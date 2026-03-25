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
import sys
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from .config import DEFAULT_MODEL, OLLAMA_BASE_URL, ORCHESTRATOR_PORT
from .router import route

app = FastAPI(
    title="LLM Local Orchestrator",
    version="0.1.0",
    description="Routeur déterministe vers les modèles Ollama locaux.",
)


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

    async with httpx.AsyncClient(base_url=OLLAMA_BASE_URL, timeout=120.0) as client:
        response_text = await _call_ollama(client, req.prompt, selected_model)

        if response_text is None and selected_model != DEFAULT_MODEL:
            response_text = await _call_ollama(client, req.prompt, DEFAULT_MODEL)
            if response_text is None:
                raise HTTPException(
                    status_code=503,
                    detail=(
                        f"Modèle {selected_model} et fallback {DEFAULT_MODEL} inaccessibles. "
                        f"Vérifiez qu'Ollama tourne sur {OLLAMA_BASE_URL}."
                    ),
                )
            routed_by = f"fallback:{DEFAULT_MODEL} (original:{selected_model} indisponible)"
            selected_model = DEFAULT_MODEL

        if response_text is None:
            raise HTTPException(
                status_code=503,
                detail=f"Ollama inaccessible sur {OLLAMA_BASE_URL}.",
            )

        return PromptResponse(
            model=selected_model,
            routed_by=routed_by,
            response=response_text,
        )


# ─── Helpers internes ─────────────────────────────────────────────────────────


async def _call_ollama(
    client: httpx.AsyncClient,
    prompt: str,
    model: str,
) -> str | None:
    """Appelle /api/generate sur Ollama.

    Retourne None si le modèle n'existe pas (404) ou si Ollama est injoignable.
    """
    try:
        resp = await client.post(
            "/api/generate",
            json={"model": model, "prompt": prompt, "stream": False},
        )
        if resp.status_code == 404:  # noqa: PLR2004
            return None
        resp.raise_for_status()
        return resp.json().get("response", "")  # type: ignore[no-any-return]
    except httpx.HTTPError:
        return None


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
    async with httpx.AsyncClient(base_url=OLLAMA_BASE_URL, timeout=120.0) as client:
        result = await _call_ollama(client, prompt, model)

        if result is None and model != DEFAULT_MODEL:
            print(
                f"[fallback] {model} indisponible, bascule sur {DEFAULT_MODEL}",
                file=sys.stderr,
            )
            result = await _call_ollama(client, prompt, DEFAULT_MODEL)

        if result is None:
            print(
                f"[erreur] Ollama inaccessible sur {OLLAMA_BASE_URL}",
                file=sys.stderr,
            )
            sys.exit(1)

        return result


def serve() -> None:
    """Lance le serveur FastAPI sur ORCHESTRATOR_PORT."""
    import uvicorn  # noqa: PLC0415

    uvicorn.run(app, host="127.0.0.1", port=ORCHESTRATOR_PORT)


if __name__ == "__main__":
    main()
