"""Schémas internes et API pour l'application web locale."""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import BaseModel


@dataclass(slots=True)
class StructuredDocumentFields:
    """Champs extraits localement pour compléter un texte OCR brut."""

    date: str = "non trouvé"
    nom: str = "non trouvé"
    numero_securite_sociale: str = "non trouvé"
    numero_creance: str = "non trouvé"
    montant: str = "non trouvé"
    iban: str = "non trouvé"
    bic: str = "non trouvé"

    def as_dict(self) -> dict[str, str]:
        return {
            "date": self.date,
            "nom": self.nom,
            "numero_securite_sociale": self.numero_securite_sociale,
            "numero_creance": self.numero_creance,
            "montant": self.montant,
            "iban": self.iban,
            "bic": self.bic,
        }


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
    structured_fields: StructuredDocumentFields = field(default_factory=StructuredDocumentFields)


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
