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
        lambda prompt, document, memory, input_type="text": (prompt, []),
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


def test_chat_requires_prompt_or_document(monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "ensure_storage", lambda: None)
    monkeypatch.setattr(orchestrator, "initialize_database", lambda: None)

    with TestClient(orchestrator.app) as client:
        response = client.post("/chat", data={"prompt": ""})

    assert response.status_code == 400
