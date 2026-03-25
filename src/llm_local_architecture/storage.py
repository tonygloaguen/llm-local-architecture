"""Stockage local de l'application."""

from __future__ import annotations

import re
from pathlib import Path
from uuid import uuid4

from .config import APP_DATA_DIR, DOCUMENTS_DIR, EXTRACTED_DIR, OCR_DIR


def ensure_storage() -> None:
    """Crée les répertoires locaux nécessaires."""
    for directory in (APP_DATA_DIR, DOCUMENTS_DIR, EXTRACTED_DIR, OCR_DIR):
        directory.mkdir(parents=True, exist_ok=True)


def sanitize_filename(filename: str) -> str:
    """Retourne un nom de fichier local sûr et lisible."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", filename).strip("._")
    return cleaned or "document"


def build_document_path(filename: str) -> tuple[str, Path]:
    """Construit l'identifiant et le chemin de stockage d'un document brut."""
    document_id = uuid4().hex
    safe_name = sanitize_filename(filename)
    path = DOCUMENTS_DIR / f"{document_id}_{safe_name}"
    return document_id, path


def build_text_artifact_path(document_id: str, suffix: str = ".txt") -> Path:
    """Construit le chemin d'un artefact texte local."""
    return EXTRACTED_DIR / f"{document_id}{suffix}"
