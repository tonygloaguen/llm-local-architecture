from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture.prompting import build_generation_prompt, classify_user_intent
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


def test_classify_user_intent_supports_document_guardrails() -> None:
    intent = classify_user_intent("Résume ce courrier", has_document=False)
    assert intent.category == "summary"
    assert intent.document_policy == "document_required"
    assert intent.use_document is False


def test_classify_user_intent_ignores_irrelevant_document_for_simple_qa() -> None:
    intent = classify_user_intent("2+2", has_document=True)
    assert intent.category == "qa_simple"
    assert intent.document_policy == "document_optional"
    assert intent.use_document is False


def test_classify_user_intent_detects_targeted_extraction() -> None:
    intent = classify_user_intent("Extrais la date, le nom, le montant, l'IBAN et le BIC.", has_document=True)
    assert intent.category == "extraction"
    assert intent.use_document is True
    assert intent.concise is True


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


def test_build_generation_prompt_for_targeted_extraction_is_strict() -> None:
    prompt_text, _ = build_generation_prompt(
        "Extrais la date, le nom, le montant, l'IBAN et le BIC.",
        _document(text="Date 12/03/2026\nNom JEAN DUPONT\nMontant 10 EUR\nIBAN FR76\nBIC ABCD"),
        MemoryBundle(),
        "text+document",
        intent=classify_user_intent("Extrais la date, le nom, le montant, l'IBAN et le BIC.", True),
    )

    assert "Réponds uniquement avec les champs explicitement demandés" in prompt_text
    assert "N'ajoute aucun champ supplémentaire." in prompt_text
    assert "réponds exactement `absent`" in prompt_text


def test_build_generation_prompt_for_missing_document_answer_is_strict() -> None:
    prompt_text, _ = build_generation_prompt(
        "Quel est le numéro de facture ?",
        _document(text="IBAN FR76\nBIC ABCD"),
        MemoryBundle(),
        "text+document",
        intent=classify_user_intent("Quel est le numéro de facture ?", True),
    )

    assert "réponds exactement `absent du document`" in prompt_text
    assert "N'ajoute aucune autre information." in prompt_text


def test_build_generation_prompt_for_inline_summary_forbids_extra_interpretation() -> None:
    prompt_text, _ = build_generation_prompt(
        "Résume ce texte en 3 points : Ligne A. Ligne B. Ligne C.",
        None,
        MemoryBundle(),
        "text",
        intent=classify_user_intent("Résume ce texte en 3 points : Ligne A. Ligne B. Ligne C.", False),
    )

    assert "Fais un résumé fidèle au contenu fourni." in prompt_text
    assert "N'ajoute aucune interprétation" in prompt_text


def test_build_generation_prompt_for_simple_question_requests_concise_answer() -> None:
    prompt_text, _ = build_generation_prompt(
        "2+2",
        None,
        MemoryBundle(),
        "text",
        intent=classify_user_intent("2+2", False),
    )

    assert "Réponds de manière courte, directe et exploitable." in prompt_text
    assert "N'ajoute pas d'explication inutile." in prompt_text


def test_build_generation_prompt_for_action_request_is_not_generic_summary() -> None:
    prompt_text, _ = build_generation_prompt(
        "Donne moi les actions prioritaires à effectuer.",
        _document(text="Action 1\nAction 2"),
        MemoryBundle(),
        "text+document",
        intent=classify_user_intent("Donne moi les actions prioritaires à effectuer.", True),
    )

    assert "liste d'actions concrètes et prioritaires" in prompt_text
    assert "Ne fournis pas de résumé générique." in prompt_text
