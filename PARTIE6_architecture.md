# PARTIE 6 — ARCHITECTURE TECHNIQUE

## Décision runtime : Ollama seul (pas llama.cpp direct)

**Ollama retenu, llama.cpp direct écarté. Raisons :**

| Critère | Ollama | llama.cpp direct |
|---------|--------|-----------------|
| Gestion multi-modèles | Swap automatique, API unifiée | Manuel, 1 processus par modèle |
| API REST compatible OpenAI | Oui (port 11434) | Non natif (server mode différent) |
| Intégration Python SDK | `ollama` package stable | Bindings moins stables |
| CUDA RTX 5060 | Détecté automatiquement | Flag `-ngl` à gérer manuellement |
| Gestion mémoire VRAM | Swap automatique entre modèles | Gestion manuelle |
| Maintenance | Mise à jour `apt upgrade ollama` | Compilation depuis source |
| **Cas où llama.cpp direct est préférable** | — | Benchmark fins, quantizations exotiques (IQ4_XS), Nemotron Mamba |

**LM Studio** : exclu. Interface graphique, pas d'API headless stable, pas de CLI.
**Open WebUI** : optionnel — voir section dédiée ci-dessous.

---

## Topologie des composants

```
┌─────────────────────────────────────────────────────────────────┐
│                    UbuntuDevStation (local)                      │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                   ORCHESTRATEUR                            │ │
│  │   /home/gloaguen/projets/local-llm-orchestrator/          │ │
│  │                                                            │ │
│  │   LangGraph Graph ──► node_router (phi4-mini, permanent)  │ │
│  │        │                                                   │ │
│  │        ├──► node_code_worker                              │ │
│  │        ├──► node_audit_worker                             │ │
│  │        ├──► node_agent_worker         via Ollama REST      │ │
│  │        ├──► node_debug_worker    ─────────────────────►   │ │
│  │        └──► node_redaction_worker                         │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            │                                     │
│                            ▼                                     │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │            OLLAMA SERVICE (systemd)                         │ │
│  │            http://127.0.0.1:11434                           │ │
│  │                                                              │ │
│  │  Modèles chargés (VRAM RTX 5060 8GB) :                     │ │
│  │  ┌──────────────────┐  ← permanent (2.4 Go)                │ │
│  │  │  phi4-mini       │                                       │ │
│  │  └──────────────────┘                                       │ │
│  │  ┌──────────────────┐  ← swap à la demande (~3-5s)         │ │
│  │  │  qwen2.5-coder   │  4.1 Go                              │ │
│  │  │  granite3.3      │  4.9 Go   (un seul en VRAM à la fois) │ │
│  │  │  deepseek-r1     │  4.5 Go                              │ │
│  │  │  mistral:7b      │  4.1 Go                              │ │
│  │  └──────────────────┘                                       │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌──────────────────┐  ┌────────────────────────────────────┐   │
│  │  ~/.llm-local/   │  │  ~/.ollama/models/                 │   │
│  │  manifest.json   │  │  blobs/ (GGUF binaires)            │   │
│  │  recheck.sh      │  │  manifests/ (JSON layers)          │   │
│  │  logs/           │  │                                    │   │
│  └──────────────────┘  └────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Chargement : permanent vs à la demande

**Permanent** (toujours en VRAM) :
```bash
# phi4-mini reste chargé → désactiver le timeout de déchargement Ollama
# Ollama décharge un modèle après 5min d'inactivité par défaut
# Pour le garder en VRAM : option OLLAMA_KEEP_ALIVE

# Configurer via variable d'environnement dans le service Ollama
sudo mkdir -p /etc/systemd/system/ollama.service.d/
cat << 'EOF' | sudo tee /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=24h"
EOF
sudo systemctl daemon-reload && sudo systemctl restart ollama

# Garder phi4-mini en VRAM en permanence
ollama run phi4-mini --keepalive 87600h "Warmup" > /dev/null &
```

**À la demande** (swap automatique) :
Ollama gère le swap entre modèles automatiquement. Latence de premier appel ~3-5s
pour charger en VRAM, ensuite fluide jusqu'à l'inactivité de 5min.

---

## Structure projet orchestrateur

```
/home/gloaguen/projets/local-llm-orchestrator/
├── pyproject.toml
├── src/
│   └── orchestrator/
│       ├── __init__.py
│       ├── graph.py          ← LangGraph graph (voir PARTIE2)
│       ├── router.py         ← logique de routing déterministe
│       ├── models.py         ← config modèles et timeouts
│       ├── state.py          ← OrchestratorState Pydantic v2
│       └── logging.py        ← journalisation appels
├── tests/
│   ├── test_router.py
│   └── test_integration.py
└── scripts/
    └── benchmark.py          ← voir PARTIE7
```

---

## Journalisation des appels

```python
# src/orchestrator/logging.py
"""Journalisation structurée de chaque appel LLM."""
import json
import datetime
from pathlib import Path
from typing import Optional


LOG_DIR = Path.home() / ".llm-local/logs/calls"
LOG_DIR.mkdir(parents=True, exist_ok=True)


def log_call(
    model: str,
    role: str,
    prompt_len: int,
    response_len: int,
    tokens_per_sec: float,
    elapsed_s: float,
    fallback: bool = False,
    error: Optional[str] = None,
) -> None:
    """Loggue un appel LLM en JSONL (une ligne par appel)."""
    entry = {
        "ts": datetime.datetime.utcnow().isoformat() + "Z",
        "model": model,
        "role": role,
        "prompt_chars": prompt_len,
        "response_chars": response_len,
        "tok_per_sec": round(tokens_per_sec, 1),
        "elapsed_s": round(elapsed_s, 2),
        "fallback": fallback,
        "error": error,
    }
    log_file = LOG_DIR / f"calls_{datetime.date.today().strftime('%Y%m%d')}.jsonl"
    with open(log_file, "a") as f:
        f.write(json.dumps(entry) + "\n")
```

Les logs sont dans `~/.llm-local/logs/calls/calls_YYYYMMDD.jsonl`.
Format JSONL → exploitable avec `jq` :
```bash
# Tokens/s moyen par modèle sur la journée
jq -r '[.model, .tok_per_sec] | @tsv' \
  ~/.llm-local/logs/calls/calls_$(date +%Y%m%d).jsonl \
  | sort | awk '{sum[$1]+=$2; count[$1]++} END {for (m in sum) print m, sum[m]/count[m]}'
```

---

## Open WebUI : pertinence

**Verdict : optionnel, non recommandé par défaut.**

Raisons d'exclusion du setup initial :
- Ajout d'une couche Docker (ou npm) avec sa propre surface d'attaque
- Port 3000 ou 8080 potentiellement exposé si mal configuré
- Inutile pour l'usage principal (scripts Python, Claude Code CLI)
- Pas de gain fonctionnel pour l'orchestrateur LangGraph

**Cas où Open WebUI est pertinent** :
- Accès occasionnel via browser pour tests manuels de prompts
- Démonstration à un tiers sur le même réseau local (LAN fermé uniquement)

**Si besoin** (installation isolée, locale uniquement) :
```bash
docker run -d \
  --name open-webui \
  --restart unless-stopped \
  --add-host=host.docker.internal:host-gateway \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -e WEBUI_AUTH=true \
  -p 127.0.0.1:3000:8080 \    # ← CRITIQUE : bind 127.0.0.1 seulement
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:0.5.20    # ← version épinglée
```

---

## Séparation test vs prod locale

```
TEST  → modèle phi4-mini (rapide, faible coût VRAM, résultats reproductibles)
        température 0.0, num_predict limité (256 tokens max)
        logs dans : ~/.llm-local/logs/test/

PROD  → batch complet selon routing PARTIE2
        température 0.1, num_predict 2048
        logs dans : ~/.llm-local/logs/calls/
```

Variable d'environnement pour switcher :
```bash
export LLM_ENV=test   # ou prod
```

Dans l'orchestrateur :
```python
import os
LLM_ENV = os.getenv("LLM_ENV", "prod")
MODEL_OVERRIDE = "phi4-mini" if LLM_ENV == "test" else None
```

---

## Installation complète depuis zéro

```bash
# 1. Prérequis (Ubuntu 24.04)
which ollama || curl -fsSL https://ollama.ai/install.sh | sh   # si pas déjà installé
which jq    || sudo apt install -y jq
which python3 && python3 --version | grep -E "3\.(11|12|13)"  || sudo apt install -y python3.11

# 2. Configuration Ollama (localhost uniquement)
sudo mkdir -p /etc/systemd/system/ollama.service.d/
cat << 'EOF' | sudo tee /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=5m"
EOF
sudo systemctl daemon-reload && sudo systemctl restart ollama
sleep 2 && ollama list  # vérification

# 3. Bootstrap modèles + intégrité
bash /home/gloaguen/projets/llm-local-architecture/bootstrap.sh

# 4. Venv orchestrateur
cd /home/gloaguen/projets/local-llm-orchestrator
python3.11 -m venv .venv
source .venv/bin/activate
pip install langgraph>=0.2 ollama>=0.3 pydantic>=2.0 pip-audit

# 5. Vérification finale
ollama list
bash ~/.llm-local/recheck.sh
python3 /home/gloaguen/projets/llm-local-architecture/canary_check.py
```

---

## pyproject.toml minimal

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "local-llm-orchestrator"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "langgraph>=0.2.0,<0.3",
    "ollama>=0.3.0,<0.4",
    "pydantic>=2.0.0,<3",
    "fastapi>=0.115.0,<0.116",
    "uvicorn[standard]>=0.32.0,<0.33",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-asyncio>=0.23",
    "mypy>=1.8",
    "ruff>=0.3",
    "pip-audit>=2.7",
]

[tool.ruff]
target-version = "py311"
line-length = 100

[tool.mypy]
python_version = "3.11"
strict = true

[tool.pytest.ini_options]
asyncio_mode = "auto"
```
