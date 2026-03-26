from __future__ import annotations

from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture import orchestrator


class FakeResponse:
    def __init__(self, status_code: int, payload: dict[str, object]) -> None:
        self.status_code = status_code
        self._payload = payload

    def raise_for_status(self) -> None:
        if self.status_code >= 400 and self.status_code != 404:
            raise orchestrator.httpx.HTTPStatusError(
                "request failed",
                request=orchestrator.httpx.Request("POST", "http://localhost"),
                response=orchestrator.httpx.Response(self.status_code),
            )

    def json(self) -> dict[str, object]:
        return self._payload


class FakeAsyncClient:
    def __init__(self, *, ps_payloads: list[list[str]], generate_responses: list[FakeResponse]) -> None:
        self.ps_payloads = ps_payloads
        self.generate_responses = generate_responses
        self.calls: list[tuple[str, str, dict[str, object] | None]] = []

    async def __aenter__(self) -> FakeAsyncClient:
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        return None

    async def get(self, path: str) -> FakeResponse:
        self.calls.append(("GET", path, None))
        models = self.ps_payloads.pop(0)
        return FakeResponse(
            200,
            {"models": [{"name": model} for model in models]},
        )

    async def post(self, path: str, json: dict[str, object]) -> FakeResponse:
        self.calls.append(("POST", path, json))
        return self.generate_responses.pop(0)


@pytest.mark.asyncio
async def test_generate_with_fallback_stops_other_resident_models(monkeypatch, caplog) -> None:
    fake_client = FakeAsyncClient(
        ps_payloads=[
            ["granite3.3:8b", "qwen2.5-coder:7b-instruct"],
            ["qwen2.5-coder:7b-instruct"],
            [],
        ],
        generate_responses=[
            FakeResponse(200, {"response": ""}),
            FakeResponse(200, {"response": "ok"}),
        ],
    )

    monkeypatch.setattr(
        orchestrator.httpx,
        "AsyncClient",
        lambda **kwargs: fake_client,
    )

    with caplog.at_level("INFO"):
        response, model, fallback_used = await orchestrator._generate_with_fallback(
            "Génère un test",
            "qwen2.5-coder:7b-instruct",
        )

    assert response == "ok"
    assert model == "qwen2.5-coder:7b-instruct"
    assert fallback_used is False
    assert fake_client.calls == [
        ("GET", "/api/ps", None),
        ("POST", "/api/generate", {"model": "granite3.3:8b", "keep_alive": 0}),
        ("GET", "/api/ps", None),
        (
            "POST",
            "/api/generate",
            {
                "model": "qwen2.5-coder:7b-instruct",
                "prompt": "Génère un test",
                "stream": False,
                "keep_alive": orchestrator.OLLAMA_GENERATE_KEEP_ALIVE,
            },
        ),
        ("GET", "/api/ps", None),
    ]
    assert "selected_model=qwen2.5-coder:7b-instruct" in caplog.text
    assert "ps_before=granite3.3:8b, qwen2.5-coder:7b-instruct" in caplog.text
    assert "ps_after_generate=<none>" in caplog.text


@pytest.mark.asyncio
async def test_generate_with_fallback_retries_with_default_model(monkeypatch) -> None:
    fake_client = FakeAsyncClient(
        ps_payloads=[
            ["qwen2.5-coder:7b-instruct", "granite3.3:8b"],
            ["qwen2.5-coder:7b-instruct"],
            [],
            [],
            [],
            [],
        ],
        generate_responses=[
            FakeResponse(200, {"response": ""}),
            FakeResponse(404, {}),
            FakeResponse(200, {"response": "fallback"}),
        ],
    )

    monkeypatch.setattr(
        orchestrator.httpx,
        "AsyncClient",
        lambda **kwargs: fake_client,
    )

    response, model, fallback_used = await orchestrator._generate_with_fallback(
        "Explique",
        "qwen2.5-coder:7b-instruct",
    )

    assert response == "fallback"
    assert model == orchestrator.DEFAULT_MODEL
    assert fallback_used is True
    assert fake_client.calls == [
        ("GET", "/api/ps", None),
        ("POST", "/api/generate", {"model": "granite3.3:8b", "keep_alive": 0}),
        ("GET", "/api/ps", None),
        (
            "POST",
            "/api/generate",
            {
                "model": "qwen2.5-coder:7b-instruct",
                "prompt": "Explique",
                "stream": False,
                "keep_alive": orchestrator.OLLAMA_GENERATE_KEEP_ALIVE,
            },
        ),
        ("GET", "/api/ps", None),
        ("GET", "/api/ps", None),
        ("GET", "/api/ps", None),
        (
            "POST",
            "/api/generate",
            {
                "model": orchestrator.DEFAULT_MODEL,
                "prompt": "Explique",
                "stream": False,
                "keep_alive": orchestrator.OLLAMA_GENERATE_KEEP_ALIVE,
            },
        ),
        ("GET", "/api/ps", None),
    ]
