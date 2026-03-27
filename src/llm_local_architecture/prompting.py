"""Construction du contexte de routage et du prompt final."""

from __future__ import annotations

from .config import DOCUMENT_EXCERPT_CHARS, ROUTING_EXCERPT_CHARS
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
    # NOTE: plus utilisée pour le routing depuis LOT 1 — conservée pour debug.
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
    input_type: str = "text",
) -> tuple[str, list[str]]:
    """Construit le prompt final envoyé à Ollama.

    Ordre de priorité (jamais tronqué -> tronqué en dernier) :
      1. system (fixe)
      2. user_message (protégé)
      3. history
      4. document + rules
      5. preferences
    """
    from .config import HISTORY_MAX_CHARS  # noqa: PLC0415

    sources = list(memory.sources)
    user_message = prompt.strip() or "Résume le document fourni, identifie son type, puis réponds de manière structurée."
    sections = ["Tu es un assistant local exécuté hors ligne.", f"Demande utilisateur:\n{user_message}"]

    if memory.short_term_text:
        sections.append(f"Historique de session récent:\n{_clip(memory.short_term_text, HISTORY_MAX_CHARS)}")

    if document is not None:
        document_heading = "Texte OCR prioritaire" if input_type in {"document", "text+document"} else "Document courant"
        doc_text = document.text.strip()
        truncated = False
        if len(doc_text) > DOCUMENT_EXCERPT_CHARS:
            doc_text = doc_text[:DOCUMENT_EXCERPT_CHARS].rstrip()
            truncated = True

        doc_block = (
            f"{document_heading}:\n"
            f"nom={document.filename}\n"
            f"type={document.source_type}\n"
            f"ocr_used={document.ocr_used}\n"
            f"extraction={document.extraction_method}\n"
            f"contenu=\n{doc_text}"
        )
        if truncated:
            doc_block += "\n[... DOCUMENT TRONQUÉ — suite omise pour respecter la limite de contexte ...]"

        sections.append(
            doc_block
        )
        sections.append(
            "Règles de réponse documentaires:\n"
            "Réponds uniquement à partir du texte OCR/extrait ci-dessus.\n"
            "N'invente rien et n'utilise aucune connaissance externe.\n"
            "Si l'information demandée n'est pas présente dans ce texte, réponds qu'elle est absente du document."
        )
        if "documentary" not in sources:
            sources.append("documentary")

    if memory.preferences_text:
        sections.append(f"Préférences utilisateur:\n{_clip(memory.preferences_text, 500)}")

    prompt_text = "\n\n".join(sections)
    return prompt_text, sources
