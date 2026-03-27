from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture.prompting import build_generation_prompt
from llm_local_architecture.schemas import MemoryBundle, ProcessedDocument, StructuredDocumentFields


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
        structured_fields=StructuredDocumentFields(
            date="12/03/2026",
            nom="JEAN DUPONT",
        ),
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
    assert "Champs structurés extraits localement:" in prompt_text
    assert "nom=JEAN DUPONT" in prompt_text
    assert "Réponds uniquement à partir du texte OCR/extrait et des champs structurés ci-dessus." in prompt_text
    assert prompt_text.index("Demande utilisateur:") < prompt_text.index("Texte OCR prioritaire:")
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


def test_user_message_never_truncated_with_huge_document() -> None:
    """user_message intact même avec un document de 20 000 chars."""
    big_doc = _document(text="Contenu répété. " * 1250)
    user_msg = "Quel est le montant exact à payer sur cette notification ?"
    prompt_text, _ = build_generation_prompt(user_msg, big_doc, MemoryBundle(), "text+document")
    assert user_msg in prompt_text


def test_truncation_marker_present_when_doc_exceeds_budget() -> None:
    """Si le doc dépasse DOCUMENT_EXCERPT_CHARS, le marqueur de troncature est présent."""
    from llm_local_architecture.config import DOCUMENT_EXCERPT_CHARS

    big_doc = _document(text="X" * (DOCUMENT_EXCERPT_CHARS + 500))
    prompt_text, _ = build_generation_prompt("Question", big_doc, MemoryBundle(), "text+document")
    assert "DOCUMENT TRONQUÉ" in prompt_text


def test_user_message_appears_before_document_section() -> None:
    """user_message doit précéder le contenu documentaire dans le prompt final."""
    doc = _document(text="Un texte court de test")
    user_msg = "Résume ce document"
    prompt_text, _ = build_generation_prompt(user_msg, doc, MemoryBundle(), "text+document")
    assert prompt_text.index("Demande utilisateur:") < prompt_text.index("nom=scan.pdf")


def test_short_document_not_truncated() -> None:
    """Un document court ne doit pas avoir le marqueur de troncature."""
    short_doc = _document(text="Document court de 50 chars seulement.")
    prompt_text, _ = build_generation_prompt("Question", short_doc, MemoryBundle(), "text+document")
    assert "DOCUMENT TRONQUÉ" not in prompt_text
