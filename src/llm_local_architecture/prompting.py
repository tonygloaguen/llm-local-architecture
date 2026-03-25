"""Construction du contexte de routage et du prompt final."""

from __future__ import annotations

from .config import DOCUMENT_EXCERPT_CHARS, MAX_CONTEXT_CHARS, ROUTING_EXCERPT_CHARS
from .schemas import MemoryBundle, ProcessedDocument


def _clip(text: str, limit: int) -> str:
    normalized = text.strip()
    if len(normalized) <= limit:
        return normalized
    return normalized[:limit].rstrip() + "..."


def build_routing_text(
    prompt: str,
    document: ProcessedDocument | None,
    memory: MemoryBundle,
) -> str:
    """Construit un texte de routage explicable à partir du contexte courant."""
    effective_prompt = prompt.strip() or "Resume le document fourni et reponds de maniere structuree."
    parts: list[str] = [effective_prompt]

    if document is not None:
        parts.extend(
            [
                "document_uploaded",
                f"document_type:{document.source_type}",
                f"extraction:{document.extraction_method}",
            ]
        )
        if document.ocr_used:
            parts.append("ocr_used")
        parts.append(document.filename)
        parts.append(_clip(document.text, ROUTING_EXCERPT_CHARS))

    return " ".join(part for part in parts if part)


def build_generation_prompt(
    prompt: str,
    document: ProcessedDocument | None,
    memory: MemoryBundle,
) -> tuple[str, list[str]]:
    """Construit le prompt final envoyé à Ollama."""
    sources = list(memory.sources)
    user_prompt = prompt.strip() or "Résume le document fourni, identifie son type, puis réponds de manière structurée."

    sections = [
        "Tu es un assistant local exécuté hors ligne.",
        f"Demande utilisateur:\n{user_prompt}",
    ]

    if memory.short_term_text:
        sections.append(f"Historique de session récent:\n{_clip(memory.short_term_text, 2000)}")

    if document is not None:
        sections.append(
            "Document courant:\n"
            f"nom={document.filename}\n"
            f"type={document.source_type}\n"
            f"ocr_used={document.ocr_used}\n"
            f"contenu=\n{_clip(document.text, DOCUMENT_EXCERPT_CHARS)}"
        )
        if "documentary" not in sources:
            sources.append("documentary")

    if memory.preferences_text:
        sections.append(f"Préférences utilisateur:\n{memory.preferences_text}")

    prompt_text = "\n\n".join(sections)
    return _clip(prompt_text, MAX_CONTEXT_CHARS), sources
