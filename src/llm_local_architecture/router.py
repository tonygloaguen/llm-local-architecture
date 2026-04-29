"""Routeur déterministe par correspondance de mots-clés.

Logique : premier match dans ROUTING_RULES (ordre = priorité) gagne.
Pas d'embedding, pas de ML, latence <1ms.
"""

from __future__ import annotations

import unicodedata

from .config import DEFAULT_MODEL, ROUTING_RULES

CODE_MODEL = "qwen2.5-coder:7b-instruct"

_CODE_ACTION_KEYWORDS = (
    "ajoute",
    "automatise",
    "cree",
    "creer",
    "corrige",
    "developpe",
    "donne moi",
    "ecris",
    "faire",
    "fais",
    "genere",
    "implemente",
    "modifie",
    "patch",
    "produis",
    "refactor",
    "repare",
)
_CODE_OBJECT_KEYWORDS = (
    "api",
    "backup script",
    "bash",
    "classe",
    "code",
    "commande",
    "cron",
    "docker compose",
    "docker-compose",
    "dockerfile",
    "fastapi",
    "fonction",
    "github actions",
    "javascript",
    "patch",
    "powershell",
    "pytest",
    "python",
    "rclone",
    "refactor",
    "ruby",
    "sauvegarde automatisee",
    "script",
    "sh",
    "shell",
    "workflow",
)
_CODE_DIRECT_PATTERNS = (
    "```",
    ".py",
    "#!/bin/bash",
    "#!/usr/bin/env bash",
    "async def ",
    "class ",
    "def ",
    "dockerfile",
    "function ",
    "github actions",
    "import ",
    "set -euo pipefail",
)
_CONCEPTUAL_PREFIXES = (
    "c'est quoi",
    "definition",
    "definis",
    "explique ce qu",
    "explique moi ce qu",
    "qu'est-ce",
    "quelle est la difference",
    "que veut dire",
    "what is",
)

def _normalize(text: str) -> str:
    """Normalise un texte pour un matching simple et robuste."""
    lowered = text.lower()
    decomposed = unicodedata.normalize("NFKD", lowered)
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def is_code_task_request(prompt: str) -> bool:
    """Détecte les demandes qui veulent du code, une commande ou un script."""
    normalized = _normalize(prompt)
    if any(normalized.strip().startswith(prefix) for prefix in _CONCEPTUAL_PREFIXES):
        return False
    if any(pattern in normalized for pattern in _CODE_DIRECT_PATTERNS):
        return True
    has_action = any(keyword in normalized for keyword in _CODE_ACTION_KEYWORDS)
    has_code_object = any(keyword in normalized for keyword in _CODE_OBJECT_KEYWORDS)
    return has_action and has_code_object


def route(prompt: str) -> str:
    """Retourne le nom du modèle le plus adapté pour le prompt donné.

    Parcourt les règles de routing dans l'ordre de priorité.
    Retourne DEFAULT_MODEL si aucune règle ne correspond.

    Args:
        prompt: Le texte de l'utilisateur.

    Returns:
        Nom de modèle Ollama (ex: "granite3.3:8b").
    """
    if is_code_task_request(prompt):
        return CODE_MODEL

    prompt_normalized = _normalize(prompt)
    for rule in ROUTING_RULES:
        for keyword in rule["keywords"]:
            if _normalize(str(keyword)) in prompt_normalized:
                return str(rule["model"])

    return DEFAULT_MODEL
