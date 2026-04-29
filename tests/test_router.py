"""Tests unitaires pour la logique de routing.

Aucun appel Ollama requis — tests purement déterministes.
"""

from __future__ import annotations

import pytest

from llm_local_architecture.router import route


@pytest.mark.parametrize(
    "prompt,expected_model",
    [
        # ── Code (priorité 1) ──────────────────────────────────────────────────
        ("Audite ce Dockerfile", "qwen2.5-coder:7b-instruct"),
        ("Génère un module FastAPI avec async def", "qwen2.5-coder:7b-instruct"),
        ("Implémente cette classe Python", "qwen2.5-coder:7b-instruct"),
        ("Refactor ce script bash", "qwen2.5-coder:7b-instruct"),
        ("```python\ndef foo(): pass", "qwen2.5-coder:7b-instruct"),
        ("Génère le code pour ce module pytest", "qwen2.5-coder:7b-instruct"),
        ("Patch Python pour corriger ce bugfix", "qwen2.5-coder:7b-instruct"),
        ("Corrige ce workflow GitHub Actions", "qwen2.5-coder:7b-instruct"),
        # ── Balanced / deep pivot Qwen3 ───────────────────────────────────────
        ("Revue de sécurité du pipeline CI/CD", "qwen3:8b"),
        ("Trivy scan results show CVE-2023-1234", "qwen3:8b"),
        ("Hardening de ce serveur nginx", "qwen3:8b"),
        ("Scan gitleaks sur ce repo", "qwen3:8b"),
        ("Checkov rapport sur ce compose", "qwen3:8b"),
        ("Planifie les étapes de ce workflow", "qwen3:8b"),
        ("Décompose cette architecture en modules", "qwen3:8b"),
        ("Stratégie de migration de base de données", "qwen3:8b"),
        ("Root cause analysis de cet incident", "qwen3:8b"),
        ("Rédige un mail professionnel pour ce client", "qwen3:8b"),
        ("Synthèse de ce document technique", "qwen3:8b"),
        ("Reformule ce compte rendu de réunion", "qwen3:8b"),
        # ── Debug rapide (priorité 5) ──────────────────────────────────────────
        ("traceback RuntimeError dans ce script", "phi4-mini"),
        ("Sanity check rapide de cette config", "phi4-mini"),
        ("Exception KeyError line 42", "phi4-mini"),
        # ── Fallback (aucun keyword) ───────────────────────────────────────────
        ("Bonjour", "phi4-mini"),
        ("42", "phi4-mini"),
        ("", "phi4-mini"),
    ],
)
def test_route(prompt: str, expected_model: str) -> None:
    assert route(prompt) == expected_model


def test_route_priority_audit_over_code() -> None:
    """Les demandes de patch/code gardent la priorité sur l'audit legacy."""
    prompt = "Génère du code Python pour scanner les CVE d'un Dockerfile"
    assert route(prompt) == "qwen2.5-coder:7b-instruct"


def test_route_returns_str() -> None:
    assert isinstance(route("n'importe quoi"), str)


def test_route_case_insensitive() -> None:
    """Le routing ne doit pas dépendre de la casse."""
    assert route("AUDIT ce Dockerfile") == route("audit ce dockerfile")
    assert route("Python FastAPI module") == route("python fastapi module")


def test_route_nonempty_result() -> None:
    """Le routeur ne retourne jamais une chaîne vide."""
    assert route("") != ""
    assert route("   ") != ""


def test_router_false_positive_code_postal() -> None:
    """'code' seul dans une phrase courante ne doit pas router vers qwen."""
    result = route("Quel est le code postal de Lyon ?")
    assert result != "qwen2.5-coder:7b-instruct"


def test_router_false_positive_fonction_medicament() -> None:
    """'fonction' biologique/administrative ne doit pas router vers qwen."""
    result = route("Quelle est la fonction de ce médicament ?")
    assert result != "qwen2.5-coder:7b-instruct"


def test_router_isolation_from_document_markers() -> None:
    """Le routeur ne doit pas être influencé par les marqueurs documentaires."""
    polluted = "document_uploaded document_type:pdf audit dockerfile cve trivy"
    neutral_prompt = "Quand expire mon contrat ?"
    assert polluted != neutral_prompt
    assert route(neutral_prompt) != "qwen3:8b"


def test_router_code_python_still_routes_to_qwen() -> None:
    """Après correction, le code Python légitime route toujours vers qwen."""
    assert route("Génère un module FastAPI avec async def") == "qwen2.5-coder:7b-instruct"
    assert route("Implémente cette classe Python") == "qwen2.5-coder:7b-instruct"
    assert route("Génère le code pour ce module pytest") == "qwen2.5-coder:7b-instruct"
    assert route("def foo(): pass") == "qwen2.5-coder:7b-instruct"
