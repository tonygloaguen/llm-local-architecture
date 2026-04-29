from __future__ import annotations

from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture import reasoning


@pytest.mark.asyncio
async def test_fast_keeps_single_generation_call(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_AUTO_SELECT", False)
    monkeypatch.setattr(reasoning, "REASONING_MODE", "fast")
    calls: list[tuple[str, str]] = []

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        calls.append((prompt, model))
        return "réponse finale", model, False

    result = await reasoning.run_adaptive_reasoning(
        prompt="Bonjour",
        selected_model="phi4-mini",
        generate=generate,
    )

    assert result.response == "réponse finale"
    assert result.model == "phi4-mini"
    assert result.fallback_used is False
    assert result.mode == "fast"
    assert result.loops == 0
    assert calls == [("Bonjour", "phi4-mini")]


@pytest.mark.asyncio
async def test_balanced_calls_generation_critique_and_revision(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_ENABLE_CRITIC", True)
    monkeypatch.setattr(reasoning, "REASONING_MAX_LOOPS", 3)
    calls: list[tuple[str, str]] = []
    responses = iter(
        [
            ("brouillon", "qwen2.5-coder:7b-instruct", False),
            ("FIX: ajoute la contrainte VRAM", "qwen2.5-coder:7b-instruct", False),
            ("réponse révisée", "qwen2.5-coder:7b-instruct", False),
            ("OK", "qwen2.5-coder:7b-instruct", False),
        ]
    )

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        calls.append((prompt, model))
        return next(responses)

    result = await reasoning.run_adaptive_reasoning(
        prompt="Explique cette configuration Python",
        selected_model="qwen2.5-coder:7b-instruct",
        requested_mode="balanced",
        generate=generate,
    )

    assert result.response == "réponse révisée"
    assert result.mode == "balanced"
    assert result.loops == 2
    assert len(calls) == 4
    assert calls[0] == ("Explique cette configuration Python", "qwen2.5-coder:7b-instruct")
    assert "Critique interne courte" in calls[1][0]
    assert "Révise la réponse candidate" in calls[2][0]
    assert calls[1][1] == calls[2][1] == "qwen2.5-coder:7b-instruct"


@pytest.mark.asyncio
async def test_deep_respects_configured_max_loops(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_ENABLE_CRITIC", True)
    monkeypatch.setattr(reasoning, "REASONING_MAX_LOOPS", 2)
    calls: list[str] = []

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        calls.append(prompt)
        if len(calls) == 1:
            return "draft 1", model, False
        if "Critique interne structurée" in prompt:
            return "FIX: corrige", model, False
        return f"draft {len(calls)}", model, False

    result = await reasoning.run_adaptive_reasoning(
        prompt="Traceback Python avec pytest et Docker",
        selected_model="deepseek-r1:7b",
        requested_mode="deep",
        generate=generate,
    )

    assert result.mode == "deep"
    assert result.loops == 2
    assert len(calls) == 5


def test_auto_select_chooses_fast_for_simple_prompt(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_AUTO_SELECT", True)

    assert reasoning.resolve_reasoning_mode("Bonjour", None) == "fast"


@pytest.mark.parametrize(
    "prompt",
    [
        "Traceback RuntimeError dans pytest",
        "Audite ce pipeline GitHub Actions avec gitleaks et trivy",
        "Corrige ce Dockerfile FastAPI",
        "```python\nraise Exception('boom')\n```",
    ],
)
def test_auto_select_chooses_deep_for_code_logs_or_security(monkeypatch, prompt: str) -> None:
    monkeypatch.setattr(reasoning, "REASONING_AUTO_SELECT", True)

    assert reasoning.resolve_reasoning_mode(prompt, None) == "deep"


@pytest.mark.asyncio
async def test_fallback_flag_is_preserved_across_pipeline(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_ENABLE_CRITIC", True)
    calls = 0

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        nonlocal calls
        calls += 1
        if calls == 1:
            return "brouillon", "phi4-mini", True
        return "OK", "phi4-mini", False

    result = await reasoning.run_adaptive_reasoning(
        prompt="Analyse technique",
        selected_model="qwen2.5-coder:7b-instruct",
        requested_mode="balanced",
        generate=generate,
    )

    assert result.response == "brouillon"
    assert result.model == "phi4-mini"
    assert result.fallback_used is True


@pytest.mark.asyncio
async def test_internal_critique_is_not_returned_to_user(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_ENABLE_CRITIC", True)
    responses = iter(
        [
            ("réponse initiale", "phi4-mini", False),
            ("FIX: critique interne confidentielle", "phi4-mini", False),
            ("réponse finale publique", "phi4-mini", False),
            ("OK", "phi4-mini", False),
        ]
    )

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        return next(responses)

    result = await reasoning.run_adaptive_reasoning(
        prompt="Explique",
        selected_model="phi4-mini",
        requested_mode="balanced",
        generate=generate,
    )

    assert result.response == "réponse finale publique"
    assert "critique interne confidentielle" not in result.response
    assert "FIX:" not in result.response


@pytest.mark.asyncio
async def test_generation_calls_are_sequential_not_concurrent(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_ENABLE_CRITIC", True)
    in_progress = False
    calls = 0

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        nonlocal in_progress, calls
        assert in_progress is False
        in_progress = True
        calls += 1
        in_progress = False
        if calls == 1:
            return "draft", model, False
        if "Critique interne" in prompt:
            return "FIX: améliore", model, False
        return "final", model, False

    await reasoning.run_adaptive_reasoning(
        prompt="Analyse ce code",
        selected_model="qwen2.5-coder:7b-instruct",
        requested_mode="balanced",
        generate=generate,
    )

    assert calls == 5


@pytest.mark.asyncio
async def test_explicit_critic_model_is_used_only_when_configured(monkeypatch) -> None:
    monkeypatch.setattr(reasoning, "REASONING_ENABLE_CRITIC", True)
    monkeypatch.setattr(reasoning, "REASONING_CRITIC_MODEL", "granite3.3:8b")
    calls: list[str] = []
    responses = iter(
        [
            ("draft", "qwen2.5-coder:7b-instruct", False),
            ("OK", "granite3.3:8b", False),
        ]
    )

    async def generate(prompt: str, model: str) -> tuple[str, str, bool]:
        calls.append(model)
        return next(responses)

    await reasoning.run_adaptive_reasoning(
        prompt="Analyse ce code",
        selected_model="qwen2.5-coder:7b-instruct",
        requested_mode="balanced",
        generate=generate,
    )

    assert calls == ["qwen2.5-coder:7b-instruct", "granite3.3:8b"]
