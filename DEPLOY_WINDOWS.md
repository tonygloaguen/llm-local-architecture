# Déploiement sur Windows (PowerShell natif + GPU NVIDIA)

Ce guide explique comment déployer `llm-local-architecture` sur une machine Windows
avec GPU NVIDIA, sans WSL2, en PowerShell natif.

L’usage principal ensuite se fait via l’application FastAPI locale du repo.
Open WebUI via Docker reste optionnel.

---

## Prérequis

| Outil | Où l'obtenir | Obligatoire |
|---|---|---|
| PowerShell 7+ | https://github.com/PowerShell/PowerShell/releases | ✅ |
| Git for Windows | https://git-scm.com/download/win | ✅ |
| Drivers NVIDIA récents (570+) | https://www.nvidia.com/drivers | ✅ |
| Docker Desktop | https://www.docker.com/products/docker-desktop | ⚠️ Pour Open WebUI uniquement |
| Tesseract OCR | https://github.com/UB-Mannheim/tesseract/wiki | ⚠️ Recommandé pour images et PDF scannés |

> Ollama s'installe automatiquement par le script si absent.

---

## Installation en 3 commandes

```powershell
# 1. Ouvrir PowerShell 7 en administrateur

# 2. Autoriser l'exécution de scripts
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 3. Télécharger et lancer le script de déploiement
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/tonygloaguen/llm-local-architecture/main/deploy-windows.ps1" `
    -OutFile "$env:TEMP\deploy-windows.ps1"
.\$env:TEMP\deploy-windows.ps1 -SetupPythonEnv
```

Ou depuis un clone local :

```powershell
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture
.\deploy-windows.ps1 -SetupPythonEnv
```

---

## Ce que fait le script

1. Vérifie le GPU NVIDIA via `nvidia-smi`
2. Installe Ollama si absent (téléchargement silencieux)
3. Démarre le service Ollama
4. Clone ou met à jour le repo
5. En mode standard, conserve les modèles déjà présents et n'installe que les modèles manquants
6. Optionnellement, fait un `pull` contrôlé pour détecter une mise à jour via comparaison digest avant/après
7. Vérifie l'intégrité SHA-256 de chaque blob
8. Génère le manifest courant dans `%USERPROFILE%\.llm-local\manifests\current_manifest.json`
9. Met à jour le registre approuvé uniquement avec `-ApproveCandidates`
10. Si Docker Desktop est installé, lance Open WebUI avec `docker compose --profile webui-only up -d`
11. Vérifie la présence de Tesseract OCR et rappelle son impact fonctionnel s’il est absent
12. Optionnellement, prépare `.venv` et installe `pip install -e ".[dev]"` avec `-SetupPythonEnv`
13. Optionnellement, lance FastAPI locale avec `-LaunchApp`

---

## Options

```powershell
# Check standard : aucun pull si le modèle exact existe déjà
.\deploy-windows.ps1

# Détection fiable d'une mise à jour sans API key : pull contrôlé + comparaison digest
.\deploy-windows.ps1 -CheckByPull

# Autorise la mise à jour des modèles déjà présents
.\deploy-windows.ps1 -AutoUpdate

# Force un pull même si le modèle existe déjà
.\deploy-windows.ps1 -ForceUpdate

# Réapprouve explicitement les modèles candidate / drifted après validation humaine
.\deploy-windows.ps1 -ApproveCandidates

# Check distant optionnel si OLLAMA_API_KEY est défini
.\deploy-windows.ps1 -CheckRemoteUpdates

# Prépare aussi le virtualenv Python du projet
.\deploy-windows.ps1 -SetupPythonEnv

# Prépare le virtualenv puis lance l'application FastAPI locale
.\deploy-windows.ps1 -SetupPythonEnv -LaunchApp

# Lance seulement l'application si .venv existe déjà
.\deploy-windows.ps1 -LaunchApp
```

Comportement :

- Par défaut, le script ne dépend d'aucune API key et ne fait pas de pull automatique sur un modèle déjà présent.
- `-CheckByPull` déclenche la détection fiable sans clé API en comparant le digest local avant/après `ollama pull`.
- `-AutoUpdate` et `-ForceUpdate` autorisent un pull sur un modèle déjà installé, mais ne l'approuvent jamais automatiquement.
- Si le contenu d'un modèle approuvé change, il repasse hors `trusted` et doit être validé explicitement avec `-ApproveCandidates`.
- `-CheckRemoteUpdates` est purement optionnel. Sans `OLLAMA_API_KEY`, le script loggue le fallback et continue en mode local.
- `-SetupPythonEnv` crée `.venv` si besoin, met à jour `pip` dans le venv et installe `pip install -e ".[dev]"`.
- `-LaunchApp` lance `.\.venv\Scripts\python.exe -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001`.
- Si `-LaunchApp` est utilisé sans `.venv`, le script affiche un message clair et demande de préparer l’environnement Python.
- Pour Open WebUI sur Windows natif, le script utilise le profil Docker Compose `webui-only`.
- Un simple `docker compose up -d` ne suffit pas avec ce repo, car tous les services sont placés sous profiles. Sans profil explicite, Docker retourne `no service selected`.
- Le compose surcharge aussi le healthcheck embarqué d’Open WebUI avec un test HTTP simple sur `http://127.0.0.1:8080/`, pour éviter les faux `unhealthy` liés au parsing `jq` de l’image.
- Si Tesseract est présent, le script recommande la valeur de `TESSERACT_CMD` pour la session courante.
- Si Tesseract est absent, le déploiement continue : seul l’OCR image / PDF scanné reste indisponible.

Fonctionnement sans Tesseract :

- texte seul : OK
- PDF texte : OK
- `.txt`, `.md`, `.csv`, `.log`, `Dockerfile` : OK
- image / PDF scanné : KO avec erreur explicite

États visibles par modèle dans le manifest et le rapport final :

- `install_state` : `installed`, `already_present`, `pull_failed`
- `trust_state` : `trusted`, `candidate`, `drifted`, `quarantine`, `missing`
- `update_state` : `up_to_date`, `updated`, `update_unknown`

Exemples :

- `phi4-mini [candidate] [updated] [already_present]`
- `granite3.3:8b [trusted] [up_to_date] [already_present]`

---

## Où sont stockés les fichiers

```
%USERPROFILE%\
├── .ollama\
│   └── models\
│       ├── manifests\   ← index des modèles
│       └── blobs\       ← fichiers GGUF
├── .llm-local\
│   ├── manifests\current_manifest.json   ← état courant / trust / update
│   ├── registry\approved_models.json     ← modèles explicitement approuvés
│   └── logs\                     ← logs de déploiement
└── projets\
    └── llm-local-architecture\   ← repo cloné
```

---

## Tester après déploiement

```powershell
# Vérifier que les modèles sont bien installés
ollama list

# Test rapide
ollama run phi4-mini "Dis bonjour en une phrase"

# API Ollama
Invoke-RestMethod -Uri "http://localhost:11434/api/tags"

# Préparer l'environnement Python du projet
.\deploy-windows.ps1 -SetupPythonEnv

# Lancement principal du projet ensuite
.\.venv\Scripts\python.exe -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001

# Vérifier les services Docker du profil Windows natif
docker compose --profile webui-only config --services

# Open WebUI optionnel (si Docker Desktop lancé)
Start-Process "http://localhost:3000"
```

Routine quotidienne recommandée :

```powershell
.\deploy-windows.ps1 -LaunchApp
```

Ou sans repasser par le script :

```powershell
.\.venv\Scripts\python.exe -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
```

Commande Docker manuelle équivalente au script :

```powershell
docker compose --profile webui-only up -d
```

---

## Différences avec Linux

| Aspect | Linux | Windows natif |
|---|---|---|
| Répertoire modèles | `/usr/share/ollama/.ollama/models` | `%USERPROFILE%\.ollama\models` |
| Service Ollama | systemd | Process en tâche de fond |
| Script bootstrap | `bash bootstrap.sh` | `.\deploy-windows.ps1` |
| Préparation Python | `bash bootstrap.sh --setup-python-env` | `.\deploy-windows.ps1 -SetupPythonEnv` |
| Lancement app | `bash bootstrap.sh --launch-app` | `.\deploy-windows.ps1 -LaunchApp` |
| Recheck intégrité | cron 07h00 | Tâche planifiée Windows (à créer) |
| GPU | CUDA via driver natif | CUDA via driver natif |

---

## Déploiement distant depuis GitHub Actions

Pour que le workflow `deploy.yml` puisse déployer sur ta machine Windows,
il faut activer SSH sur Windows et configurer les secrets GitHub.

### Activer SSH sur Windows

```powershell
# En administrateur
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Vérifier
Get-Service sshd
```

### Configurer les secrets GitHub

```
GitHub → tonygloaguen/llm-local-architecture
→ Settings → Secrets and variables → Actions

DEPLOY_SSH_KEY_WIN   ← clé privée SSH (générée sur ta machine dev Linux)
DEPLOY_HOST_WIN      ← IP de la machine Windows
DEPLOY_USER_WIN      ← nom d'utilisateur Windows
```

### Générer et autoriser la clé SSH (depuis ta machine dev Linux)

```bash
# Générer la clé
ssh-keygen -t ed25519 -C "deploy-windows@llm" -f ~/.ssh/deploy_win -N ""

# Copier la clé publique sur Windows
# Sur Windows, ajouter le contenu de deploy_win.pub dans :
# C:\Users\<user>\.ssh\authorized_keys

# Tester la connexion
ssh -i ~/.ssh/deploy_win <user>@<ip-windows>

# Ajouter la clé privée comme secret GitHub
gh secret set DEPLOY_SSH_KEY_WIN < ~/.ssh/deploy_win
gh secret set DEPLOY_HOST_WIN --body "<ip-windows>"
gh secret set DEPLOY_USER_WIN --body "<user-windows>"
```

---

## Dépannage

| Problème | Solution |
|---|---|
| `ollama` non reconnu après install | Redémarrer PowerShell, vérifier `$env:PATH` |
| GPU non détecté par Ollama | Mettre à jour drivers NVIDIA (570+ requis pour RTX 5060) |
| `Set-ExecutionPolicy` refusé | Lancer PowerShell en administrateur |
| Pull modèle échoue | Vérifier connexion internet, relancer le script |
| `-LaunchApp` échoue car `.venv` absent | Relancer avec `.\deploy-windows.ps1 -SetupPythonEnv` |
| Docker compose échoue | Vérifier que Docker Desktop est lancé et WSL2 activé dans ses paramètres |
| SSH refusé depuis GitHub Actions | Vérifier `authorized_keys` et que le service `sshd` tourne |
