# llm-local-architecture

Application locale simple au-dessus d’Ollama, avec :
- un routage automatique explicable entre plusieurs LLM locaux
- une interface web locale légère servie par FastAPI
- un support documentaire local (PDF, images OCR, fichiers texte simples)
- une mémoire persistante locale

Le projet fournit aujourd’hui :
- un routeur Python déterministe
- un orchestrateur local FastAPI/CLI au-dessus d’Ollama
- une interface web locale simple
- un pipeline documentaire local
- un OCR local configurable
- une mémoire locale persistante en SQLite
- un `docker-compose` pour Ollama et Open WebUI

Le projet ne fournit pas encore :
- d’orchestration multi-étapes avancée
- de coordination automatique entre plusieurs modèles dans une même requête
- d’intégration d’Open WebUI via l’orchestrateur
- de LangGraph

## À lire d’abord

Il y a deux moments distincts dans la vie du projet :

### 1. Première installation

Si tu pars d’une machine où Ollama n’est pas encore prêt, le premier geste n’est **pas** de lancer FastAPI.

Le premier geste est :

- **Linux** : exécuter `bootstrap.sh`
- **Windows** : exécuter `deploy-windows.ps1`

Ces scripts servent à préparer la couche runtime locale des modèles :
- installation / préparation d’Ollama selon le système
- téléchargement des modèles locaux
- vérifications associées
- préparation de l’environnement local nécessaire

Modes de contrôle disponibles pour les scripts de déploiement :

- Check standard : ne fait pas de `pull` si le modèle exact est déjà présent localement.
- Check by pull : fait un `pull` contrôlé et compare le digest avant/après pour détecter une mise à jour sans dépendre d’une API key.
- Auto update : autorise la mise à jour des modèles déjà présents via `pull`, sans approbation automatique.
- Force update : force un `pull` même si le modèle est déjà présent.
- Approve candidates : écrit explicitement dans le registre approuvé après validation humaine.
- Remote check : optionnel, nécessite `OLLAMA_API_KEY` pour comparer le digest local au digest distant via `https://ollama.com/api`.

États exposés par modèle :

- `install_state` : `installed`, `already_present`, `pull_failed`
- `trust_state` : `trusted`, `candidate`, `drifted`, `quarantine`, `missing`
- `update_state` : `up_to_date`, `updated`, `update_unknown`

Ensuite seulement tu prépares l’environnement Python du projet.

### 2. Routine normale ensuite

Une fois la machine préparée et les modèles déjà présents localement :
- tu actives le virtualenv
- tu lances FastAPI
- tu ouvres l’interface web locale

En routine, tu n’as pas à relancer le bootstrap des modèles à chaque fois.

## Déploiement guidé selon le système

## Linux

### Étape 1 — préparer Ollama et les modèles

Depuis la racine du repo :

```bash
bash bootstrap.sh

Ce script correspond à la couche runtime locale des modèles, pas à l’application FastAPI elle-même.

Étape 2 — préparer l’environnement Python

Créer le virtualenv :

python3 -m venv .venv

Activer le virtualenv :

source .venv/bin/activate

Installer le projet :

pip install -e ".[dev]"
Étape 3 — lancer l’application
uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

Puis ouvrir :

http://127.0.0.1:8001
Windows 11
Étape 1 — préparer Ollama et les modèles

Depuis la racine du repo, dans PowerShell :

.\deploy-windows.ps1

Ce script correspond à la couche runtime locale des modèles, pas à l’application FastAPI elle-même.

Étape 2 — préparer l’environnement Python

Créer le virtualenv :

python -m venv .venv

Activer le virtualenv :

.\.venv\Scripts\Activate.ps1

Installer le projet :

python -m pip install -e ".[dev]"
Étape 3 — lancer l’application
uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

Puis ouvrir :

http://127.0.0.1:8001
Routine normale

Quand tout est déjà installé sur la machine, le cycle normal est :

Linux
source .venv/bin/activate
uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
Windows
.\.venv\Scripts\Activate.ps1
uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

Puis ouvrir :

http://127.0.0.1:8001
État réel du projet

Composants réellement présents dans le repo :

Routeur déterministe : src/llm_local_architecture/router.py
Configuration centrale : src/llm_local_architecture/config.py
Orchestrateur local CLI/API/web : src/llm_local_architecture/orchestrator.py
Pipeline documentaire : src/llm_local_architecture/documents.py
OCR local : src/llm_local_architecture/ocr.py
Mémoire SQLite : src/llm_local_architecture/memory.py
Construction du contexte/prompt : src/llm_local_architecture/prompting.py
Stockage local : src/llm_local_architecture/storage.py
Schémas : src/llm_local_architecture/schemas.py
Interface web locale : src/llm_local_architecture/static/
Tests routeur : tests/test_router.py
Tests documents : tests/test_documents.py
Tests mémoire : tests/test_memory.py
Tests web : tests/test_web_app.py
Architecture actuelle
1. Runtime local

Ollama exécute les modèles localement et expose son API sur http://localhost:11434.

2. Routeur déterministe

Le routeur Python sélectionne un modèle à partir de mots-clés, selon un ordre de priorité fixe.

Caractéristiques :

simple
explicable
déterministe
sans LangGraph
sans routage probabiliste
robuste aux accents dans les prompts français
3. Orchestrateur local

L’orchestrateur FastAPI/CLI :

reçoit un prompt, un document ou les deux
appelle le routeur
transmet la requête à Ollama avec le modèle choisi
retourne la réponse
applique un fallback simple sur phi4-mini si nécessaire
gère aussi :
l’interface web locale
le pipeline documentaire
la mémoire persistante
les métadonnées de réponse
4. Interface web locale

L’interface web locale est servie directement par FastAPI.

Elle fournit :

un champ prompt
un upload de document
un bouton d’envoi
l’affichage de la réponse
l’affichage du modèle choisi
l’affichage de l’usage OCR ou non
l’affichage du type d’entrée
l’affichage des sources mémoire utilisées
5. Pipeline documentaire

Le pipeline documentaire local prend en charge :

PDF texte
PDF scannés
images OCR
fichiers texte simples :
.txt
.md
.csv
.log
Dockerfile

Comportement :

PDF texte : extraction directe
image / PDF scanné : OCR local si nécessaire
texte simple : lecture directe sans OCR
6. Mémoire locale

La mémoire persistante locale s’appuie sur SQLite et distingue trois couches :

mémoire courte
mémoire documentaire
mémoire préférences

Le routage reste centré sur la demande courante et le document courant.
La mémoire sert surtout à enrichir la génération, pas à polluer le choix du modèle.

7. Open WebUI via Docker

Le docker-compose actuel fournit aussi Open WebUI, mais cette GUI reste séparée.

Important :

aujourd’hui, Open WebUI parle directement à Ollama
l’interface graphique Open WebUI ne bénéficie donc pas du routage automatique du projet
le routage automatique du projet s’applique à :
la CLI du projet
l’API FastAPI du projet
l’interface web locale servie par FastAPI
Modèles configurés

Le routeur référence actuellement les modèles suivants :

qwen2.5-coder:7b-instruct
granite3.3:8b
deepseek-r1:7b
phi4-mini
mistral:7b-instruct-v0.3-q4_K_M

Leur rôle et les règles de routage sont définis dans src/llm_local_architecture/config.py.

Prérequis
Python
Python 3.11+
Runtime LLM
Ollama installé
Ollama accessible localement sur http://localhost:11434
modèles déjà téléchargés localement
OCR

Pour l’OCR des images et PDF scannés :

Tesseract doit être installé localement
et soit :
accessible dans le PATH
soit configuré explicitement via TESSERACT_CMD

Important :

sans Tesseract :
prompt texte seul : fonctionne
PDF texte : fonctionne
.txt, .md, .csv, .log, Dockerfile : fonctionnent
image / PDF scanné : échouent avec une erreur explicite
Utilisation
Interface web locale

Lancement :

uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

Puis ouvrir :

http://127.0.0.1:8001

L’interface web locale permet :

texte seul
document seul
texte + document
CLI

Commande attendue :

python -m llm_local_architecture.orchestrator "Génère un module FastAPI async"

Exemple :

python -m llm_local_architecture.orchestrator "Audite ce Dockerfile"
API FastAPI

Lancement :

uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

Endpoints disponibles :

GET /health
GET /models
POST /route
POST /generate
POST /chat
GET /

Exemple health :

curl -s http://127.0.0.1:8001/health

Exemple route :

curl -s -X POST http://127.0.0.1:8001/route \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Audite ce Dockerfile"}'

Exemple generate :

curl -s -X POST http://127.0.0.1:8001/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Génère un endpoint FastAPI GET /health"}'

Exemple chat texte seul :

curl -s -X POST http://127.0.0.1:8001/chat \
  -F 'prompt=Rédige un mail professionnel de relance'

Exemple chat avec document :

curl -s -X POST http://127.0.0.1:8001/chat \
  -F 'prompt=Résume ce document en 10 points clés' \
  -F 'document=@./mon_document.pdf'
Stockage local

Par défaut, l’application crée un stockage local persistant à la racine du repo dans data/.

Structure attendue :

data/
├── app.db
├── documents/
├── extracted/
└── ocr/

Contenu :

app.db : SQLite
documents/ : fichiers importés
extracted/ : textes extraits
ocr/ : artefacts OCR éventuels

Ce chemin peut être surchargé avec :

LLM_LOCAL_DATA_DIR

Variables d’environnement utiles
OLLAMA_BASE_URL
ORCHESTRATOR_PORT
LLM_LOCAL_DATA_DIR
SHORT_TERM_MESSAGE_LIMIT
MAX_CONTEXT_CHARS
DOCUMENT_EXCERPT_CHARS
ROUTING_EXCERPT_CHARS
OCR_ENABLED
OCR_LANG
OCR_DPI
OCR_MIN_EXTRACTED_CHARS
TESSERACT_CMD

Exemple :

export OLLAMA_BASE_URL=http://localhost:11434
export OCR_LANG=fra+eng
export TESSERACT_CMD=/usr/bin/tesseract
Tests

Suite validée actuellement :

routeur
mémoire
documents
web

Commande :

python -m pytest tests/test_router.py tests/test_memory.py tests/test_documents.py tests/test_web_app.py -v

Ces tests :

ne nécessitent pas tous Ollama
couvrent le cœur du routage
couvrent la mémoire SQLite
couvrent le pipeline documentaire
couvrent l’API web locale
Docker

Le fichier docker-compose.yml ne déploie pas l’orchestrateur Python.

Il fournit deux usages :

Profil full
docker compose --profile full up -d

Démarre :

Ollama
Open WebUI
Profil webui-only
docker compose --profile webui-only up -d

Démarre :

Open WebUI uniquement

Ce profil est utile quand Ollama tourne déjà nativement sur la machine, par exemple sous Windows.

Important :

un simple `docker compose up -d` ne suffit pas dans ce repo, car tous les services sont placés sous profiles
sans `--profile full` ou `--profile webui-only`, Docker peut répondre `no service selected`
dans ce mode, Open WebUI pointe vers l’Ollama natif
l’orchestrateur Python n’est pas dans la boucle
Scripts

Le repo contient deux scripts principaux avec des rôles différents.

bootstrap.sh

Script orienté runtime local des modèles :

téléchargement des modèles via Ollama
vérifications d’intégrité
génération de manifest et de fichiers associés
logique de recheck côté machine locale

Ce script correspond à la couche “modèles/Ollama”, pas à l’orchestrateur Python.

scripts/bootstrap.sh

Script orienté environnement Python du projet :

création du virtualenv
installation des dépendances Python

Dans l’état actuel du repo, ce script doit être considéré séparément du bootstrap.sh racine.
Il ne remplace pas le script de gestion des modèles.

Déploiement Windows 11

Points d’attention réels sur une cible Windows 11 :

1. Ollama

Il faut :

Ollama installé
modèles présents localement
service accessible sur http://localhost:11434
2. Tesseract

Pour l’OCR image / PDF scanné :

Tesseract doit être installé
soit dans le PATH
soit configuré via TESSERACT_CMD

Sans cela :

PDF texte : OK
.txt, .md, .csv, .log, Dockerfile : OK
image / scan : erreur explicite
3. Droits d’écriture

L’application écrit dans data/ par défaut.
Vérifier les droits d’écriture dans le dossier du projet.

4. Lancement attendu

Dans le repo, depuis le virtualenv :

python -m pip install -e ".[dev]"
uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

Puis ouvrir :

http://127.0.0.1:8001

5. Recette minimale Windows 11

Tests conseillés :

prompt texte simple
prompt rédaction sans accents
upload .txt
upload Dockerfile
upload PDF texte
upload image scannée pour valider Tesseract
Limites actuelles

Le projet n’est pas encore une plateforme d’orchestration avancée entre plusieurs LLM.

Aujourd’hui, il s’agit d’un socle local exploitable :

un routeur déterministe
un orchestrateur local FastAPI/CLI
une interface web locale simple
une façade vers Ollama
une mémoire locale persistante
un pipeline documentaire local
une GUI Open WebUI séparée via Docker
Cible future

La cible future du projet est la suivante :

plusieurs LLM locaux gérés par Ollama
un orchestrateur Python local qui choisit automatiquement le bon modèle
une interface graphique unifiée au-dessus de cet orchestrateur
une intégration où toute GUI passe par l’orchestrateur plutôt que directement par Ollama

Cette cible n’est pas encore l’état actuel du repo.

Résumé

État actuel :

le routage automatique fonctionne pour la CLI, l’API FastAPI et l’interface web locale
Open WebUI reste séparé et parle directement à Ollama
l’orchestrateur actuel reste simple, local et déterministe
le pipeline documentaire local est opérationnel
la mémoire locale persistante est opérationnelle

Cible future :

placer toutes les interfaces graphiques au-dessus de l’orchestrateur local, pour que le routage automatique s’applique à tous les usages GUI
 ​:contentReference[oaicite:0]{index=0}​
