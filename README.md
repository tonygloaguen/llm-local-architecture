# llm-local-architecture

Routeur local déterministe pour plusieurs LLM locaux via Ollama, avec une CLI et une API FastAPI.

Le projet fournit aujourd’hui :
- un routeur Python simple et explicable
- un orchestrateur local minimal au-dessus d’Ollama
- une façade CLI/API vers Ollama
- un `docker-compose` pour Ollama et Open WebUI

Le projet ne fournit pas encore :
- d’orchestration multi-étapes avancée
- de coordination automatique entre plusieurs modèles dans une même requête
- d’intégration d’Open WebUI via l’orchestrateur
- de LangGraph

## État réel du projet

Composants réellement présents dans le repo :

- Routeur déterministe : `src/llm_local_architecture/router.py`
- Configuration des modèles et règles : `src/llm_local_architecture/config.py`
- Orchestrateur local CLI/API : `src/llm_local_architecture/orchestrator.py`
- Tests du routeur : `tests/test_router.py`

## Architecture actuelle

### 1. Runtime local

Ollama exécute les modèles localement et expose son API sur `http://localhost:11434`.

### 2. Routeur déterministe

Le routeur Python sélectionne un modèle à partir de mots-clés, selon un ordre de priorité fixe.

Caractéristiques :
- simple
- explicable
- déterministe
- sans LangGraph
- sans routage probabiliste

### 3. Orchestrateur local minimal

L’orchestrateur FastAPI/CLI :
- reçoit un prompt
- appelle le routeur
- transmet la requête à Ollama avec le modèle choisi
- retourne la réponse
- applique un fallback simple sur `phi4-mini` si nécessaire

### 4. Interface graphique

Le `docker-compose` actuel fournit Open WebUI.

Important :
- aujourd’hui, Open WebUI parle directement à Ollama
- l’interface graphique actuelle ne bénéficie donc pas du routage automatique du projet
- le routage automatique ne s’applique aujourd’hui qu’à :
  - la CLI du projet
  - l’API FastAPI du projet

## Modèles configurés

Le routeur référence actuellement les modèles suivants :

- `qwen2.5-coder:7b-instruct`
- `granite3.3:8b`
- `deepseek-r1:7b`
- `phi4-mini`
- `mistral:7b-instruct-v0.3-q4_K_M`

Leur rôle et les règles de routage sont définis dans `src/llm_local_architecture/config.py`.

## Installation Python

Prérequis :
- Python `3.11+`
- Ollama installé et accessible localement pour la génération

Créer le virtualenv :

```bash
python3 -m venv .venv
```

Activer le virtualenv :

```bash
source .venv/bin/activate
```

Installer le projet :

```bash
pip install -e ".[dev]"
```

## Utilisation

### CLI

Commande attendue :

```bash
python -m llm_local_architecture.orchestrator "Génère un module FastAPI async"
```

Exemple :

```bash
python -m llm_local_architecture.orchestrator "Audite ce Dockerfile"
```

### API FastAPI

Lancement :

```bash
uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
```

Endpoints disponibles :
- `GET /health`
- `GET /models`
- `POST /route`
- `POST /generate`

Exemple `health` :

```bash
curl -s http://127.0.0.1:8001/health
```

Exemple `route` :

```bash
curl -s -X POST http://127.0.0.1:8001/route \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Audite ce Dockerfile"}'
```

Exemple `generate` :

```bash
curl -s -X POST http://127.0.0.1:8001/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Génère un endpoint FastAPI GET /health"}'
```

## Tests

Tests du routeur :

```bash
python3 -m pytest tests/test_router.py -v
```

Ces tests couvrent le routage déterministe.
Ils ne nécessitent pas Ollama.

## Docker

Le fichier `docker-compose.yml` ne déploie pas l’orchestrateur Python.

Il fournit deux usages :

### Profil `full`

```bash
docker compose --profile full up -d
```

Démarre :
- Ollama
- Open WebUI

### Profil `webui-only`

```bash
docker compose --profile webui-only up -d
```

Démarre :
- Open WebUI uniquement

Ce profil est utile quand Ollama tourne déjà nativement sur la machine, par exemple sous Windows.

Important :
- dans ce mode, Open WebUI pointe vers l’Ollama natif
- l’orchestrateur Python n’est pas dans la boucle

## Scripts

Le repo contient deux scripts principaux avec des rôles différents.

### `bootstrap.sh`

Script orienté runtime local des modèles :
- téléchargement des modèles via Ollama
- vérifications d’intégrité
- génération de manifest et de fichiers associés
- logique de recheck côté machine locale

Ce script correspond à la couche “modèles/Ollama”, pas à l’orchestrateur Python.

### `scripts/bootstrap.sh`

Script orienté environnement Python du projet :
- création du virtualenv
- installation des dépendances Python

Dans l’état actuel du repo, ce script doit être considéré séparément du `bootstrap.sh` racine.
Il ne remplace pas le script de gestion des modèles.

## Limites actuelles

Le projet n’est pas encore une plateforme d’orchestration avancée entre plusieurs LLM.

Aujourd’hui, il s’agit d’un socle minimal :
- un routeur déterministe
- un orchestrateur local minimal
- une façade CLI/API vers Ollama
- une interface graphique Open WebUI séparée

## Cible future

La cible future du projet est la suivante :
- plusieurs LLM locaux gérés par Ollama
- un orchestrateur Python local qui choisit automatiquement le bon modèle
- une interface graphique au-dessus de cet orchestrateur
- une intégration où la GUI passe par l’orchestrateur plutôt que directement par Ollama

Cette cible n’est pas encore l’état actuel du repo.

## Résumé

État actuel :
- le routage automatique fonctionne pour la CLI et l’API FastAPI
- Open WebUI reste séparé et parle directement à Ollama
- l’orchestrateur actuel est minimal et déterministe

Cible future :
- placer l’interface graphique au-dessus de l’orchestrateur local, pour que le routage automatique s’applique aussi à l’usage GUI
