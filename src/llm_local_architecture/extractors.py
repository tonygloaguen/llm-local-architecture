"""Extraction structurée légère pour documents administratifs OCRisés."""

from __future__ import annotations

import re
import unicodedata

from .schemas import StructuredDocumentFields

_NOT_FOUND = "non trouvé"
_DATE_RE = re.compile(r"\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b")
_MONTANT_RE = re.compile(r"(\d[\d .]*(?:,\d{2})\s*(?:€|eur|euros))", re.IGNORECASE)
_IBAN_RE = re.compile(r"\b([A-Z]{2}\d{2}(?:[\s.-]?[A-Z0-9]{2,5}){4,8})\b")
_BIC_RE = re.compile(r"\b([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b")
_NSS_RE = re.compile(r"\b([12]\s?\d{2}(?:[\s.-]?\d{2}){5}[\s.-]?\d{3}[\s.-]?\d{2})\b")


def _normalized_lines(text: str) -> list[tuple[str, str]]:
    lines: list[tuple[str, str]] = []
    for raw_line in text.splitlines():
        line = " ".join(raw_line.split()).strip()
        if not line:
            continue
        normalized = unicodedata.normalize("NFKD", line.casefold())
        normalized = "".join(char for char in normalized if not unicodedata.combining(char))
        lines.append((line, normalized))
    return lines


def _clean_match(value: str) -> str:
    return " ".join(value.split()).strip(" .:;-")


def _first_match(pattern: re.Pattern[str], text: str) -> str:
    match = pattern.search(text)
    if match is None:
        return _NOT_FOUND
    return _clean_match(match.group(1))


def _extract_from_labeled_line(
    normalized_lines: list[tuple[str, str]],
    labels: tuple[str, ...],
    *,
    value_pattern: re.Pattern[str] | None = None,
) -> str:
    for original, normalized in normalized_lines:
        if not any(label in normalized for label in labels):
            continue
        if value_pattern is not None:
            match = value_pattern.search(original)
            if match is not None:
                return _clean_match(match.group(1))
        if ":" in original:
            _, value = original.split(":", 1)
            cleaned = _clean_match(value)
            if cleaned:
                return cleaned
    return _NOT_FOUND


def _extract_name(normalized_lines: list[tuple[str, str]]) -> str:
    label_value = _extract_from_labeled_line(
        normalized_lines,
        ("nom", "assure", "assuree", "beneficiaire", "destinataire"),
    )
    if label_value != _NOT_FOUND:
        return label_value

    uppercase_candidate_re = re.compile(r"\b([A-Z][A-Z' -]{2,})\b")
    for original, normalized in normalized_lines:
        if "cpam" in normalized or "assurance maladie" in normalized:
            continue
        match = uppercase_candidate_re.search(original)
        if match is not None:
            candidate = _clean_match(match.group(1))
            if len(candidate.split()) >= 2:
                return candidate
    return _NOT_FOUND


def _labeled_or_first_match(
    normalized_lines: list[tuple[str, str]],
    labels: tuple[str, ...],
    pattern: re.Pattern[str],
    text: str,
) -> str:
    labeled_match = _extract_from_labeled_line(normalized_lines, labels, value_pattern=pattern)
    if labeled_match != _NOT_FOUND:
        return labeled_match
    return _first_match(pattern, text)


def extract_structured_fields(text: str) -> StructuredDocumentFields:
    """Extrait quelques champs génériques à partir d'un OCR bruité."""
    normalized_lines = _normalized_lines(text)
    numero_creance_re = re.compile(r"([A-Z0-9][A-Z0-9 ./-]{4,})")

    return StructuredDocumentFields(
        date=_labeled_or_first_match(normalized_lines, ("date",), _DATE_RE, text),
        nom=_extract_name(normalized_lines),
        numero_securite_sociale=_labeled_or_first_match(
            normalized_lines,
            ("securite sociale", "numero de securite sociale", "n ss", "nss"),
            _NSS_RE,
            text,
        ),
        numero_creance=_extract_from_labeled_line(
            normalized_lines,
            ("creance", "numero de creance", "reference"),
            value_pattern=numero_creance_re,
        ),
        montant=_labeled_or_first_match(
            normalized_lines,
            ("montant", "somme", "a payer", "reste a payer"),
            _MONTANT_RE,
            text,
        ),
        iban=_labeled_or_first_match(normalized_lines, ("iban",), _IBAN_RE, text),
        bic=_labeled_or_first_match(normalized_lines, ("bic",), _BIC_RE, text),
    )
