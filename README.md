# llm-local-architecture

Architecture locale pour orchestration multi-modèles LLM open-source.
Pas de cloud. Pas d'API payante. Tout tourne sur la machine locale.

---

## État du projet

| Composant | Statut |
|-----------|--------|
| Téléchargement et vérification des modèles (Linux) | **Implémenté** — `bootstrap.sh` |
| Téléchargement et vérification des modèles (Windows) | **Implémenté** — `deploy-windows.ps1` |
| Registre local d'approbation des modèles | **Implémenté** — `deploy-windows.ps1` |
| Routeur Python déterministe | **Implémenté** — `src/llm_local_architecture/router.py` |
| API FastAPI d'orchestration (port 8001) | **Implémenté** — `src/llm_local_architecture/orchestrator.py` |
| CLI d'orchestration | **Implémenté** — `python -m llm_local_architecture.orchestrator` |
| Open WebUI (interface web) | **Disponible via Docker** — voir section Docker |
| Benchmark automatisé | **Documenté** — `PARTIE7_benchmark.md` (non branché) |
| Recheck intégrité automatique (Windows) | **Partiel** — manuel, pas de tâche planifiée |

---

## Les 5 modèles du batch

Tags exacts tels que téléchargés et validés sur machine réelle :

| Modèle | Rôle | VRAM Q4 |
|--------|------|---------|
| `qwen2.5-coder:7b-instruct` | Code Python, FastAPI, LangGraph | ~4.1 Go |
| `granite3.3:8b` | Audit sécurité, DevSecOps, CI/CD | ~4.9 Go |
| `deepseek-r1:7b` | Raisonnement, orchestration, planification | ~4.5 Go |
| `phi4-mini` | Debug rapide, sanity check, fallback permanent | ~2.4 Go |
| `mistral:7b-instruct-v0.3-q4_K_M` | Rédaction française, documents | ~4.1 Go |

> **Contrainte VRAM :** un seul modèle 7-8B en mémoire à la fois sur 8 Go.
> `phi4-mini` (2.4 Go) peut coexister avec n'importe quel autre modèle.

---

## Architecture réelle

```
┌──────────────────────────────────────────────────────┐
│  CLI / API locale (port 8001)                        │
│  python -m llm_local_architecture.orchestrator       │
│  POST http://localhost:8001/generate                 │
└──────────────────────┬───────────────────────────────┘
                       │
             ┌─────────▼─────────┐
             │  Routeur Python   │  routing déterministe
             │  (keyword match)  │  <1ms, sans ML
             └─────────┬─────────┘
                       │ sélectionne le modèle
             ┌─────────▼─────────────────────────────────┐
             │  Ollama  (port 11434)                      │
             │  Runtime local — gère le swap VRAM         │
             │  API compatible OpenAI sur localhost       │
             └─────────┬─────────────────────────────────┘
                       │
        ┌──────────────▼──────────────────┐
        │  Modèles stockés localement      │
        │  Linux : /usr/share/ollama/...  │
        │  Windows : %USERPROFILE%\.ollama│
        │  Intégrité SHA-256 vérifiée     │
        └──────────────────────────────────┘
```

### Règles de routing (ordre = priorité)

| Priorité | Mots-clés déclencheurs (exemples) | Modèle sélectionné |
|----------|-----------------------------------|---------------------|
| 1 | dockerfile, cve, audit, hardening, gitleaks, nis2 | `granite3.3:8b` |
| 2 | python, fastapi, génère, implémente, class, .py | `qwen2.5-coder:7b-instruct` |
| 3 | orchestr, planifie, stratégie, workflow, agent | `deepseek-r1:7b` |
| 4 | rédige, reformule, mail, synthèse, compte rendu | `mistral:7b-instruct-v0.3-q4_K_M` |
| 5 | erreur, traceback, bug, sanity check, rapide | `phi4-mini` |
| fallback | (aucun match) | `phi4-mini` |

---

## Installation

### Linux (Ubuntu 24.04)

```bash
# 1. Installer Ollama (télécharger le binaire officiel)
#    → https://ollama.com/download/linux
#    Vérifier le SHA-256 fourni sur la page de téléchargement avant d'exécuter

# 2. Cloner le repo
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture

# 3. Bootstrap : télécharge les 5 modèles, vérifie l'intégrité, génère le manifest
#    Durée : 20-60 min selon le débit réseau
bash bootstrap.sh

# 4. Tester
ollama run phi4-mini "Dis bonjour en une phrase"
```

### Windows (PowerShell natif + GPU NVIDIA)

```powershell
# 1. Ouvrir PowerShell 7 en administrateur

# 2. Autoriser l'exécution de scripts
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 3. Cloner le repo
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture

# 4. Déploiement (installe Ollama si absent, télécharge les modèles)
.\deploy-windows.ps1

# 5. Tester
ollama run phi4-mini "Dis bonjour en une phrase"
```

> Guide Windows complet : [DEPLOY_WINDOWS.md](DEPLOY_WINDOWS.md)

---

## Utiliser l'orchestrateur

### Installation du package Python

```bash
pip install -e ".[dev]"
```

### CLI

```bash
# Routing automatique + appel Ollama
python -m llm_local_architecture.orchestrator "Génère un module FastAPI async"
# → [router] → qwen2.5-coder:7b-instruct
# → (réponse du modèle)

python -m llm_local_architecture.orchestrator "Audite ce Dockerfile"
# → [router] → granite3.3:8b

python -m llm_local_architecture.orchestrator "Rédige un mail de relance client"
# → [router] → mistral:7b-instruct-v0.3-q4_K_M
```

### API FastAPI (port 8001)

```bash
# Lancer le serveur
uvicorn llm_local_architecture.orchestrator:app --port 8001

# Dry-run — voir quel modèle serait sélectionné
curl -s -X POST http://localhost:8001/route \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Audite ce Dockerfile"}' | python3 -m json.tool

# Génération complète
curl -s -X POST http://localhost:8001/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Génère un endpoint FastAPI GET /health"}' | python3 -m json.tool

# Forcer un modèle spécifique (bypass routing)
curl -s -X POST http://localhost:8001/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Analyse ce texte", "model": "deepseek-r1:7b"}' | python3 -m json.tool

# Lister les modèles disponibles dans Ollama
curl -s http://localhost:8001/models | python3 -m json.tool
```

### Tests du routeur

```bash
# Tests unitaires — aucun Ollama requis
pytest tests/test_router.py -v
```

---

## Docker — Deux modes

### MODE 1 — Linux full Docker (Ollama + WebUI dans des conteneurs)

```bash
docker compose --profile full up -d
# → Ollama sur localhost:11434
# → Open WebUI sur http://localhost:3000
```

Pour activer le GPU NVIDIA, décommenter le bloc `deploy` dans `docker-compose.yml`.

### MODE 2 — Windows natif (ou Linux avec Ollama déjà lancé)

> **Pourquoi ce mode ?**
> Sur Windows, Ollama tourne nativement et occupe déjà le port 11434.
> Lancer un second Ollama dans Docker provoque un conflit de port.
> Ce mode lance uniquement Open WebUI et le connecte à l'Ollama natif.

```bash
docker compose --profile webui-only up -d
# → Open WebUI sur http://localhost:3000
# → Pointe vers Ollama natif (host.docker.internal:11434)
# Prérequis : Ollama natif tourne sur localhost:11434
```

> **Note Docker Desktop Windows :** `host.docker.internal` est résolu nativement.
> **Note Linux Docker Engine :** l'entrée `extra_hosts: host-gateway` est déjà configurée dans le compose.

---

## Vérification d'intégrité des modèles

### Linux

```bash
# Recheck manuel
bash ~/.llm-local/recheck.sh

# Voir le manifest
cat ~/.llm-local/manifests/manifest.json | python3 -m json.tool

# Logs
tail -f ~/.llm-local/logs/cron.log
```

Un recheck automatique tourne chaque jour à 07h00 via cron (installé par `bootstrap.sh`).

### Windows

```powershell
# Le script deploy-windows.ps1 génère et maintient un registre local
# Voir le manifest
notepad $env:USERPROFILE\.llm-local\manifests\manifest.json
```

### Statuts des modèles

| Statut | Signification | Action |
|--------|---------------|--------|
| `candidate` | Modèle téléchargé, pas encore approuvé | Lancer `deploy-windows.ps1` pour approuver |
| `trusted` | Hash vérifié et approuvé dans le registre | Aucune action requise |
| `drifted` | Hash actuel ≠ hash approuvé | Investigation — re-télécharger |
| `quarantine` | Drift confirmé ou corruption détectée | Supprimer et re-télécharger |
| `missing` | Modèle absent de l'inventaire local | Re-télécharger |

---

## CI/CD

### À chaque push sur `dev` ou `main`

- Lint bash avec `shellcheck`
- Validation `docker-compose.yml`
- Scan `pip-audit`

### Chaque lundi à 06h00

- Scan secrets avec Gitleaks
- Scan CVE avec Trivy
- Checkov sur les fichiers IaC

### Déploiement manuel depuis GitHub

```
GitHub → Actions → Deploy → Run workflow
→ Choisir la cible : linux-bare-metal ou windows-native
→ Taper "DEPLOY" pour confirmer
```

---

## Structure des fichiers générés (hors repo)

```
~/.llm-local/               (Linux)
%USERPROFILE%\.llm-local\   (Windows)
├── manifests/
│   └── manifest.json       ← état de chaque modèle (statut, hash, date)
├── logs/
│   ├── bootstrap_*.log
│   ├── integrity_*.log
│   └── cron.log            (Linux uniquement)
├── trusted/
│   └── trusted_blobs.log
└── quarantine/
    └── quarantine.log
```

Fichiers locaux à chaque machine, non versionnés.

---

## Dépannage

| Problème | Linux | Windows |
|----------|-------|---------|
| Ollama ne répond pas | `systemctl status ollama` | `Get-Process ollama` |
| Modèle en quarantaine | `cat ~/.llm-local/quarantine/quarantine.log` | `notepad $env:USERPROFILE\.llm-local\quarantine\quarantine.log` |
| Relancer le déploiement | `bash bootstrap.sh` | `.\deploy-windows.ps1` |
| Voir les modèles | `ollama list` | `ollama list` |
| Tester un modèle | `ollama run phi4-mini "test"` | `ollama run phi4-mini "test"` |
| WebUI inaccessible | `docker compose --profile full ps` | `docker compose --profile webui-only ps` |
| Conflit port 11434 sur Windows | N/A | Utiliser le profil `webui-only` |
| GPU non détecté | `nvidia-smi` | `nvidia-smi.exe` (dans `C:\Windows\System32\`) |
| Orchestrateur — Ollama injoignable | `curl http://localhost:11434/api/tags` | Idem |

---

## Différences Linux vs Windows

| Aspect | Linux | Windows natif |
|--------|-------|---------------|
| Script de déploiement | `bash bootstrap.sh` | `.\deploy-windows.ps1` |
| Répertoire modèles | `/usr/share/ollama/.ollama/models` | `%USERPROFILE%\.ollama\models` |
| Service Ollama | systemd | Process en tâche de fond |
| Recheck intégrité | cron 07h00 (automatique) | Manuel (pas de tâche planifiée) |
| GPU | CUDA natif | CUDA natif (RTX 5060+) |
| Docker | Docker Engine | Docker Desktop |
| Mode Docker recommandé | `--profile full` | `--profile webui-only` |

---

## Branching

```
main   ← stable, déployable, protégée
  └── dev  ← développement quotidien
        ├── feature/xxx
        └── fix/xxx
```

Le déploiement physique se fait toujours depuis `main`.

---

## Liens

- Ollama : https://ollama.com
- Open WebUI : https://github.com/open-webui/open-webui
- Bibliothèque de modèles : https://ollama.com/library
