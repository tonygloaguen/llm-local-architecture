"""Pipeline documentaire local : extraction PDF et OCR si nécessaire."""

from __future__ import annotations

from io import BytesIO
import logging
from pathlib import Path

from PIL import Image
from pypdf import PdfReader
import pypdfium2 as pdfium

from .config import OCR_DPI, OCR_ENABLED, OCR_MIN_EXTRACTED_CHARS, PDF_MAX_PAGES
from .ocr import extract_text_from_images
from .schemas import ProcessedDocument
from .storage import build_document_path, build_text_artifact_path, ensure_storage

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}
TEXT_SUFFIXES = {".txt", ".md", ".csv", ".log"}
TEXT_FILENAMES = {"dockerfile"}

# Magic bytes pour détection fiable indépendante de l'extension
_MAGIC_PDF = b"%PDF"
_MAGIC_PNG = b"\x89PNG"
_MAGIC_JPEG = b"\xff\xd8\xff"
_MAGIC_WEBP = b"RIFF"
_MAGIC_TIFF1 = b"II*\x00"
_MAGIC_TIFF2 = b"MM\x00*"

logger = logging.getLogger(__name__)


def determine_input_type(prompt: str, has_document: bool) -> str:
    """Retourne le type d'entrée global de la requête."""
    has_prompt = bool(prompt.strip())
    if has_prompt and has_document:
        return "text+document"
    if has_document:
        return "document"
    return "text"


def _detect_source_type(payload: bytes, filename: str) -> str:
    """Détecte le type de source par magic bytes, puis par extension en fallback."""
    header = payload[:8]
    if header[:4] == _MAGIC_PDF:
        return "pdf"
    if header[:4] == _MAGIC_PNG:
        return "image"
    if header[:3] == _MAGIC_JPEG:
        return "image"
    if header[:4] == _MAGIC_WEBP and payload[8:12] == b"WEBP":
        return "image"
    if header[:4] in (_MAGIC_TIFF1, _MAGIC_TIFF2):
        return "image"

    suffix = Path(filename).suffix.lower()
    filename_lower = filename.strip().lower()
    if suffix == ".pdf":
        return "pdf"
    if suffix in IMAGE_SUFFIXES:
        return "image"
    if suffix in TEXT_SUFFIXES or filename_lower in TEXT_FILENAMES:
        return "text"
    return "unknown"


def _extract_pdf_text(path: Path) -> tuple[str, int]:
    reader = PdfReader(str(path))
    total_pages = len(reader.pages)
    pages_to_process = reader.pages[:PDF_MAX_PAGES]
    if total_pages > PDF_MAX_PAGES:
        logger.warning(
            "PDF tronqué: %s pages → %s (limite PDF_MAX_PAGES=%s)",
            total_pages,
            PDF_MAX_PAGES,
            PDF_MAX_PAGES,
        )
    pages = []
    for page in pages_to_process:
        pages.append(page.extract_text() or "")
    return "\n\n".join(pages).strip(), total_pages


def _render_pdf_pages(path: Path) -> list[Image.Image]:
    pdf = pdfium.PdfDocument(str(path))
    scale = OCR_DPI / 72
    images: list[Image.Image] = []
    for index in range(len(pdf)):
        page = pdf[index]
        bitmap = page.render(scale=scale)
        images.append(bitmap.to_pil())
    return images


def _should_use_ocr(extracted_text: str) -> bool:
    return len(extracted_text.strip()) < OCR_MIN_EXTRACTED_CHARS


def _decode_text_bytes(payload: bytes) -> str:
    """Décodage local simple pour les fichiers texte."""
    return payload.decode("utf-8", errors="replace").strip()


def process_document_bytes(
    filename: str,
    payload: bytes,
    content_type: str | None = None,
) -> ProcessedDocument:
    """Traite un document localement et retourne son texte exploitable."""
    ensure_storage()
    document_id, stored_path = build_document_path(filename)
    stored_path.write_bytes(payload)

    extracted_text = ""
    extraction_method = "none"
    ocr_used = False
    page_count = 1
    source_type = "binary"
    mime_type = content_type or "application/octet-stream"
    detected_source_type = _detect_source_type(payload, filename)

    if detected_source_type == "pdf":
        source_type = "pdf"
        extracted_text, page_count = _extract_pdf_text(stored_path)
        extraction_method = "pdf_text"
        if OCR_ENABLED and _should_use_ocr(extracted_text):
            extracted_text = extract_text_from_images(_render_pdf_pages(stored_path))
            extraction_method = "pdf_ocr"
            ocr_used = True
    elif detected_source_type == "text":
        source_type = "text"
        extracted_text = _decode_text_bytes(payload)
        extraction_method = "plain_text"
    elif detected_source_type == "image":
        source_type = "image"
        image = Image.open(BytesIO(payload))
        if not OCR_ENABLED:
            raise RuntimeError("OCR désactivé alors qu'un document image a été fourni.")
        extracted_text = extract_text_from_images([image])
        extraction_method = "image_ocr"
        ocr_used = True
    else:
        raise ValueError(f"Type de document non supporté: {Path(filename).suffix.lower() or filename}")

    if not extracted_text.strip() and extraction_method not in {"plain_text"}:
        logger.warning(
            "Document vide après extraction: filename=%s extraction_method=%s",
            filename,
            extraction_method,
        )
        extraction_method = "empty"

    logger.debug(
        "Document processed filename=%s source_type=%s extraction_method=%s ocr_used=%s extracted_chars=%s extracted_text=%r",
        filename,
        source_type,
        extraction_method,
        ocr_used,
        len(extracted_text),
        extracted_text,
    )

    extracted_path = build_text_artifact_path(document_id)
    extracted_path.write_text(extracted_text, encoding="utf-8")

    return ProcessedDocument(
        document_id=document_id,
        filename=filename,
        stored_path=str(stored_path),
        extracted_path=str(extracted_path),
        mime_type=mime_type,
        source_type=source_type,
        extraction_method=extraction_method,
        text=extracted_text,
        ocr_used=ocr_used,
        page_count=page_count,
    )
