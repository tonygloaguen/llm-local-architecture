from __future__ import annotations

from pathlib import Path
import sys
from types import SimpleNamespace

from PIL import Image, ImageDraw
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture import ocr


def test_score_ocr_text_prefers_clean_text() -> None:
    clean = "Bonjour, ceci est un document francais lisible avec plusieurs mots utiles."
    noisy = "@@@ ### ///"

    assert ocr.score_ocr_text(clean, min_text_length=20, mean_confidence=88.0) > ocr.score_ocr_text(
        noisy,
        min_text_length=20,
        mean_confidence=10.0,
    )


def test_build_preprocessing_variants_upscales_small_images() -> None:
    if ocr.cv2 is None or ocr.np is None:
        pytest.skip("OpenCV OCR non installé dans cet environnement de test.")

    image = Image.new("RGB", (80, 40), "white")
    draw = ImageDraw.Draw(image)
    draw.text((5, 10), "Bonjour", fill="black")

    variants = ocr._build_preprocessing_variants(image)

    assert variants
    assert min(variants[0].image.shape[:2]) >= ocr.OCR_MIN_IMAGE_SIDE
    assert all(variant.image.ndim == 2 for variant in variants)


def test_extract_text_from_images_prefers_fallback_language(monkeypatch) -> None:
    image = Image.new("RGB", (120, 60), "white")
    variant = ocr.PreprocessedImage(
        name="adaptive_open",
        image=object(),
        debug_steps=[],
    )

    monkeypatch.setattr(ocr, "_configure_tesseract", lambda: "/usr/bin/tesseract")
    monkeypatch.setattr(ocr, "_select_languages", lambda: ["fra", "fra+eng"])
    monkeypatch.setattr(ocr, "_psm_sequence", lambda: [6])
    monkeypatch.setattr(ocr, "_build_preprocessing_variants", lambda _: [variant])

    def fake_run_tesseract(prepared: object, *, lang: str, psm: int, oem: int) -> tuple[str, float]:
        assert prepared is variant.image
        if lang == "fra":
            return "@@@", 8.0
        return "Bonjour ceci est un texte lisible", 92.0

    monkeypatch.setattr(ocr, "_run_tesseract", fake_run_tesseract)

    assert ocr.extract_text_from_images([image]) == "Bonjour ceci est un texte lisible"


def test_extract_text_from_images_errors_when_tesseract_missing(monkeypatch) -> None:
    image = Image.new("RGB", (50, 50), "white")
    monkeypatch.setattr(ocr, "_ensure_ocr_dependencies", lambda: None)
    monkeypatch.setattr(ocr, "_resolve_tesseract_command", lambda: None)
    monkeypatch.setattr(ocr, "pytesseract", SimpleNamespace(pytesseract=SimpleNamespace()))

    with pytest.raises(RuntimeError, match="Tesseract est introuvable"):
        ocr.extract_text_from_images([image])


def test_select_languages_errors_when_requested_packs_are_missing(monkeypatch) -> None:
    monkeypatch.setattr(ocr, "OCR_TESSERACT_LANG", "fra")
    monkeypatch.setattr(ocr, "OCR_TESSERACT_FALLBACK_LANG", "fra+eng")
    monkeypatch.setattr(ocr, "OCR_ENABLE_MULTI_PASS", True)
    monkeypatch.setattr(ocr, "_available_languages", lambda: {"eng"})

    with pytest.raises(RuntimeError, match="Packs langue Tesseract manquants"):
        ocr._select_languages()
