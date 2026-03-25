"""Orchestrateur LLM local — package Python."""

from .router import route

__all__ = ["get_package_name", "route"]


def get_package_name() -> str:
    """Return the canonical package name."""
    return "llm_local_architecture"
