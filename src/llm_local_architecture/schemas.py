"""Schémas internes et API pour l'application web locale."""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import BaseModel


@dataclass(slots=True)
class ProcessedDocument:
    """Résultat du pipeline documentaire local."""

    document_id: str
    filename: str
    stored_path: str
    extracted_path: str
    mime_type: str
    source_type: str
    extraction_method: str
    text: str
    ocr_used: bool
    page_count: int


@dataclass(slots=True)
class MemoryBundle:
    """Contexte mémoire injecté dans le prompt."""

    short_term_text: str = ""
    documentary_text: str = ""
    preferences_text: str = ""
    sources: list[str] = field(default_factory=list)


class ChatResponse(BaseModel):
    """Réponse enrichie de l'interface web locale."""

    session_id: str
    model: str
    routed_by: str
    response: str
    input_type: str
    ocr_used: bool
    document_id: str | None = None
    memory_sources: list[str]
    extraction_method: str | None = None
