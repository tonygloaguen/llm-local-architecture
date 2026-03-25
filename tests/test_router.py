"""Tests unitaires pour la logique de routing.

Aucun appel Ollama requis — tests purement déterministes.
"""

from __future__ import annotations

import pytest

from llm_local_architecture.router import route


@pytest.mark.parametrize(
    "prompt,expected_model",
    [
        # ── Audit / Sécurité (priorité 1) ─────────────────────────────────────
        ("Audite ce Dockerfile", "granite3.3:8b"),
        ("Revue de sécurité du pipeline CI/CD", "granite3.3:8b"),
        ("Trivy scan results show CVE-2023-1234", "granite3.3:8b"),
        ("Hardening de ce serveur nginx", "granite3.3:8b"),
        ("Scan gitleaks sur ce repo", "granite3.3:8b"),
        ("Checkov rapport sur ce compose", "granite3.3:8b"),
        # ── Code (priorité 2) ──────────────────────────────────────────────────
        ("Génère un module FastAPI avec async def", "qwen2.5-coder:7b-instruct"),
        ("Implémente cette classe Python", "qwen2.5-coder:7b-instruct"),
        ("Refactor ce script bash", "qwen2.5-coder:7b-instruct"),
        ("```python\ndef foo(): pass", "qwen2.5-coder:7b-instruct"),
        ("Génère le code pour ce module pytest", "qwen2.5-coder:7b-instruct"),
        # ── Agent / Raisonnement (priorité 3) ─────────────────────────────────
        ("Planifie les étapes de ce workflow", "deepseek-r1:7b"),
        ("Décompose cette architecture en modules", "deepseek-r1:7b"),
        ("Stratégie de migration de base de données", "deepseek-r1:7b"),
        ("Root cause analysis de cet incident", "deepseek-r1:7b"),
        # ── Rédaction française (priorité 4) ──────────────────────────────────
        ("Rédige un mail professionnel pour ce client", "mistral:7b-instruct-v0.3-q4_K_M"),
        ("Synthèse de ce document technique", "mistral:7b-instruct-v0.3-q4_K_M"),
        ("Reformule ce compte rendu de réunion", "mistral:7b-instruct-v0.3-q4_K_M"),
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
    """Les keywords audit (priorité 1) l'emportent sur les keywords code (priorité 2)."""
    # "dockerfile" est dans les règles audit ET potentiellement code (docker-compose)
    # "audit" et "cve" font déclencher la règle audit avant la règle code
    prompt = "Génère du code Python pour scanner les CVE d'un Dockerfile"
    assert route(prompt) == "granite3.3:8b"


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
