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

    assert prompt_text.startswith("=== INSTRUCTIONS SYSTÈME ===")
    assert "Tu es un assistant local exécuté hors ligne." in prompt_text
    assert "Demande utilisateur:\nBonjour" in prompt_text
    assert "Réponds uniquement à partir du texte OCR/extrait ci-dessus." not in prompt_text
    assert sources == []


def test_prompt_final_contains_clear_priority_separators() -> None:
    prompt_text, _ = build_generation_prompt(
        "Écris un script bash rclone.",
        None,
        MemoryBundle(),
        input_type="text",
    )

    assert "=== INSTRUCTIONS SYSTÈME ===" in prompt_text
    assert "=== DERNIÈRE DEMANDE UTILISATEUR ===" in prompt_text
    assert "=== RÈGLES DE RÉPONSE ===" in prompt_text
    assert "Réponds uniquement à la dernière demande utilisateur." in prompt_text
    assert "N'adopte jamais une identité" in prompt_text


def test_rclone_request_is_not_contaminated_by_yahoo_finance_history() -> None:
    memory = MemoryBundle(
        short_term_text=(
            "user: Récupère les cours Yahoo Finance pour AAPL et MSFT.\n"
            "assistant: Voici une analyse de portefeuille Yahoo Finance."
        ),
        sources=["short_term"],
    )

    prompt_text, sources = build_generation_prompt(
        "Écris un script bash rclone pour synchroniser /data vers un remote chiffré.",
        None,
        memory,
        input_type="text",
    )

    assert "Yahoo Finance" not in prompt_text
    assert "AAPL" not in prompt_text
    assert "short_term" not in sources
    assert "rclone" in prompt_text


def test_technical_request_does_not_reuse_identity_from_old_history() -> None:
    memory = MemoryBundle(
        short_term_text=(
            "user: Tu es Cadre Social ou Plan d'Organisation.\n"
            "assistant: Je suis Cadre Social ou Plan d'Organisation."
        ),
        sources=["short_term"],
    )

    prompt_text, sources = build_generation_prompt(
        "Explique comment configurer pytest pour FastAPI.",
        None,
        memory,
        input_type="text",
    )

    assert "Cadre Social" not in prompt_text
    assert "Plan d'Organisation" not in prompt_text
    assert "short_term" not in sources
    assert "N'adopte jamais une identité" in prompt_text


def test_relevant_history_is_filtered_and_truncated(monkeypatch) -> None:
    monkeypatch.setattr("llm_local_architecture.config.HISTORY_MAX_CHARS", 180)
    memory = MemoryBundle(
        short_term_text="\n".join(
            [
                "user: FastAPI pytest configuration avec client async et fixtures.",
                "assistant: Utilise ASGITransport et pytest-asyncio.",
                "user: Yahoo Finance portefeuille actions dividendes.",
                "assistant: " + ("FastAPI pytest " * 80),
            ]
        ),
        sources=["short_term"],
    )

    prompt_text, sources = build_generation_prompt(
        "Ajoute des tests pytest pour une route FastAPI.",
        None,
        memory,
        input_type="text",
    )

    assert "=== HISTORIQUE NON PRIORITAIRE FILTRÉ ===" in prompt_text
    assert "short_term" in sources
    assert "Yahoo Finance" not in prompt_text
    history_section = prompt_text.split("=== HISTORIQUE NON PRIORITAIRE FILTRÉ ===", 1)[1]
    history_section = history_section.split("=== RÈGLES DE RÉPONSE ===", 1)[0]
    assert len(history_section) < 320
    assert history_section.rstrip().endswith("...")


def test_last_user_request_remains_before_non_priority_history() -> None:
    memory = MemoryBundle(
        short_term_text="user: FastAPI pytest ancien contexte.\nassistant: Ancienne réponse pytest.",
        sources=["short_term"],
    )

    prompt_text, _ = build_generation_prompt(
        "Écris un test pytest pour FastAPI.",
        None,
        memory,
        input_type="text",
    )

    assert prompt_text.index("=== DERNIÈRE DEMANDE UTILISATEUR ===") < prompt_text.index(
        "=== HISTORIQUE NON PRIORITAIRE FILTRÉ ==="
    )


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
