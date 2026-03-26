from pathlib import Path

from llm_local_architecture import memory
from llm_local_architecture.schemas import ProcessedDocument


def test_memory_roundtrip(tmp_path: Path, monkeypatch) -> None:
    db_path = tmp_path / "app.db"
    monkeypatch.setattr(memory, "APP_DB_PATH", db_path)

    memory.initialize_database()
    session_id = memory.ensure_session()
    memory.save_message(session_id, "user", "Bonjour")
    memory.save_message(session_id, "assistant", "Salut")

    document = ProcessedDocument(
        document_id="doc1",
        filename="test.pdf",
        stored_path=str(tmp_path / "test.pdf"),
        extracted_path=str(tmp_path / "test.txt"),
        mime_type="application/pdf",
        source_type="pdf",
        extraction_method="pdf_text",
        text="Contenu de document",
        ocr_used=False,
        page_count=1,
    )
    memory.save_document(session_id, document)

    bundle = memory.build_memory_bundle(session_id, "doc1")
    assert "Bonjour" in bundle.short_term_text
    assert "Contenu de document" in bundle.documentary_text
    assert "short_term" in bundle.sources
    assert "documentary" in bundle.sources
