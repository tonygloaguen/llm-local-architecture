"""Tests d'intégration API — aucun appel Ollama réel, aucune DB SQLite."""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from llm_local_architecture.orchestrator import app
import llm_local_architecture.orchestrator as orch
from llm_local_architecture.schemas import MemoryBundle

# Réponse mock renvoyée à la place d'Ollama
_MOCK_TEXT = "Réponse de test générée par le mock."
_MOCK_MODEL = "phi4-mini"


async def _mock_generate(prompt: str, model: str) -> tuple[str, str, bool]:
    return _MOCK_TEXT, _MOCK_MODEL, False


@pytest_asyncio.fixture
async def client(monkeypatch):
    """Client HTTP ASGI.

    - Ollama : mocké via _generate_with_fallback
    - SQLite : mocké via ensure_session / save_message / save_document
    """
    monkeypatch.setattr(orch, "_generate_with_fallback", _mock_generate)
    monkeypatch.setattr(orch, "ensure_session", lambda session_id: session_id or "test-session-id")
    monkeypatch.setattr(orch, "save_message", lambda *a, **kw: None)
    monkeypatch.setattr(orch, "save_document", lambda *a, **kw: "doc-test-id")
    monkeypatch.setattr(orch, "build_memory_bundle", lambda *a, **kw: MemoryBundle())

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.mark.asyncio
async def test_health_returns_200(client) -> None:
    resp = await client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_chat_text_only_returns_200(client) -> None:
    resp = await client.post("/chat", data={"prompt": "Bonjour, résume-moi Python."})
    assert resp.status_code == 200
    body = resp.json()
    assert body["response"] == _MOCK_TEXT
    assert body["session_id"] == "test-session-id"
    assert body["input_type"] == "text"
    assert body["ocr_used"] is False


@pytest.mark.asyncio
async def test_chat_empty_payload_returns_400(client) -> None:
    resp = await client.post("/chat", data={})
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_chat_empty_document_returns_400(client) -> None:
    resp = await client.post(
        "/chat",
        data={"prompt": "Analyse ce doc"},
        files={"document": ("empty.pdf", b"", "application/pdf")},
    )
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_route_endpoint_returns_model(client) -> None:
    resp = await client.post("/route", json={"prompt": "Audite ce Dockerfile"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["model"] == "granite3.3:8b"
    assert body["routed_by"] == "auto"


@pytest.mark.asyncio
async def test_route_endpoint_override(client) -> None:
    resp = await client.post("/route", json={"prompt": "test", "model": "phi4-mini"})
    assert resp.status_code == 200
    assert resp.json()["routed_by"] == "override"
