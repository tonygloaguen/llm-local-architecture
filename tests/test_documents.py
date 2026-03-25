from pathlib import Path

from llm_local_architecture import documents


def test_determine_input_type() -> None:
    assert documents.determine_input_type("hello", False) == "text"
    assert documents.determine_input_type("", True) == "document"
    assert documents.determine_input_type("hello", True) == "text+document"


def test_should_use_ocr() -> None:
    assert documents._should_use_ocr("") is True
    assert documents._should_use_ocr("a" * 10) is True
    assert documents._should_use_ocr("a" * 500) is False


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
