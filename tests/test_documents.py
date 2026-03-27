from pathlib import Path

from llm_local_architecture import documents
from llm_local_architecture.documents import _detect_source_type


def test_determine_input_type() -> None:
    assert documents.determine_input_type("hello", False) == "text"
    assert documents.determine_input_type("", True) == "document"
    assert documents.determine_input_type("hello", True) == "text+document"


def test_should_use_ocr() -> None:
    assert documents._should_use_ocr("") is True
    assert documents._should_use_ocr("a" * 10) is True
    assert documents._should_use_ocr("a" * 500) is False


def test_pdf_detected_by_magic_bytes_no_extension() -> None:
    """Un payload PDF est détecté même sans extension .pdf."""
    pdf_header = b"%PDF-1.4 fake content"
    assert _detect_source_type(pdf_header, "upload_12345") == "pdf"


def test_jpeg_detected_by_magic_bytes() -> None:
    """Un payload JPEG est détecté même avec une extension bizarre."""
    jpeg_header = b"\xff\xd8\xff\xe0" + b"\x00" * 100
    assert _detect_source_type(jpeg_header, "photo.bin") == "image"


def test_unknown_type_returns_unknown() -> None:
    """Un payload inconnu retourne 'unknown' sans exception."""
    assert _detect_source_type(b"\x00\x00\x00\x00", "fichier.xyz") == "unknown"


def test_text_file_detected_by_extension_fallback() -> None:
    """Un fichier .txt est détecté par extension si pas de magic bytes."""
    assert _detect_source_type(b"Bonjour monde", "notes.txt") == "text"


def test_process_pdf_prefers_direct_text(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc1", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")
    monkeypatch.setattr(documents, "_extract_pdf_text", lambda path: ("Texte exploitable " * 20, 2))

    result = documents.process_document_bytes("sample.pdf", b"%PDF-1.4", "application/pdf")

    assert result.ocr_used is False
    assert result.extraction_method == "pdf_text"
    assert result.page_count == 2


def test_process_image_uses_ocr(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc2", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")
    monkeypatch.setattr(documents, "extract_text_from_images", lambda images: "Texte OCR")

    image_bytes = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc```\x00\x00"
        b"\x00\x04\x00\x01\xf6\x178U\x00\x00\x00\x00IEND\xaeB`\x82"
    )

    result = documents.process_document_bytes("scan.png", image_bytes, "image/png")
    assert result.ocr_used is True
    assert result.extraction_method == "image_ocr"


def test_process_pdf_falls_back_to_ocr_when_direct_text_is_too_short(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc5", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")
    monkeypatch.setattr(documents, "_extract_pdf_text", lambda path: ("Trop court", 1))
    monkeypatch.setattr(documents, "_render_pdf_pages", lambda path: ["page-image"])
    monkeypatch.setattr(documents, "extract_text_from_images", lambda images: "Texte OCR retenu")

    result = documents.process_document_bytes("scan.pdf", b"%PDF-1.4", "application/pdf")

    assert result.ocr_used is True
    assert result.extraction_method == "pdf_ocr"
    assert result.text == "Texte OCR retenu"


def test_process_text_file_without_ocr(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc3", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")

    result = documents.process_document_bytes("notes.txt", b"Bonjour\nCeci est un document texte.\n", "text/plain")

    assert result.ocr_used is False
    assert result.source_type == "text"
    assert result.extraction_method == "plain_text"
    assert "Bonjour" in result.text


def test_process_dockerfile_without_ocr(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc4", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")

    payload = b"FROM python:3.12-slim\nRUN pip install -r requirements.txt\n"
    result = documents.process_document_bytes("Dockerfile", payload, "text/plain")

    assert result.ocr_used is False
    assert result.source_type == "text"
    assert result.extraction_method == "plain_text"
    assert "FROM python:3.12-slim" in result.text


def test_process_pdf_without_extension_detected_by_magic_bytes(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc6", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")
    monkeypatch.setattr(
        documents,
        "_extract_pdf_text",
        lambda path: ("Texte PDF extrait directement. " * 5, 3),
    )

    result = documents.process_document_bytes("upload_12345", b"%PDF-1.4 fake content", "application/octet-stream")

    assert result.source_type == "pdf"
    assert result.extraction_method == "pdf_text"
    assert result.ocr_used is False
    assert result.page_count == 3


def test_process_pdf_empty_after_extraction_is_graceful(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(documents, "ensure_storage", lambda: None)
    monkeypatch.setattr(documents, "build_document_path", lambda filename: ("doc7", tmp_path / filename))
    monkeypatch.setattr(documents, "build_text_artifact_path", lambda document_id: tmp_path / f"{document_id}.txt")
    monkeypatch.setattr(documents, "_extract_pdf_text", lambda path: ("", 1))
    monkeypatch.setattr(documents, "_render_pdf_pages", lambda path: ["page-image"])
    monkeypatch.setattr(documents, "extract_text_from_images", lambda images: "")

    result = documents.process_document_bytes("scan.pdf", b"%PDF-1.4", "application/pdf")

    assert result.extraction_method == "empty"
    assert result.text == ""
