from pathlib import Path
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture import orchestrator
from llm_local_architecture.schemas import MemoryBundle


def test_chat_text_only(monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "ensure_storage", lambda: None)
    monkeypatch.setattr(orchestrator, "initialize_database", lambda: None)
    monkeypatch.setattr(orchestrator, "ensure_session", lambda session_id=None: "session-1")
    monkeypatch.setattr(orchestrator, "build_memory_bundle", lambda session_id, document_id=None: MemoryBundle())
    monkeypatch.setattr(orchestrator, "save_message", lambda session_id, role, content: None)
    monkeypatch.setattr(
        orchestrator,
        "build_generation_prompt",
        lambda prompt, document, memory, input_type="text", intent=None: (prompt, []),
    )

    async def fake_generate(prompt: str, selected_model: str):
        return "Réponse locale", selected_model, False

    monkeypatch.setattr(orchestrator, "_generate_with_fallback", fake_generate)

    with TestClient(orchestrator.app) as client:
        response = client.post("/chat", data={"prompt": "Bonjour"})

    assert response.status_code == 200
    payload = response.json()
    assert payload["response"] == "Réponse locale"
    assert payload["input_type"] == "text"
    assert payload["ocr_used"] is False


def test_chat_ignores_irrelevant_document_for_simple_prompt(monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "ensure_storage", lambda: None)
    monkeypatch.setattr(orchestrator, "initialize_database", lambda: None)
    monkeypatch.setattr(orchestrator, "ensure_session", lambda session_id=None: "session-1")
    monkeypatch.setattr(orchestrator, "build_memory_bundle", lambda session_id, document_id=None: MemoryBundle())
    monkeypatch.setattr(orchestrator, "save_message", lambda session_id, role, content: None)
    monkeypatch.setattr(orchestrator, "save_document", lambda session_id, document: "doc-1")

    captured: dict[str, object] = {}

    def fake_build_generation_prompt(prompt, document, memory, input_type="text", intent=None):
        captured["document"] = document
        captured["input_type"] = input_type
        captured["intent"] = intent.category if intent is not None else None
        return prompt, []

    monkeypatch.setattr(orchestrator, "build_generation_prompt", fake_build_generation_prompt)

    async def fake_generate(prompt: str, selected_model: str):
        return "4", selected_model, False

    monkeypatch.setattr(orchestrator, "_generate_with_fallback", fake_generate)
    monkeypatch.setattr(
        orchestrator,
        "process_document_bytes",
        lambda filename, payload, content_type=None: type(
            "Doc",
            (),
            {
                "filename": filename,
                "text": "Date: 12/03/2026",
                "ocr_used": False,
                "extraction_method": "plain_text",
                "source_type": "text",
                "structured_fields": None,
            },
        )(),
    )

    with TestClient(orchestrator.app) as client:
        response = client.post(
            "/chat",
            data={"prompt": "2+2"},
            files={"document": ("texte.txt", b"Date: 12/03/2026", "text/plain")},
        )

    assert response.status_code == 200
    payload = response.json()
    assert payload["response"] == "4"
    assert payload["input_type"] == "text"
    assert captured["document"] is None
    assert captured["intent"] == "qa_simple"


def test_chat_requires_prompt_or_document(monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "ensure_storage", lambda: None)
    monkeypatch.setattr(orchestrator, "initialize_database", lambda: None)

    with TestClient(orchestrator.app) as client:
        response = client.post("/chat", data={"prompt": ""})

    assert response.status_code == 400


def test_chat_refuses_document_request_without_document(monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "ensure_storage", lambda: None)
    monkeypatch.setattr(orchestrator, "initialize_database", lambda: None)
    monkeypatch.setattr(orchestrator, "ensure_session", lambda session_id=None: "session-1")
    monkeypatch.setattr(orchestrator, "save_message", lambda session_id, role, content: None)

    with TestClient(orchestrator.app) as client:
        response = client.post("/chat", data={"prompt": "Analyse ce document"})

    assert response.status_code == 200
    payload = response.json()
    assert payload["response"] == "Aucun document fourni. Impossible de répondre."
    assert payload["model"] == "guardrail"


def test_lifespan_runs_startup_and_shutdown(monkeypatch) -> None:
    calls: list[str] = []

    async def fake_startup() -> None:
        calls.append("startup")

    async def fake_shutdown() -> None:
        calls.append("shutdown")

    monkeypatch.setattr(orchestrator, "_startup", fake_startup)
    monkeypatch.setattr(orchestrator, "_shutdown", fake_shutdown)

    with TestClient(orchestrator.app):
        assert calls == ["startup"]

    assert calls == ["startup", "shutdown"]
