"""Hiérarchie d'exceptions typées pour les erreurs Ollama."""

from __future__ import annotations


class OllamaError(Exception):
    """Classe de base pour toutes les erreurs Ollama."""


class OllamaUnavailableError(OllamaError):
    """Ollama inaccessible : connexion refusée, réseau down."""


class OllamaModelNotFoundError(OllamaError):
    """Modèle demandé absent d'Ollama (HTTP 404)."""


class OllamaTimeoutError(OllamaError):
    """Timeout dépassé lors de la génération."""


class OllamaGenerationError(OllamaError):
    """Erreur HTTP inattendue (5xx, etc.)."""
