"""OCR local robuste basé sur Tesseract et OpenCV."""

from __future__ import annotations

from dataclasses import dataclass
import logging
import re
import shutil
import tempfile
from pathlib import Path
from statistics import mean
from typing import Any

from PIL import Image

from .config import (
    OCR_DEBUG_SAVE_INTERMEDIATES,
    OCR_DIR,
    OCR_ENABLE_DESKEW,
    OCR_ENABLE_MULTI_PASS,
    OCR_MIN_IMAGE_SIDE,
    OCR_MIN_TEXT_LENGTH,
    OCR_TESSERACT_FALLBACK_LANG,
    OCR_TESSERACT_LANG,
    OCR_TESSERACT_OEM,
    OCR_TESSERACT_PSM,
    OCR_TESSERACT_SPARSE_PSM,
    TESSERACT_CMD,
)

try:
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None  # type: ignore[assignment]

try:
    import numpy as np
except ImportError:  # pragma: no cover
    np = None  # type: ignore[assignment]

try:
    import pytesseract
except ImportError:  # pragma: no cover
    pytesseract = None  # type: ignore[assignment]


logger = logging.getLogger(__name__)

_WORD_RE = re.compile(r"[A-Za-zÀ-ÖØ-öø-ÿ]{2,}(?:['’-][A-Za-zÀ-ÖØ-öø-ÿ]{2,})?")
_TOKEN_RE = re.compile(r"\S+")
_ABERRANT_CHAR_RE = re.compile(r"[^0-9A-Za-zÀ-ÖØ-öø-ÿ\s.,;:!?%/()'\"°@&+\-€$£#_=*]")
_COMMON_WORDS = {
    "a",
    "au",
    "aux",
    "avec",
    "ce",
    "ces",
    "dans",
    "de",
    "des",
    "du",
    "elle",
    "en",
    "et",
    "est",
    "je",
    "la",
    "le",
    "les",
    "mais",
    "ou",
    "par",
    "pas",
    "pour",
    "que",
    "qui",
    "sur",
    "une",
    "un",
    "the",
    "and",
    "for",
    "with",
}
_WINDOWS_TESSERACT_CANDIDATES = (
    Path(r"C:\Program Files\Tesseract-OCR\tesseract.exe"),
    Path(r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"),
)


@dataclass(slots=True)
class PreprocessedImage:
    name: str
    image: np.ndarray[Any, Any]
    debug_steps: list[tuple[str, np.ndarray[Any, Any]]]


@dataclass(slots=True)
class OCRCandidate:
    text: str
    score: float
    mean_confidence: float
    lang: str
    psm: int
    oem: int
    variant: str


def _resolve_tesseract_command() -> str | None:
    if TESSERACT_CMD:
        candidate = Path(TESSERACT_CMD)
        return str(candidate) if candidate.exists() else None

    discovered = shutil.which("tesseract")
    if discovered:
        return discovered

    for candidate in _WINDOWS_TESSERACT_CANDIDATES:
        if candidate.exists():
            return str(candidate)
    return None


def _ensure_ocr_dependencies() -> None:
    if cv2 is None or np is None:
        raise RuntimeError(
            "OpenCV OCR indisponible. Installez les dépendances Python du projet "
            "avant d'utiliser l'extraction sur images ou scans."
        )


def _configure_tesseract() -> str:
    _ensure_ocr_dependencies()
    if pytesseract is None:
        raise RuntimeError(
            "pytesseract n'est pas installé. Ajoutez les dépendances Python OCR avant d'utiliser ce flux."
        )

    command = _resolve_tesseract_command()
    if command is None:
        raise RuntimeError(
            "Tesseract est introuvable. Installez le binaire localement puis configurez "
            "OCR_TESSERACT_CMD ou TESSERACT_CMD si nécessaire."
        )

    pytesseract.pytesseract.tesseract_cmd = command
    return command


def _available_languages() -> set[str]:
    _configure_tesseract()
    assert pytesseract is not None
    return set(pytesseract.get_languages(config=""))


def _normalize_lang(lang: str) -> str:
    return "+".join(part.strip() for part in lang.split("+") if part.strip())


def _select_languages() -> list[str]:
    primary = _normalize_lang(OCR_TESSERACT_LANG)
    fallback = _normalize_lang(OCR_TESSERACT_FALLBACK_LANG)
    if not primary:
        raise RuntimeError("OCR_TESSERACT_LANG est vide. Configurez au moins une langue Tesseract.")

    requested = [primary]
    if OCR_ENABLE_MULTI_PASS and fallback and fallback != primary:
        requested.append(fallback)

    available = _available_languages()
    missing_by_lang: dict[str, list[str]] = {}
    selected: list[str] = []

    for lang in requested:
        missing = [part for part in lang.split("+") if part not in available]
        if missing:
            missing_by_lang[lang] = missing
            continue
        selected.append(lang)

    if selected:
        if missing_by_lang:
            logger.warning("OCR fallback language unavailable: %s", missing_by_lang)
        return selected

    missing_details = ", ".join(
        f"{lang} -> {', '.join(parts)}" for lang, parts in missing_by_lang.items()
    )
    raise RuntimeError(
        "Packs langue Tesseract manquants. Configurez les données demandées "
        f"({requested}) et installez au minimum 'fra'. Détail: {missing_details}."
    )


def _pil_to_bgr(image: Image.Image) -> np.ndarray[Any, Any]:
    rgb = image.convert("RGB")
    rgb_array = np.array(rgb)
    return cv2.cvtColor(rgb_array, cv2.COLOR_RGB2BGR)


def _ensure_min_size(image: np.ndarray[Any, Any]) -> np.ndarray[Any, Any]:
    height, width = image.shape[:2]
    shortest_side = min(height, width)
    if shortest_side >= OCR_MIN_IMAGE_SIDE:
        return image

    scale = OCR_MIN_IMAGE_SIDE / max(shortest_side, 1)
    return cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)


def _deskew_image(image: np.ndarray[Any, Any]) -> np.ndarray[Any, Any]:
    if not OCR_ENABLE_DESKEW:
        return image

    non_white_points = np.column_stack(np.where(image < 245))
    if non_white_points.size == 0:
        return image

    angle = cv2.minAreaRect(non_white_points)[-1]
    if angle < -45:
        angle = 90 + angle
    elif angle > 45:
        angle = angle - 90

    if abs(angle) < 0.3:
        return image

    height, width = image.shape[:2]
    center = (width / 2, height / 2)
    matrix = cv2.getRotationMatrix2D(center, angle, 1.0)
    return cv2.warpAffine(
        image,
        matrix,
        (width, height),
        flags=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=255,
    )


def _build_preprocessing_variants(image: Image.Image) -> list[PreprocessedImage]:
    color = _ensure_min_size(_pil_to_bgr(image))
    gray = cv2.cvtColor(color, cv2.COLOR_BGR2GRAY)
    denoised = cv2.fastNlMeansDenoising(gray, None, 12, 7, 21)
    contrast = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8)).apply(denoised)
    deskewed = _deskew_image(contrast)
    padded = cv2.copyMakeBorder(
        deskewed,
        18,
        18,
        18,
        18,
        cv2.BORDER_CONSTANT,
        value=255,
    )

    _, otsu = cv2.threshold(padded, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    adaptive = cv2.adaptiveThreshold(
        padded,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY,
        31,
        11,
    )
    morph_kernel = np.ones((2, 2), np.uint8)
    opened = cv2.morphologyEx(adaptive, cv2.MORPH_OPEN, morph_kernel)
    closed = cv2.morphologyEx(otsu, cv2.MORPH_CLOSE, morph_kernel)

    gray_std = float(np.std(gray))
    looks_like_photo = gray_std > 55
    variants = [
        PreprocessedImage(
            name="adaptive_open",
            image=opened,
            debug_steps=[
                ("grayscale", gray),
                ("denoised", denoised),
                ("contrast", contrast),
                ("deskewed", deskewed),
                ("adaptive", adaptive),
                ("adaptive_open", opened),
            ],
        ),
        PreprocessedImage(
            name="otsu_close",
            image=closed,
            debug_steps=[
                ("grayscale", gray),
                ("denoised", denoised),
                ("contrast", contrast),
                ("deskewed", deskewed),
                ("otsu", otsu),
                ("otsu_close", closed),
            ],
        ),
        PreprocessedImage(
            name="contrast_gray",
            image=padded,
            debug_steps=[
                ("grayscale", gray),
                ("denoised", denoised),
                ("contrast", contrast),
                ("deskewed", deskewed),
                ("contrast_gray", padded),
            ],
        ),
    ]
    if looks_like_photo:
        variants.insert(
            0,
            PreprocessedImage(
                name="photo_adaptive",
                image=adaptive,
                debug_steps=[
                    ("grayscale", gray),
                    ("denoised", denoised),
                    ("contrast", contrast),
                    ("deskewed", deskewed),
                    ("photo_adaptive", adaptive),
                ],
            ),
        )
    return variants


def _psm_sequence() -> list[int]:
    psms = [OCR_TESSERACT_PSM]
    if OCR_ENABLE_MULTI_PASS and OCR_TESSERACT_SPARSE_PSM not in psms:
        psms.append(OCR_TESSERACT_SPARSE_PSM)
    return psms


def score_ocr_text(text: str, *, min_text_length: int = OCR_MIN_TEXT_LENGTH, mean_confidence: float = 0.0) -> float:
    normalized = text.strip()
    if not normalized:
        return -1000.0

    compact = re.sub(r"\s+", " ", normalized)
    total_chars = len(compact)
    tokens = _TOKEN_RE.findall(compact)
    words = _WORD_RE.findall(compact)
    alnum_chars = sum(char.isalnum() for char in compact)
    aberrant_chars = len(_ABERRANT_CHAR_RE.findall(compact))
    common_hits = sum(1 for word in words if word.lower() in _COMMON_WORDS)

    alnum_ratio = alnum_chars / max(total_chars, 1)
    word_ratio = len(words) / max(len(tokens), 1)
    aberrant_ratio = aberrant_chars / max(total_chars, 1)
    common_word_ratio = common_hits / max(len(words), 1)

    score = 0.0
    score += min(total_chars / max(min_text_length, 1), 2.0) * 2.5
    score += alnum_ratio * 3.0
    score += word_ratio * 2.5
    score += common_word_ratio * 1.5
    score += max(mean_confidence, 0.0) / 100.0
    score -= aberrant_ratio * 8.0
    if total_chars < min_text_length:
        score -= 2.5
    return score


def _to_pil_image(image: np.ndarray[Any, Any]) -> Image.Image:
    return Image.fromarray(image)


def _tesseract_config(psm: int, oem: int) -> str:
    return f"--oem {oem} --psm {psm} -c preserve_interword_spaces=1"


def _mean_confidence(data: dict[str, list[Any]]) -> float:
    confidences: list[float] = []
    for raw_value in data.get("conf", []):
        try:
            value = float(raw_value)
        except (TypeError, ValueError):
            continue
        if value >= 0:
            confidences.append(value)
    if not confidences:
        return 0.0
    return mean(confidences)


def _run_tesseract(image: np.ndarray[Any, Any], *, lang: str, psm: int, oem: int) -> tuple[str, float]:
    _configure_tesseract()
    assert pytesseract is not None
    pil_image = _to_pil_image(image)
    config = _tesseract_config(psm, oem)
    text = pytesseract.image_to_string(pil_image, lang=lang, config=config).strip()
    data = pytesseract.image_to_data(
        pil_image,
        lang=lang,
        config=config,
        output_type=pytesseract.Output.DICT,
    )
    return text, _mean_confidence(data)


def _save_debug_images(variant: PreprocessedImage, debug_dir: Path, page_index: int) -> None:
    for step_name, step_image in variant.debug_steps:
        output_path = debug_dir / f"page{page_index:02d}_{variant.name}_{step_name}.png"
        cv2.imwrite(str(output_path), step_image)


def _build_debug_dir() -> Path | None:
    if not OCR_DEBUG_SAVE_INTERMEDIATES:
        return None
    OCR_DIR.mkdir(parents=True, exist_ok=True)
    path = Path(tempfile.mkdtemp(prefix="ocr-debug-", dir=str(OCR_DIR)))
    logger.info("OCR debug intermediates saved in %s", path)
    return path


def _extract_best_text_from_image(image: Image.Image, *, page_index: int, debug_dir: Path | None) -> OCRCandidate:
    candidates: list[OCRCandidate] = []
    languages = _select_languages()
    variants = _build_preprocessing_variants(image)

    for variant in variants:
        if debug_dir is not None:
            _save_debug_images(variant, debug_dir, page_index)
        for psm in _psm_sequence():
            for lang in languages:
                text, mean_confidence = _run_tesseract(
                    variant.image,
                    lang=lang,
                    psm=psm,
                    oem=OCR_TESSERACT_OEM,
                )
                score = score_ocr_text(
                    text,
                    min_text_length=OCR_MIN_TEXT_LENGTH,
                    mean_confidence=mean_confidence,
                )
                candidates.append(
                    OCRCandidate(
                        text=text,
                        score=score,
                        mean_confidence=mean_confidence,
                        lang=lang,
                        psm=psm,
                        oem=OCR_TESSERACT_OEM,
                        variant=variant.name,
                    )
                )

    best_candidate = max(candidates, key=lambda candidate: candidate.score)
    logger.info(
        "OCR page=%s variant=%s lang=%s psm=%s oem=%s score=%.2f confidence=%.2f",
        page_index,
        best_candidate.variant,
        best_candidate.lang,
        best_candidate.psm,
        best_candidate.oem,
        best_candidate.score,
        best_candidate.mean_confidence,
    )
    return best_candidate


def extract_text_from_images(images: list[Image.Image]) -> str:
    """OCR local multi-pass sur une liste d'images."""
    if not images:
        return ""

    _configure_tesseract()
    _select_languages()
    debug_dir = _build_debug_dir()
    chunks: list[str] = []

    for page_index, image in enumerate(images, start=1):
        best_candidate = _extract_best_text_from_image(image, page_index=page_index, debug_dir=debug_dir)
        if best_candidate.text:
            chunks.append(best_candidate.text)

    return "\n\n".join(chunks).strip()
