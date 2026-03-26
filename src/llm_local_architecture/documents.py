"""Pipeline documentaire local : extraction PDF et OCR si nécessaire."""

from __future__ import annotations

from io import BytesIO
import logging
from pathlib import Path

from PIL import Image
from pypdf import PdfReader
import pypdfium2 as pdfium

from .config import OCR_DPI, OCR_ENABLED, OCR_MIN_EXTRACTED_CHARS
from .ocr import extract_text_from_images
from .schemas import ProcessedDocument
from .storage import build_document_path, build_text_artifact_path, ensure_storage

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}
TEXT_SUFFIXES = {".txt", ".md", ".csv", ".log"}
TEXT_FILENAMES = {"dockerfile"}

logger = logging.getLogger(__name__)


def determine_input_type(prompt: str, has_document: bool) -> str:
    """Retourne le type d'entrée global de la requête."""
    has_prompt = bool(prompt.strip())
    if has_prompt and has_document:
        return "text+document"
    if has_document:
        return "document"
    return "text"


def _extract_pdf_text(path: Path) -> tuple[str, int]:
    reader = PdfReader(str(path))
    pages = []
    for page in reader.pages:
        pages.append(page.extract_text() or "")
    return "\n\n".join(pages).strip(), len(reader.pages)


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

    suffix = stored_path.suffix.lower()
    filename_lower = filename.strip().lower()
    extracted_text = ""
    extraction_method = "none"
    ocr_used = False
    page_count = 1
    source_type = "binary"
    mime_type = content_type or "application/octet-stream"

    if suffix == ".pdf":
        source_type = "pdf"
        extracted_text, page_count = _extract_pdf_text(stored_path)
        extraction_method = "pdf_text"
        if OCR_ENABLED and _should_use_ocr(extracted_text):
            extracted_text = extract_text_from_images(_render_pdf_pages(stored_path))
            extraction_method = "pdf_ocr"
            ocr_used = True
    elif suffix in TEXT_SUFFIXES or filename_lower in TEXT_FILENAMES:
        source_type = "text"
        extracted_text = _decode_text_bytes(payload)
        extraction_method = "plain_text"
    elif suffix in IMAGE_SUFFIXES:
        source_type = "image"
        image = Image.open(BytesIO(payload))
        if not OCR_ENABLED:
            raise RuntimeError("OCR désactivé alors qu'un document image a été fourni.")
        extracted_text = extract_text_from_images([image])
        extraction_method = "image_ocr"
        ocr_used = True
    else:
        raise ValueError(f"Type de document non supporté: {suffix or filename}")

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
