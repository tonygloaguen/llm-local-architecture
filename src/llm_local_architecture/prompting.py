"""Construction du contexte de routage et du prompt final."""

from __future__ import annotations

import unicodedata

from .config import DOCUMENT_EXCERPT_CHARS, ROUTING_EXCERPT_CHARS
from .schemas import MemoryBundle, ProcessedDocument, UserIntent

_SUMMARY_KEYWORDS = (
    "resume",
    "resume-moi",
    "resumer",
    "resum",
    "synthese",
    "synthese",
    "synthétise",
    "synthétiser",
)
_EXTRACTION_KEYWORDS = (
    "extrais",
    "extrait",
    "extraction",
    "identifie",
    "releve",
    "liste",
    "recopie",
)
_DOCUMENT_REFERENCE_KEYWORDS = (
    "document",
    "courrier",
    "fichier",
    "pdf",
    "scan",
    "piece jointe",
    "image jointe",
    "facture",
    "photo",
    "capture",
    "page",
)
_DOCUMENT_CONTEXT_MARKERS = (
    "ci joint",
    "ci-joint",
    "joint",
    "fourni",
    "visible",
    "dans le document",
    "du document",
    "sur le document",
    "dans cette image",
    "dans ce courrier",
    "sur cette facture",
    "dans ce pdf",
)
_DOCUMENT_QA_KEYWORDS = (
    "numero",
    "montant",
    "iban",
    "bic",
    "date",
    "nom",
    "reference",
    "code",
    "adresse",
    "echeance",
    "action",
    "prioritaire",
    "point cle",
)
_ACTION_KEYWORDS = ("action", "actions", "prioritaire", "a effectuer", "a faire")


def _clip(text: str, limit: int) -> str:
    normalized = text.strip()
    if len(normalized) <= limit:
        return normalized
    return normalized[:limit].rstrip() + "..."


def _format_structured_fields(document: ProcessedDocument) -> str:
    fields = document.structured_fields.as_dict()
    lines = [f"{key}={value}" for key, value in fields.items()]
    return "Champs structurés extraits localement:\n" + "\n".join(lines)


def _normalize(text: str) -> str:
    lowered = text.lower()
    decomposed = unicodedata.normalize("NFKD", lowered)
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def _contains_any(text: str, keywords: tuple[str, ...]) -> bool:
    return any(keyword in text for keyword in keywords)


def _has_inline_payload(prompt: str) -> bool:
    stripped = prompt.strip()
    if "\n" in stripped:
        return True
    if ":" not in stripped:
        return False
    _, tail = stripped.split(":", 1)
    return len(tail.strip()) >= 40


def _is_action_request(prompt_normalized: str) -> bool:
    return _contains_any(prompt_normalized, _ACTION_KEYWORDS)


def classify_user_intent(prompt: str, has_document: bool) -> UserIntent:
    """Infère une intention simple, déterministe et testable."""
    normalized = _normalize(prompt)
    has_inline_payload = _has_inline_payload(prompt)
    has_document_reference = _contains_any(normalized, _DOCUMENT_REFERENCE_KEYWORDS) or _contains_any(
        normalized,
        _DOCUMENT_CONTEXT_MARKERS,
    )
    is_summary = _contains_any(normalized, _SUMMARY_KEYWORDS)
    is_extraction = _contains_any(normalized, _EXTRACTION_KEYWORDS)
    is_document_qa = (
        has_document
        and (
            has_document_reference
            or _contains_any(normalized, _DOCUMENT_QA_KEYWORDS)
            or _is_action_request(normalized)
        )
    )

    if is_extraction:
        category = "extraction"
    elif is_summary:
        category = "summary"
    elif is_document_qa:
        category = "document_qa"
    else:
        category = "qa_simple"

    requires_document = has_document_reference and not has_inline_payload
    use_document = has_document and (
        category in {"extraction", "document_qa"}
        or (category == "summary" and (has_document_reference or not has_inline_payload))
    )

    if category == "qa_simple" and not has_document_reference:
        use_document = False

    return UserIntent(
        category=category,
        document_policy="document_required" if requires_document else "document_optional",
        use_document=use_document,
        concise=category in {"qa_simple", "extraction", "document_qa"},
    )


def build_routing_text(
    prompt: str,
    document: ProcessedDocument | None,
    memory: MemoryBundle,
) -> str:
    """Construit un texte de routage explicable à partir du contexte courant."""
    # NOTE: plus utilisée pour le routing depuis LOT 1 — conservée pour debug.
    effective_prompt = prompt.strip() or "Resume le document fourni et reponds de maniere structuree."
    parts: list[str] = [effective_prompt]

    if document is not None:
        parts.extend(
            [
                "document_uploaded",
                f"document_type:{document.source_type}",
                f"extraction:{document.extraction_method}",
            ]
        )
        if document.ocr_used:
            parts.append("ocr_used")
        parts.append(document.filename)
        parts.append(_clip(document.text, ROUTING_EXCERPT_CHARS))

    return " ".join(part for part in parts if part)


def build_generation_prompt(
    prompt: str,
    document: ProcessedDocument | None,
    memory: MemoryBundle,
    input_type: str = "text",
    intent: UserIntent | None = None,
) -> tuple[str, list[str]]:
    """Construit le prompt final envoyé à Ollama.

    Ordre de priorité (jamais tronqué -> tronqué en dernier) :
      1. system (fixe)
      2. user_message (protégé)
      3. history
      4. document + rules
      5. preferences
    """
    from .config import HISTORY_MAX_CHARS  # noqa: PLC0415

    sources = list(memory.sources)
    user_message = prompt.strip() or "Résume le document fourni, identifie son type, puis réponds de manière structurée."
    active_intent = intent or classify_user_intent(user_message, document is not None)
    sections = ["Tu es un assistant local exécuté hors ligne.", f"Demande utilisateur:\n{user_message}"]

    if memory.short_term_text:
        sections.append(f"Historique de session récent:\n{_clip(memory.short_term_text, HISTORY_MAX_CHARS)}")

    if document is not None:
        document_heading = "Texte OCR prioritaire" if input_type in {"document", "text+document"} else "Document courant"
        doc_text = document.text.strip()
        truncated = False
        if len(doc_text) > DOCUMENT_EXCERPT_CHARS:
            doc_text = doc_text[:DOCUMENT_EXCERPT_CHARS].rstrip()
            truncated = True

        doc_block = (
            f"{document_heading}:\n"
            f"nom={document.filename}\n"
            f"type={document.source_type}\n"
            f"ocr_used={document.ocr_used}\n"
            f"extraction={document.extraction_method}\n"
            f"contenu=\n{doc_text}"
        )
        if truncated:
            doc_block += "\n[... DOCUMENT TRONQUÉ — suite omise pour respecter la limite de contexte ...]"

        sections.append(
            doc_block
        )
        sections.append(_format_structured_fields(document))
        sections.append(
            "Règles de réponse documentaires:\n"
            "Réponds uniquement à partir du texte OCR/extrait et des champs structurés ci-dessus.\n"
            "N'invente rien et n'utilise aucune connaissance externe.\n"
            "Si l'information demandée n'est pas présente dans ce texte, réponds qu'elle est absente du document."
        )
        if "documentary" not in sources:
            sources.append("documentary")

    if memory.preferences_text:
        sections.append(f"Préférences utilisateur:\n{_clip(memory.preferences_text, 500)}")

    normalized_prompt = _normalize(user_message)
    if active_intent.category == "qa_simple":
        sections.append(
            "Règles de réponse:\n"
            "Réponds de manière courte, directe et exploitable.\n"
            "N'ajoute pas d'explication inutile."
        )
    elif active_intent.category == "summary":
        if _is_action_request(normalized_prompt):
            sections.append(
                "Règles de réponse:\n"
                "Produis uniquement une liste d'actions concrètes et prioritaires issues du contenu.\n"
                "Ne rédige pas un résumé générique.\n"
                "N'ajoute aucune action absente du contenu."
            )
        else:
            sections.append(
                "Règles de réponse:\n"
                "Fais un résumé fidèle au contenu fourni.\n"
                "N'ajoute aucune interprétation, hypothèse ou conclusion absente du contenu."
            )
    elif active_intent.category == "extraction":
        sections.append(
            "Règles de réponse:\n"
            "Réponds uniquement avec les champs explicitement demandés par l'utilisateur.\n"
            "N'ajoute aucun champ supplémentaire.\n"
            "Pour chaque champ demandé mais absent, réponds exactement `absent`.\n"
            "Utilise une ligne par champ demandé."
        )
    elif active_intent.category == "document_qa":
        if _is_action_request(normalized_prompt):
            sections.append(
                "Règles de réponse:\n"
                "Réponds uniquement sous forme de liste d'actions concrètes et prioritaires.\n"
                "Ne fournis pas de résumé générique.\n"
                "N'ajoute rien qui ne soit pas appuyé par le document."
            )
        else:
            sections.append(
                "Règles de réponse:\n"
                "Réponds uniquement à la question posée.\n"
                "Si l'information demandée n'est pas présente, réponds exactement `absent du document`.\n"
                "N'ajoute aucune autre information."
            )

    prompt_text = "\n\n".join(sections)
    return prompt_text, sources
