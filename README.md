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
- un `docker-compose` optionnel pour Ollama et Open WebUI

Le projet ne fournit pas encore :
- d’orchestration multi-étapes avancée
- de coordination automatique entre plusieurs modèles dans une même requête
- d’intégration d’Open WebUI via l’orchestrateur
- de LangGraph

## À lire d’abord

L’interface principale du projet est l’application FastAPI locale :

- URL locale : `http://127.0.0.1:8001`
- lancement : `uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001`
- Open WebUI via Docker : optionnel

Il y a maintenant trois moments distincts dans la vie du projet :

1. Préparer le runtime local des modèles.
2. Préparer l’environnement Python du repo.
3. Lancer FastAPI au quotidien.

### 1. Préparer le runtime local des modèles

Les scripts racine servent d’abord à préparer Ollama, les modèles et l’OCR :

- Linux : `bash bootstrap.sh`
- Windows : `.\deploy-windows.ps1`

Ils gèrent :

- l’installation ou la vérification d’Ollama selon la plateforme
- le téléchargement contrôlé des modèles
- les vérifications d’intégrité et d’approbation
- la validation OCR locale réelle : binaire Tesseract, langue `fra`, imports Python OCR (`cv2`, `numpy`, `pytesseract`) et test runtime minimal
- Open WebUI via Docker en option

États exposés par modèle :

- `install_state` : `installed`, `already_present`, `pull_failed`
- `trust_state` : `trusted`, `candidate`, `drifted`, `quarantine`, `missing`
- `update_state` : `up_to_date`, `updated`, `update_unknown`

### 2. Préparer l’environnement Python

Le package Python du projet est défini dans `pyproject.toml`.

Les scripts principaux savent maintenant aussi préparer `.venv` :

- Linux : `bash bootstrap.sh --setup-python-env`
- Windows : `.\deploy-windows.ps1 -SetupPythonEnv`

Cette étape :

- crée `.venv` si absent
- met à jour `pip` dans le virtualenv
- installe `pip install -e ".[dev]"`

### 3. Lancer FastAPI au quotidien

Lancement direct :

- Linux : `.venv/bin/python -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001`
- Windows : `.\.venv\Scripts\python.exe -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001`

Ou via les nouvelles options :

- Linux : `bash bootstrap.sh --launch-app`
- Windows : `.\deploy-windows.ps1 -LaunchApp`

Si `.venv` n’existe pas encore :

- Linux : `bash bootstrap.sh --setup-python-env --launch-app`
- Windows : `.\deploy-windows.ps1 -SetupPythonEnv -LaunchApp`

En routine, il n’est pas nécessaire de relancer le bootstrap des modèles à chaque session.

## Déploiement guidé selon le système

### Linux

Préparation complète :

```bash
bash bootstrap.sh --setup-python-env
```

Lancement quotidien :

```bash
.venv/bin/python -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
```

Lancement via script :

```bash
bash bootstrap.sh --launch-app
```

### Windows 11

Préparation complète :

```powershell
.\deploy-windows.ps1 -SetupPythonEnv
```

Lancement quotidien :

```powershell
.\.venv\Scripts\python.exe -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
```

Lancement via script :

```powershell
.\deploy-windows.ps1 -LaunchApp
```

### Stratégie GPU Windows 11 / RTX 5060 8 Go

Sur une machine Windows équipée d’une RTX 5060 8 Go, le point de vigilance principal n’est pas le routage mais la résidence mémoire côté Ollama.

Plusieurs modèles 7B peuvent tenir individuellement en VRAM, mais leur cohabitation provoque vite :

- éviction partielle vers le CPU
- latence très variable
- débit instable selon l’ordre des appels

L’orchestrateur applique donc une stratégie stricte de résidence unique :

- un seul modèle chargé à la fois
- lecture de `ollama ps` avant exécution
- arrêt automatique des autres modèles avant chaque génération
- exécution avec `keep_alive=0` pour éviter qu’un modèle reste résident après la réponse
- logs explicites sur le modèle sélectionné, `ollama ps` avant purge, après purge et après génération

Cette stratégie est activée par défaut via :

- `OLLAMA_ENFORCE_SINGLE_MODEL_RESIDENCY=1`
- `OLLAMA_GENERATE_KEEP_ALIVE=0`

Pour diagnostiquer un fallback CPU ou une latence anormale sous Windows, vérifier d’abord :

- `ollama ps`
- l’usage VRAM dans le panneau NVIDIA
- les logs FastAPI de l’orchestrateur

Dans les deux cas, ouvrir ensuite `http://127.0.0.1:8001`.
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
si Tesseract est absent : image / PDF scanné -> erreur explicite, sans impacter les autres formats
6. Mémoire locale

La mémoire persistante locale s’appuie sur SQLite et distingue trois couches :

mémoire courte
mémoire documentaire
mémoire préférences

Le routage reste centré sur la demande courante et le document courant.
La mémoire sert surtout à enrichir la génération, pas à polluer le choix du modèle.

7. Open WebUI via Docker

Le docker-compose actuel fournit aussi Open WebUI, mais cette GUI reste séparée et optionnelle.

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
soit configuré explicitement via OCR_TESSERACT_CMD

Fonctionnement sans OCR :

- prompts texte : OK
- PDF texte : OK
- `.txt`, `.md`, `.csv`, `.log`, `Dockerfile` : OK
- image / PDF scanné : KO avec erreur explicite tant que Tesseract n’est pas installé

Important :

sans Tesseract :
prompt texte seul : fonctionne
PDF texte : fonctionne
.txt, .md, .csv, .log, Dockerfile : fonctionnent
image / PDF scanné : échouent avec une erreur explicite

### Installation Tesseract

Linux Debian/Ubuntu :

```bash
sudo apt-get update
sudo apt-get install -y tesseract-ocr tesseract-ocr-fra tesseract-ocr-eng
```

Windows :

- installer Tesseract depuis UB Mannheim ou un package interne équivalent
- vérifier que `tesseract.exe` est dans le `PATH`
- sinon définir `OCR_TESSERACT_CMD=C:\Program Files\Tesseract-OCR\tesseract.exe`

Langues :

- la langue OCR par défaut du projet est `fra`
- le fallback configurable recommandé est `fra+eng`
- si `fra` ou `fra+eng` sont configurés sans packs installés, l’erreur retournée est explicite
- les scripts `bootstrap.sh` et `deploy-windows.ps1` considèrent `fra` comme indispensable pour un environnement OCR nominal
- `eng` reste recommandé pour le fallback, mais son absence ne bloque pas l’usage français principal

### Prétraitement OCR

Le pipeline OCR reste entièrement local et repose sur OpenCV avant Tesseract :

- conversion en niveaux de gris
- agrandissement si l’image est trop petite
- réduction de bruit
- amélioration de contraste avec CLAHE
- binarisation Otsu et adaptive selon plusieurs variantes
- deskew simple si activé
- bordure blanche légère
- morphologie légère pour améliorer la lisibilité

Le moteur essaie ensuite plusieurs combinaisons de preprocessing, `--psm` et langue, score les résultats et conserve l’extraction brute la plus crédible.

### Diagnostic de base

Les scripts de préparation valident maintenant l’OCR de manière opérationnelle :

- détection explicite du binaire Tesseract
- vérification des langues installées
- vérification des imports Python OCR dans le virtualenv
- test OCR fonctionnel minimal sur une image synthétique

Si cette validation échoue, le script sort en erreur non nulle au lieu de considérer l’environnement comme prêt.
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
OCR_DPI
OCR_TESSERACT_LANG
OCR_TESSERACT_FALLBACK_LANG
OCR_TESSERACT_PSM
OCR_TESSERACT_SPARSE_PSM
OCR_TESSERACT_OEM
OCR_ENABLE_DESKEW
OCR_ENABLE_MULTI_PASS
OCR_MIN_TEXT_LENGTH
OCR_MIN_EXTRACTED_CHARS
OCR_DEBUG_SAVE_INTERMEDIATES
OCR_TESSERACT_CMD
TESSERACT_CMD

Exemple :

export OLLAMA_BASE_URL=http://localhost:11434
export OCR_TESSERACT_LANG=fra
export OCR_TESSERACT_FALLBACK_LANG=fra+eng
export OCR_TESSERACT_PSM=6
export OCR_ENABLE_MULTI_PASS=1
export OCR_ENABLE_DESKEW=1
export OCR_TESSERACT_CMD=/usr/bin/tesseract
Tests

Suite validée actuellement :

routeur
mémoire
documents
ocr
web

Commande :

python -m pytest tests/test_router.py tests/test_memory.py tests/test_documents.py tests/test_ocr.py tests/test_web_app.py -v

Ces tests :

ne nécessitent pas tous Ollama
couvrent le cœur du routage
couvrent la mémoire SQLite
couvrent le pipeline documentaire
couvrent le scoring et la stratégie OCR
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
le compose surcharge aussi le healthcheck Open WebUI pour éviter le healthcheck jq embarqué dans l’image, qui peut marquer le conteneur `unhealthy` alors que l’UI répond bien
dans ce mode, Open WebUI pointe vers l’Ollama natif
l’orchestrateur Python n’est pas dans la boucle
Scripts

Le repo contient deux scripts principaux avec des rôles différents.

`bootstrap.sh`

- prépare le runtime local Ollama/modèles/OCR
- peut aussi préparer `.venv` avec `--setup-python-env`
- peut lancer FastAPI avec `--launch-app`

`deploy-windows.ps1`

- prépare le runtime local Ollama/modèles/OCR sur Windows natif
- peut aussi préparer `.venv` avec `-SetupPythonEnv`
- peut lancer FastAPI avec `-LaunchApp`

`scripts/bootstrap.sh`

- reste un script séparé orienté environnement Python
- ne remplace pas les scripts racine pour la gestion Ollama/modèles

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
soit configuré via OCR_TESSERACT_CMD

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

Limites OCR connues :

- Tesseract reste un bon compromis offline Windows/Linux, pas une solution universelle pour tous les documents très dégradés
- les scans flous, très compressés ou avec mise en page complexe restent difficiles
- le scoring heuristique favorise le texte plausible, mais ne remplace pas une validation humaine sur documents critiques
- le mode debug OCR peut générer beaucoup d’images intermédiaires dans `data/ocr/`

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
