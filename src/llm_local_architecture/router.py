"""Routeur déterministe par correspondance de mots-clés.

Logique : premier match dans ROUTING_RULES (ordre = priorité) gagne.
Pas d'embedding, pas de ML, latence <1ms.
"""

from __future__ import annotations

import unicodedata

from .config import DEFAULT_MODEL, ROUTING_RULES


def _normalize(text: str) -> str:
    """Normalise un texte pour un matching simple et robuste."""
    lowered = text.lower()
    decomposed = unicodedata.normalize("NFKD", lowered)
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def route(prompt: str) -> str:
    """Retourne le nom du modèle le plus adapté pour le prompt donné.

    Parcourt les règles de routing dans l'ordre de priorité.
    Retourne DEFAULT_MODEL si aucune règle ne correspond.

    Args:
        prompt: Le texte de l'utilisateur.

    Returns:
        Nom de modèle Ollama (ex: "granite3.3:8b").
    """
    prompt_normalized = _normalize(prompt)

    for rule in ROUTING_RULES:
        for keyword in rule["keywords"]:
            if _normalize(str(keyword)) in prompt_normalized:
                return str(rule["model"])

    return DEFAULT_MODEL
