"""Pipeline de raisonnement adaptatif borné.

Le mode `fast` préserve le comportement historique. Les modes plus profonds
utilisent des critiques internes courtes, jamais retournées à l'utilisateur.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
import logging
import re
import time

from .config import (
    REASONING_AUTO_SELECT,
    REASONING_BALANCED_MODEL,
    REASONING_CRITIC_MODEL,
    REASONING_DEBUG_THINK_TAGS,
    REASONING_DEEP_MODEL,
    REASONING_ENABLE_CRITIC,
    REASONING_FAST_MODEL,
    REASONING_MAX_LOOPS,
    REASONING_MODE,
)

logger = logging.getLogger(__name__)

ReasoningGenerate = Callable[[str, str], Awaitable[tuple[str, str, bool]]]

VALID_REASONING_MODES = {"fast", "balanced", "deep"}
_DEEP_KEYWORDS = (
    "audit",
    "bandit",
    "checkov",
    "ci/cd",
    "code",
    "comparaison",
    "correction",
    "diagnostic",
    "docker",
    "fastapi",
    "github actions",
    "gitleaks",
    "ollama",
    "plan",
    "proxmox",
    "pytest",
    "securite",
    "security",
    "ssh",
    "traceback",
    "trivy",
    "wordpress",
)
_TECHNICAL_KEYWORDS = (
    "api",
    "architecture",
    "bug",
    "configuration",
    "debug",
    "erreur",
    "exception",
    "implementation",
    "python",
    "refactor",
    "script",
    "test",
    "workflow",
)
_CODE_KEYWORDS = (
    "bugfix",
    "dockerfile",
    "fastapi",
    "github actions",
    "patch",
    "pytest",
    "python",
    "refactor",
)


@dataclass(frozen=True, slots=True)
class ReasoningResult:
    """Résultat public du pipeline."""

    response: str
    model: str
    fallback_used: bool
    mode: str
    loops: int
    ollama_calls: int = 0
    total_seconds: float = 0.0


def normalize_reasoning_mode(mode: str | None) -> str:
    """Normalise un mode utilisateur/config en valeur supportée."""
    normalized = (mode or REASONING_MODE).strip().lower()
    if normalized not in VALID_REASONING_MODES:
        return "fast"
    return normalized


def select_reasoning_mode(prompt: str) -> str:
    """Sélecteur déterministe simple pour REASONING_AUTO_SELECT."""
    normalized = _normalize(prompt)
    if _looks_like_logs_traceback_or_security(prompt):
        return "deep"
    if any(keyword in normalized for keyword in _CODE_KEYWORDS) or _looks_like_code_patch(prompt):
        return "balanced"
    if any(keyword in normalized for keyword in _DEEP_KEYWORDS) or _looks_like_code_or_logs(prompt):
        return "deep"
    if any(keyword in normalized for keyword in _TECHNICAL_KEYWORDS) or len(prompt) > 240:
        return "balanced"
    return "fast"


def resolve_reasoning_mode(prompt: str, requested_mode: str | None = None) -> str:
    """Retourne le mode effectif."""
    if requested_mode:
        return normalize_reasoning_mode(requested_mode)
    if REASONING_AUTO_SELECT:
        return select_reasoning_mode(prompt)
    return normalize_reasoning_mode(REASONING_MODE)


def resolve_reasoning_model(mode: str, routed_model: str) -> str:
    """Applique une surcharge modèle explicite par mode, sinon conserve le routage."""
    overrides = {
        "fast": REASONING_FAST_MODEL,
        "balanced": REASONING_BALANCED_MODEL,
        "deep": REASONING_DEEP_MODEL,
    }
    override = overrides.get(mode, "").strip()
    return override or routed_model


async def run_adaptive_reasoning(
    *,
    prompt: str,
    selected_model: str,
    generate: ReasoningGenerate,
    requested_mode: str | None = None,
) -> ReasoningResult:
    """Exécute le pipeline adaptatif via la fonction de génération fournie."""
    started_at = time.perf_counter()
    ollama_calls = 0
    mode = resolve_reasoning_mode(prompt, requested_mode)
    generation_model = resolve_reasoning_model(mode, selected_model)
    generation_prompt = apply_reasoning_directive(prompt, mode, generation_model)

    logger.info(
        "Reasoning mode=%s model=%s directive=%s loop=0 event=start",
        mode,
        generation_model,
        reasoning_directive_name(mode, generation_model),
    )
    initial_response, actual_model, fallback_used = await generate(generation_prompt, generation_model)
    ollama_calls += 1
    initial_response = filter_thinking_tags(initial_response)
    if mode == "fast" or not REASONING_ENABLE_CRITIC:
        total_seconds = time.perf_counter() - started_at
        logger.info(
            "Reasoning mode=%s model=%s directive=%s ollama_calls=%s fallback_used=%s total_seconds=%.3f event=done",
            mode,
            actual_model,
            reasoning_directive_name(mode, actual_model),
            ollama_calls,
            fallback_used,
            total_seconds,
        )
        return ReasoningResult(initial_response, actual_model, fallback_used, mode, 0, ollama_calls, total_seconds)

    max_loops = _loop_limit(mode)
    answer = initial_response
    current_model = actual_model
    any_fallback = fallback_used
    completed_loops = 0

    for loop in range(1, max_loops + 1):
        completed_loops = loop
        critic_model = _critic_model(current_model)
        logger.info(
            "Reasoning mode=%s model=%s directive=%s loop=%s event=critic",
            mode,
            critic_model,
            reasoning_directive_name(mode, critic_model),
            loop,
        )
        try:
            critique, actual_critic_model, critic_fallback = await generate(
                apply_reasoning_directive(_build_critique_prompt(prompt, answer, mode), mode, critic_model),
                critic_model,
            )
            ollama_calls += 1
            critique = filter_thinking_tags(critique)
            any_fallback = any_fallback or critic_fallback
            logger.info(
                "Reasoning mode=%s model=%s directive=%s loop=%s fallback=%s event=critic_done",
                mode,
                actual_critic_model,
                reasoning_directive_name(mode, actual_critic_model),
                loop,
                critic_fallback,
            )
            if _critique_accepts(critique):
                break

            revision_model = actual_critic_model if REASONING_CRITIC_MODEL.strip() else current_model
            logger.info(
                "Reasoning mode=%s model=%s directive=%s loop=%s event=revision",
                mode,
                revision_model,
                reasoning_directive_name(mode, revision_model),
                loop,
            )
            answer, current_model, revision_fallback = await generate(
                apply_reasoning_directive(_build_revision_prompt(prompt, answer, critique, mode), mode, revision_model),
                revision_model,
            )
            ollama_calls += 1
            answer = filter_thinking_tags(answer)
            any_fallback = any_fallback or revision_fallback
        except Exception as exc:
            logger.warning(
                "Reasoning mode=%s model=%s loop=%s error=%s",
                mode,
                current_model,
                loop,
                _summarize_error(exc),
            )
            break

    total_seconds = time.perf_counter() - started_at
    logger.info(
        "Reasoning mode=%s model=%s directive=%s ollama_calls=%s fallback_used=%s total_seconds=%.3f event=done",
        mode,
        current_model,
        reasoning_directive_name(mode, current_model),
        ollama_calls,
        any_fallback,
        total_seconds,
    )
    return ReasoningResult(answer, current_model, any_fallback, mode, completed_loops, ollama_calls, total_seconds)


def apply_reasoning_directive(prompt: str, mode: str, model: str) -> str:
    """Ajoute /think ou /no_think uniquement aux modèles Qwen3 compatibles."""
    directive = reasoning_directive_name(mode, model)
    if directive == "none":
        return prompt
    stripped = prompt.lstrip()
    if stripped.startswith("/think") or stripped.startswith("/no_think"):
        return prompt
    return f"/{directive}\n{prompt}"


def reasoning_directive_name(mode: str, model: str) -> str:
    """Retourne la directive Qwen3 effective pour les logs."""
    if not _is_qwen3_model(model):
        return "none"
    if mode == "deep":
        return "think"
    if mode == "balanced":
        return "no_think"
    return "none"


def filter_thinking_tags(text: str) -> str:
    """Supprime les blocs <think>...</think> sauf debug explicite."""
    if REASONING_DEBUG_THINK_TAGS:
        return text
    without_blocks = re.sub(r"<think\b[^>]*>.*?</think>", "", text, flags=re.IGNORECASE | re.DOTALL)
    return without_blocks.strip()


def _loop_limit(mode: str) -> int:
    configured = max(0, REASONING_MAX_LOOPS)
    hard_limit = 2 if mode == "balanced" else 3
    return min(configured, hard_limit)


def _critic_model(current_model: str) -> str:
    configured = REASONING_CRITIC_MODEL.strip()
    return configured or current_model


def _build_critique_prompt(prompt: str, answer: str, mode: str) -> str:
    if mode == "deep":
        instructions = (
            "Critique interne structurée. Vérifie brièvement exactitude, complétude, risques, "
            "contraintes utilisateur et actions manquantes. Réponds uniquement avec:\n"
            "OK si la réponse est suffisante, sinon FIX: suivi de 3 points maximum."
        )
    else:
        instructions = (
            "Critique interne courte. Vérifie les erreurs ou oublis importants. "
            "Réponds uniquement avec OK ou FIX: suivi d'une correction courte."
        )
    return (
        f"{instructions}\n\n"
        "Ne révèle aucun raisonnement détaillé.\n"
        f"Demande utilisateur:\n{prompt}\n\n"
        f"Réponse candidate:\n{answer}"
    )


def _build_revision_prompt(prompt: str, answer: str, critique: str, mode: str) -> str:
    detail = "rigoureuse" if mode == "deep" else "concise"
    return (
        f"Révise la réponse candidate de manière {detail} en appliquant uniquement la critique utile.\n"
        "Retourne seulement la réponse finale destinée à l'utilisateur.\n"
        "N'expose pas la critique interne ni de chain-of-thought.\n\n"
        f"Demande utilisateur:\n{prompt}\n\n"
        f"Réponse candidate:\n{answer}\n\n"
        f"Critique interne à appliquer:\n{_clip_internal(critique, 1200)}"
    )


def _critique_accepts(critique: str) -> bool:
    normalized = critique.strip().lower()
    return normalized == "ok" or normalized.startswith("ok\n") or normalized.startswith("ok.")


def _normalize(text: str) -> str:
    lowered = text.lower()
    replacements = str.maketrans({"é": "e", "è": "e", "ê": "e", "à": "a", "ç": "c", "ù": "u"})
    return lowered.translate(replacements)


def _looks_like_code_or_logs(prompt: str) -> bool:
    patterns = (
        r"```",
        r"\btraceback\b",
        r"\bdef\s+\w+\(",
        r"\bclass\s+\w+",
        r"\bimport\s+\w+",
        r"\bERROR\b",
        r"\bException\b",
        r"\bfailed\b",
    )
    return any(re.search(pattern, prompt, flags=re.IGNORECASE) for pattern in patterns)


def _looks_like_logs_traceback_or_security(prompt: str) -> bool:
    normalized = _normalize(prompt)
    security_keywords = (
        "audit",
        "bandit",
        "checkov",
        "cve",
        "gitleaks",
        "securite",
        "security",
        "traceback",
        "trivy",
    )
    log_patterns = (
        r"\btraceback\b",
        r"\b(stack trace|exception|runtimeerror|keyerror|typeerror)\b",
        r"\b(error|failed|fatal|panic)\b.*\n.*\b(error|failed|fatal|panic)\b",
    )
    return any(keyword in normalized for keyword in security_keywords) or any(
        re.search(pattern, prompt, flags=re.IGNORECASE | re.DOTALL) for pattern in log_patterns
    )


def _looks_like_code_patch(prompt: str) -> bool:
    return bool(
        re.search(
            r"\b(patch|bugfix|refactor|github actions|dockerfile|fastapi|pytest|python)\b",
            prompt,
            flags=re.IGNORECASE,
        )
    )


def _is_qwen3_model(model: str) -> bool:
    return model.strip().lower().startswith("qwen3")


def _clip_internal(text: str, limit: int) -> str:
    stripped = text.strip()
    if len(stripped) <= limit:
        return stripped
    return stripped[:limit].rstrip() + "..."


def _summarize_error(exc: Exception) -> str:
    message = str(exc).replace("\n", " ").strip()
    if len(message) > 160:
        message = message[:160].rstrip() + "..."
    return f"{type(exc).__name__}: {message}"
