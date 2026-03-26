from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture.prompting import build_generation_prompt
from llm_local_architecture.schemas import MemoryBundle, ProcessedDocument


def _document(*, text: str, ocr_used: bool = True) -> ProcessedDocument:
    return ProcessedDocument(
        document_id="doc-1",
        filename="scan.pdf",
        stored_path="/tmp/scan.pdf",
        extracted_path="/tmp/doc-1.txt",
        mime_type="application/pdf",
        source_type="pdf",
        extraction_method="pdf_ocr" if ocr_used else "pdf_text",
        text=text,
        ocr_used=ocr_used,
        page_count=1,
    )


def test_build_generation_prompt_prioritizes_document_text_for_document_inputs() -> None:
    prompt_text, sources = build_generation_prompt(
        "Liste les points clés",
        _document(text="Premier point\nDeuxième point"),
        MemoryBundle(),
        input_type="text+document",
    )

    assert "Texte OCR prioritaire:" in prompt_text
    assert "contenu=\nPremier point\nDeuxième point" in prompt_text
    assert "Réponds uniquement à partir du texte OCR/extrait ci-dessus." in prompt_text
    assert prompt_text.index("Texte OCR prioritaire:") < prompt_text.index("Demande utilisateur:")
    assert "documentary" in sources


def test_build_generation_prompt_uses_user_prompt_only_for_text_inputs() -> None:
    prompt_text, sources = build_generation_prompt(
        "Bonjour",
        None,
        MemoryBundle(),
        input_type="text",
    )

    assert prompt_text.startswith("Tu es un assistant local exécuté hors ligne.")
    assert "Demande utilisateur:\nBonjour" in prompt_text
    assert "Réponds uniquement à partir du texte OCR/extrait ci-dessus." not in prompt_text
    assert sources == []
