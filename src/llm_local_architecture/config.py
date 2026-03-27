"""Configuration centralisée des modèles et règles de routing."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any


def _get_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


def _get_int(name: str, default: int) -> int:
    return int(os.getenv(name, str(default)))


# URL de base Ollama — configurable via variable d'environnement
OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_ENFORCE_SINGLE_MODEL_RESIDENCY: bool = _get_bool(
    "OLLAMA_ENFORCE_SINGLE_MODEL_RESIDENCY",
    True,
)
OLLAMA_GENERATE_KEEP_ALIVE: str = os.getenv("OLLAMA_GENERATE_KEEP_ALIVE", "0")

# Port de l'API orchestrateur
ORCHESTRATOR_PORT: int = _get_int("ORCHESTRATOR_PORT", 8001)

# Répertoires locaux de l'application
# Par défaut, le stockage persistant est ancré à la racine du repo dans ./data
# pour rester lisible et cohérent sur Windows/Linux. Il peut être surchargé via
# LLM_LOCAL_DATA_DIR pour un autre emplacement explicite.
PROJECT_ROOT: Path = Path(__file__).resolve().parents[2]
DEFAULT_APP_DATA_DIR: Path = PROJECT_ROOT / "data"
APP_DATA_DIR: Path = Path(os.getenv("LLM_LOCAL_DATA_DIR", str(DEFAULT_APP_DATA_DIR))).resolve()
APP_DB_PATH: Path = APP_DATA_DIR / "app.db"
DOCUMENTS_DIR: Path = APP_DATA_DIR / "documents"
EXTRACTED_DIR: Path = APP_DATA_DIR / "extracted"
OCR_DIR: Path = APP_DATA_DIR / "ocr"
STATIC_DIR: Path = Path(__file__).resolve().parent / "static"

# Réglages mémoire / contexte
SHORT_TERM_MESSAGE_LIMIT: int = _get_int("SHORT_TERM_MESSAGE_LIMIT", 8)
MAX_CONTEXT_CHARS: int = _get_int("MAX_CONTEXT_CHARS", 12000)
HISTORY_MAX_CHARS: int = _get_int("HISTORY_MAX_CHARS", 1500)
DOCUMENT_EXCERPT_CHARS: int = _get_int("DOCUMENT_EXCERPT_CHARS", 6000)
ROUTING_EXCERPT_CHARS: int = _get_int("ROUTING_EXCERPT_CHARS", 1200)

# Réglages OCR
OCR_ENABLED: bool = _get_bool("OCR_ENABLED", True)
OCR_TESSERACT_LANG: str = os.getenv("OCR_TESSERACT_LANG", os.getenv("OCR_LANG", "fra"))
OCR_TESSERACT_FALLBACK_LANG: str = os.getenv("OCR_TESSERACT_FALLBACK_LANG", "fra+eng")
OCR_TESSERACT_PSM: int = _get_int("OCR_TESSERACT_PSM", 6)
OCR_TESSERACT_SPARSE_PSM: int = _get_int("OCR_TESSERACT_SPARSE_PSM", 11)
OCR_TESSERACT_OEM: int = _get_int("OCR_TESSERACT_OEM", 3)
OCR_ENABLE_DESKEW: bool = _get_bool("OCR_ENABLE_DESKEW", True)
OCR_ENABLE_MULTI_PASS: bool = _get_bool("OCR_ENABLE_MULTI_PASS", True)
OCR_MIN_TEXT_LENGTH: int = _get_int("OCR_MIN_TEXT_LENGTH", 20)
OCR_MIN_EXTRACTED_CHARS: int = _get_int("OCR_MIN_EXTRACTED_CHARS", 80)
OCR_DPI: int = _get_int("OCR_DPI", 200)
OCR_DEBUG_SAVE_INTERMEDIATES: bool = _get_bool("OCR_DEBUG_SAVE_INTERMEDIATES", False)
OCR_MIN_IMAGE_SIDE: int = _get_int("OCR_MIN_IMAGE_SIDE", 1400)
TESSERACT_CMD: str = os.getenv("OCR_TESSERACT_CMD", os.getenv("TESSERACT_CMD", ""))

# Modèle de fallback si le modèle routé n'est pas disponible
DEFAULT_MODEL: str = "phi4-mini"

# Catalogue des modèles disponibles avec leurs métadonnées
MODEL_CATALOG: dict[str, dict[str, Any]] = {
    "granite3.3:8b": {
        "role": "audit",
        "description": "Audit sécurité, DevSecOps, CI/CD, NIS2",
        "vram_gb": 4.9,
    },
    "qwen2.5-coder:7b-instruct": {
        "role": "code",
        "description": "Code Python, FastAPI, LangGraph, debug code",
        "vram_gb": 4.1,
    },
    "deepseek-r1:7b": {
        "role": "agent",
        "description": "Raisonnement, orchestration, planification",
        "vram_gb": 4.5,
    },
    "phi4-mini": {
        "role": "debug",
        "description": "Debug rapide, sanity check, questions courtes (permanent VRAM)",
        "vram_gb": 2.4,
    },
    "mistral:7b-instruct-v0.3-q4_K_M": {
        "role": "redaction",
        "description": "Rédaction française, documents, synthèse",
        "vram_gb": 4.1,
    },
}

# Règles de routing — ordre = priorité (premier match gagne)
ROUTING_RULES: list[dict[str, Any]] = [
    {
        "model": "granite3.3:8b",
        "role": "audit",
        "keywords": [
            "dockerfile",
            "github actions",
            "ci/cd",
            "cve",
            "vulnerability",
            "trivy",
            "gitleaks",
            "checkov",
            "bandit",
            "pip-audit",
            "supply chain",
            "sast",
            "dast",
            "owasp",
            "secret",
            "credentials",
            "audit",
            "pentest",
            "nis2",
            "anssi",
            "sigma",
            "mitre",
            "att&ck",
            "siem",
            "revue de code sécurité",
            "durcissement",
            "hardening",
        ],
    },
    {
        "model": "qwen2.5-coder:7b-instruct",
        "role": "code",
        "keywords": [
            "python",
            "fastapi",
            "sqlalchemy",
            "langgraph",
            "asyncio",
            "async def",
            "pydantic",
            "pytest",
            "docker-compose",
            "bash script",
            "arm64",
            "raspberry pi",
            "playwright",
            "langchain",
            "openai sdk",
            "refactor",
            "génère",
            "génère le code",
            "implémente",
            ".py",
            "def ",
            "fonction python",
            "class ",
            "import ",
            "```python",
            "code python",
            "bout de code",
            "function",
            "programme python",
            "script python",
        ],
    },
    {
        "model": "deepseek-r1:7b",
        "role": "agent",
        "keywords": [
            "orchestr",
            "planifie",
            "décompose",
            "stratégie",
            "workflow",
            "étapes",
            "multi-étapes",
            "décide",
            "agent",
            "graph",
            "node",
            "raisonne",
            "analyse",
            "pourquoi",
            "cause",
            "root cause",
            "architecture",
            "conception",
            "plan",
        ],
    },
    {
        "model": "mistral:7b-instruct-v0.3-q4_K_M",
        "role": "redaction",
        "keywords": [
            "rédige",
            "reformule",
            "synthèse",
            "linkedin",
            "mail",
            "email",
            "professionnel",
            "rapport",
            "résumé",
            "présentation",
            "post",
            "lettre",
            "document",
            "note de synthèse",
            "compte rendu",
            "rédaction",
        ],
    },
    {
        "model": "phi4-mini",
        "role": "debug",
        "keywords": [
            "erreur",
            "error",
            "traceback",
            "exception",
            "bug",
            "crash",
            "broken",
            "quick",
            "explain briefly",
            "what is",
            "en une ligne",
            "sanity check",
            "vite",
            "rapide",
            "simple",
        ],
    },
]
