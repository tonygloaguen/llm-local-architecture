"""Orchestrateur LLM local — API FastAPI et point d'entrée CLI.

Usage CLI :
    python -m llm_local_architecture.orchestrator "Génère un module FastAPI"

Usage API (serveur) :
    uvicorn llm_local_architecture.orchestrator:app --port 8001
    # ou via entry point :
    llm-orchestrator serve

Endpoints disponibles :
    GET  /health          — vérification de vie
    GET  /models          — liste les modèles disponibles dans Ollama
    POST /route           — routing dry-run (sans appeler Ollama)
    POST /generate        — routing + appel Ollama + réponse
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
import sys
from typing import Any

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .config import (
    DEFAULT_MODEL,
    OLLAMA_BASE_URL,
    OLLAMA_ENFORCE_SINGLE_MODEL_RESIDENCY,
    OLLAMA_GENERATE_KEEP_ALIVE,
    ORCHESTRATOR_PORT,
    STATIC_DIR,
)
from .documents import determine_input_type, process_document_bytes
from .exceptions import (
    OllamaError,
    OllamaGenerationError,
    OllamaModelNotFoundError,
    OllamaTimeoutError,
    OllamaUnavailableError,
)
from .memory import (
    build_memory_bundle,
    ensure_session,
    initialize_database,
    save_document,
    save_message,
)
from .prompting import build_generation_prompt
from .router import route
from .schemas import ChatResponse
from .storage import ensure_storage

app = FastAPI(
    title="LLM Local Orchestrator",
    version="0.1.0",
    description="Routeur déterministe vers les modèles Ollama locaux.",
)

logger = logging.getLogger(__name__)

STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


# ─── Schémas ──────────────────────────────────────────────────────────────────


class PromptRequest(BaseModel):
    """Corps d'une requête de génération."""

    prompt: str
    model: str | None = None  # surcharge le routing automatique si fourni


class PromptResponse(BaseModel):
    """Réponse de génération."""

    model: str
    routed_by: str  # "auto" | "override" | "fallback:<model>"
    response: str


@app.on_event("startup")
async def startup() -> None:
    """Initialise le stockage local au démarrage."""
    ensure_storage()
    initialize_database()


@app.get("/", include_in_schema=False)
async def index() -> FileResponse:
    """Sert l'interface web locale."""
    index_path = Path(STATIC_DIR) / "index.html"
    if not index_path.exists():
        raise HTTPException(status_code=404, detail="Interface web non disponible.")
    return FileResponse(index_path)


# ─── Routes ───────────────────────────────────────────────────────────────────


@app.get("/health")
async def health() -> dict[str, str]:
    """Vérification de vie de l'orchestrateur."""
    return {"status": "ok", "ollama_url": OLLAMA_BASE_URL}


@app.get("/models")
async def list_models() -> dict[str, Any]:
    """Liste les modèles disponibles dans Ollama."""
    async with httpx.AsyncClient(base_url=OLLAMA_BASE_URL, timeout=5.0) as client:
        try:
            resp = await client.get("/api/tags")
            resp.raise_for_status()
            return resp.json()  # type: ignore[no-any-return]
        except httpx.HTTPError as exc:
            raise HTTPException(
                status_code=503,
                detail=f"Ollama inaccessible sur {OLLAMA_BASE_URL} : {exc}",
            ) from exc


@app.post("/route")
async def route_only(req: PromptRequest) -> dict[str, str]:
    """Retourne le modèle sélectionné sans appeler Ollama (dry-run)."""
    selected = req.model or route(req.prompt)
    return {
        "model": selected,
        "routed_by": "override" if req.model else "auto",
    }


@app.post("/generate", response_model=PromptResponse)
async def generate(req: PromptRequest) -> PromptResponse:
    """Route le prompt et appelle Ollama pour générer une réponse.

    Fallback automatique sur DEFAULT_MODEL si le modèle sélectionné est absent.
    """
    selected_model = req.model or route(req.prompt)
    routed_by = "override" if req.model else "auto"

    response_text, actual_model, fallback_used = await _generate_with_fallback(
        req.prompt,
        selected_model,
    )
    if fallback_used:
        routed_by = f"fallback:{DEFAULT_MODEL} (original:{selected_model} indisponible)"
    return PromptResponse(model=actual_model, routed_by=routed_by, response=response_text)


@app.post("/chat", response_model=ChatResponse)
async def chat(
    prompt: str = Form(""),
    session_id: str | None = Form(None),
    document: UploadFile | None = File(None),
) -> ChatResponse:
    """Point d'entrée unique de l'interface web locale."""
    normalized_prompt = prompt.strip()
    if not normalized_prompt and document is None:
        raise HTTPException(status_code=400, detail="Prompt ou document requis.")

    effective_prompt = normalized_prompt or "Résume le document fourni et réponds de manière structurée."

    active_session_id = ensure_session(session_id)
    processed_document = None
    document_id: str | None = None

    if document is not None and document.filename:
        payload = await document.read()
        if not payload:
            raise HTTPException(status_code=400, detail="Document vide.")
        try:
            processed_document = process_document_bytes(
                filename=document.filename,
                payload=payload,
                content_type=document.content_type,
            )
        except (ValueError, RuntimeError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        document_id = save_document(active_session_id, processed_document)

    input_type = determine_input_type(normalized_prompt, processed_document is not None)
    memory = build_memory_bundle(active_session_id, document_id)
    selected_model = route(effective_prompt)
    generation_prompt, memory_sources = build_generation_prompt(
        effective_prompt,
        processed_document,
        memory,
        input_type=input_type,
    )
    logger.debug("Chat final_prompt=%r", generation_prompt)

    response_text, actual_model, fallback_used = await _generate_with_fallback(
        generation_prompt,
        selected_model,
    )
    routed_by = "auto"
    if fallback_used:
        routed_by = f"fallback:{DEFAULT_MODEL} (original:{selected_model} indisponible)"

    user_message = normalized_prompt or f"[document-only] {processed_document.filename}"
    save_message(active_session_id, "user", user_message)
    save_message(active_session_id, "assistant", response_text)

    return ChatResponse(
        session_id=active_session_id,
        model=actual_model,
        routed_by=routed_by,
        response=response_text,
        input_type=input_type,
        ocr_used=processed_document.ocr_used if processed_document else False,
        document_id=document_id,
        memory_sources=memory_sources,
        extraction_method=processed_document.extraction_method if processed_document else None,
    )


# ─── Helpers internes ─────────────────────────────────────────────────────────


async def _call_ollama(
    client: httpx.AsyncClient,
    prompt: str,
    model: str,
) -> str:
    """Appelle /api/generate sur Ollama. Lève une exception typée en cas d'erreur."""
    try:
        resp = await client.post(
            "/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "stream": False,
                "keep_alive": OLLAMA_GENERATE_KEEP_ALIVE,
            },
        )
        if resp.status_code == 404:  # noqa: PLR2004
            raise OllamaModelNotFoundError(f"Modèle '{model}' absent d'Ollama (404)")
        resp.raise_for_status()
        return resp.json().get("response", "")  # type: ignore[no-any-return]
    except OllamaModelNotFoundError:
        raise
    except httpx.TimeoutException as exc:
        raise OllamaTimeoutError(f"Timeout lors de la génération avec '{model}'") from exc
    except httpx.ConnectError as exc:
        raise OllamaUnavailableError(f"Ollama inaccessible sur {OLLAMA_BASE_URL}") from exc
    except httpx.HTTPError as exc:
        raise OllamaGenerationError(f"Erreur HTTP inattendue avec '{model}': {exc}") from exc


async def _list_loaded_models(client: httpx.AsyncClient) -> list[str]:
    """Retourne les modèles actuellement résidents dans Ollama."""
    try:
        resp = await client.get("/api/ps")
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Impossible de lire l'état de ollama ps sur {OLLAMA_BASE_URL} : {exc}",
        ) from exc

    payload = resp.json()
    models = payload.get("models", [])
    if not isinstance(models, list):
        return []

    loaded_models: list[str] = []
    for entry in models:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name") or entry.get("model")
        if isinstance(name, str) and name:
            loaded_models.append(name)
    return loaded_models


def _format_loaded_models(models: list[str]) -> str:
    """Formate l'état de `ollama ps` pour les logs."""
    if not models:
        return "<none>"
    return ", ".join(models)


async def _stop_model(client: httpx.AsyncClient, model: str) -> None:
    """Décharge un modèle d'Ollama pour libérer la VRAM."""
    try:
        resp = await client.post("/api/generate", json={"model": model, "keep_alive": 0})
        if resp.status_code == 404:  # noqa: PLR2004
            return
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Impossible de décharger le modèle {model} sur {OLLAMA_BASE_URL} : {exc}",
        ) from exc


async def _prepare_model_execution(client: httpx.AsyncClient, selected_model: str) -> None:
    """Garantit qu'un seul modèle est résident avant génération."""
    loaded_models = await _list_loaded_models(client)
    logger.info(
        "Ollama selected_model=%s ps_before=%s",
        selected_model,
        _format_loaded_models(loaded_models),
    )

    if OLLAMA_ENFORCE_SINGLE_MODEL_RESIDENCY:
        stale_models = [model for model in loaded_models if model != selected_model]
        for stale_model in stale_models:
            logger.info("Ollama stopping stale model=%s before selected_model=%s", stale_model, selected_model)
            await _stop_model(client, stale_model)

    updated_models = await _list_loaded_models(client)
    logger.info(
        "Ollama selected_model=%s ps_after_cleanup=%s",
        selected_model,
        _format_loaded_models(updated_models),
    )


async def _generate_with_fallback(prompt: str, selected_model: str) -> tuple[str, str, bool]:
    """Génère une réponse avec fallback éventuel sur le modèle par défaut."""
    async with httpx.AsyncClient(base_url=OLLAMA_BASE_URL, timeout=120.0) as client:
        try:
            await _prepare_model_execution(client, selected_model)
            response_text = await _call_ollama(client, prompt, selected_model)
            loaded_models = await _list_loaded_models(client)
            logger.info(
                "Ollama selected_model=%s ps_after_generate=%s generation_status=ok",
                selected_model,
                _format_loaded_models(loaded_models),
            )
            return response_text, selected_model, False
        except OllamaError as exc:
            logger.warning(
                "Ollama error: model=%s error_type=%s reason=%s",
                selected_model,
                type(exc).__name__,
                str(exc),
            )
            if selected_model == DEFAULT_MODEL:
                raise HTTPException(
                    status_code=503,
                    detail=f"Modèle par défaut {DEFAULT_MODEL} inaccessible: {exc}",
                ) from exc

            logger.warning("Ollama fallback: %s → %s", selected_model, DEFAULT_MODEL)
            try:
                await _prepare_model_execution(client, DEFAULT_MODEL)
                fallback_text = await _call_ollama(client, prompt, DEFAULT_MODEL)
                loaded_models = await _list_loaded_models(client)
                logger.info(
                    "Ollama selected_model=%s ps_after_generate=%s generation_status=ok",
                    DEFAULT_MODEL,
                    _format_loaded_models(loaded_models),
                )
                return fallback_text, DEFAULT_MODEL, True
            except OllamaError as fallback_exc:
                raise HTTPException(
                    status_code=503,
                    detail=(
                        f"Modèle {selected_model} ({type(exc).__name__}) "
                        f"et fallback {DEFAULT_MODEL} ({type(fallback_exc).__name__}) inaccessibles."
                    ),
                ) from fallback_exc

        raise HTTPException(
            status_code=503,
            detail=f"Ollama inaccessible sur {OLLAMA_BASE_URL}.",
        )


# ─── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    """Point d'entrée CLI.

    Usage : python -m llm_local_architecture.orchestrator "<prompt>"
    """
    if len(sys.argv) < 2:  # noqa: PLR2004
        print(
            'Usage: python -m llm_local_architecture.orchestrator "<prompt>"',
            file=sys.stderr,
        )
        sys.exit(1)

    prompt = " ".join(sys.argv[1:])
    selected = route(prompt)
    print(f"[router] → {selected}", file=sys.stderr, flush=True)

    response = asyncio.run(_cli_generate(prompt, selected))
    print(response)


async def _cli_generate(prompt: str, model: str) -> str:
    """Génère une réponse via Ollama depuis la CLI, avec fallback."""
    try:
        result, _, fallback_used = await _generate_with_fallback(prompt, model)
        if fallback_used:
            print(
                f"[fallback] {model} indisponible, bascule sur {DEFAULT_MODEL}",
                file=sys.stderr,
            )
        return result
    except HTTPException:
        print(
            f"[erreur] Ollama inaccessible sur {OLLAMA_BASE_URL}",
            file=sys.stderr,
        )
        sys.exit(1)


def serve() -> None:
    """Lance le serveur FastAPI sur ORCHESTRATOR_PORT."""
    import uvicorn  # noqa: PLC0415

    uvicorn.run(app, host="127.0.0.1", port=ORCHESTRATOR_PORT)


if __name__ == "__main__":
    main()
