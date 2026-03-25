"""OCR local configurable, avec Tesseract comme backend par défaut."""

from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image, ImageOps

from .config import OCR_LANG, TESSERACT_CMD

try:
    import pytesseract
except ImportError:  # pragma: no cover
    pytesseract = None  # type: ignore[assignment]


def _is_tesseract_available() -> bool:
    if pytesseract is None:
        return False
    if TESSERACT_CMD:
        pytesseract.pytesseract.tesseract_cmd = TESSERACT_CMD
        return Path(TESSERACT_CMD).exists()
    return shutil.which("tesseract") is not None


def _available_languages() -> set[str]:
    if not _is_tesseract_available():
        return set()
    assert pytesseract is not None
    return set(pytesseract.get_languages(config=""))


def _validate_languages() -> None:
    requested = [lang.strip() for lang in OCR_LANG.split("+") if lang.strip()]
    available = _available_languages()
    if not requested:
        raise RuntimeError("OCR_LANG est vide. Configurez au moins une langue Tesseract.")
    missing = [lang for lang in requested if lang not in available]
    if missing:
        raise RuntimeError(
            "Packs langue Tesseract manquants pour OCR_LANG="
            f"{OCR_LANG}. Langues absentes: {', '.join(missing)}."
        )


def preprocess_image(image: Image.Image) -> Image.Image:
    """Prétraitement local léger avant OCR pour améliorer la robustesse."""
    grayscale = image.convert("L")
    contrasted = ImageOps.autocontrast(grayscale)
    width, height = contrasted.size
    if width < 1400:
        contrasted = contrasted.resize((width * 2, height * 2))
    return contrasted.point(lambda px: 255 if px > 180 else 0)


def extract_text_from_images(images: list[Image.Image]) -> str:
    """OCR local sur une liste d'images."""
    if not _is_tesseract_available():
        raise RuntimeError(
            "Tesseract n'est pas disponible localement. Installez-le et rendez-le accessible dans PATH."
        )
    _validate_languages()
    assert pytesseract is not None
    chunks: list[str] = []
    for image in images:
        prepared = preprocess_image(image)
        chunks.append(
            pytesseract.image_to_string(
                prepared,
                lang=OCR_LANG,
                config="--psm 6",
            ).strip()
        )
    return "\n\n".join(chunk for chunk in chunks if chunk)
