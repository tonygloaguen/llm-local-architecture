"""Configuration centralisée des modèles et règles de routing."""

from __future__ import annotations

import os
from typing import Any

# URL de base Ollama — configurable via variable d'environnement
OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")

# Port de l'API orchestrateur
ORCHESTRATOR_PORT: int = int(os.getenv("ORCHESTRATOR_PORT", "8001"))

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
            "incident",
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
            "module",
            ".py",
            "def ",
            "class ",
            "import ",
            "```python",
            "code",
            "fonction",
            "function",
            "script",
            "programme",
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
