from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture.extractors import extract_structured_fields


def test_extract_structured_fields_reads_administrative_fields() -> None:
    text = """
    Assurance Maladie - CPAM
    Date : 12/03/2026
    Nom : JEAN DUPONT
    Numéro de sécurité sociale : 1 84 12 75 123 456 78
    Numéro de créance : CR-2026-001245
    Montant : 123,45 EUR
    IBAN : FR76 3000 6000 0112 3456 7890 189
    BIC : AGRIFRPP
    """

    fields = extract_structured_fields(text)

    assert fields.date == "12/03/2026"
    assert fields.nom == "JEAN DUPONT"
    assert fields.numero_securite_sociale == "1 84 12 75 123 456 78"
    assert fields.numero_creance == "CR-2026-001245"
    assert fields.montant == "123,45 EUR"
    assert fields.iban == "FR76 3000 6000 0112 3456 7890 189"
    assert fields.bic == "AGRIFRPP"


def test_extract_structured_fields_returns_not_found_when_missing() -> None:
    fields = extract_structured_fields("Document sans champs exploitables.")

    assert fields.as_dict() == {
        "date": "non trouvé",
        "nom": "non trouvé",
        "numero_securite_sociale": "non trouvé",
        "numero_creance": "non trouvé",
        "montant": "non trouvé",
        "iban": "non trouvé",
        "bic": "non trouvé",
    }
