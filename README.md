# llm-local-architecture

Environnement local de modèles LLM open-source, orchestrés et sécurisés.  
Pas de cloud. Pas d'API payante. Tout tourne sur ta machine.

---

## Ce que ce repo contient

| Fichier / Dossier | Rôle |
|---|---|
| `bootstrap.sh` | Télécharge les 5 modèles sur Linux, vérifie leur intégrité, génère le manifest |
| `deploy-windows.ps1` | Équivalent de bootstrap.sh pour Windows PowerShell natif |
| `docker-compose.yml` | Lance Ollama + Open WebUI en conteneurs Docker |
| `.github/workflows/` | CI/CD automatique (lint, sécurité, déploiement) |
| `DEPLOY_WINDOWS.md` | Guide complet déploiement Windows |
| `PARTIE1_batch_modeles.md` | Analyse détaillée des modèles retenus |
| `PARTIE2_orchestration.md` | Logique de routing automatique entre modèles |
| `PARTIE3_integrite.md` | Procédures de vérification d'intégrité |
| `PARTIE4_nis2.md` | Checklist sécurité NIS2 adaptée |
| `PARTIE5_controles.md` | Contrôles récurrents (quotidien/hebdo/mensuel) |
| `PARTIE6_architecture.md` | Architecture technique complète |
| `PARTIE7_benchmark.md` | Script de benchmark local |
| `PARTIE8_verdict.md` | Verdict final et plan de mise en œuvre |

---

## Les 5 modèles du batch

| Modèle | Rôle | Taille Q4 |
|---|---|---|
| `qwen2.5-coder:7b-instruct-q4_K_M` | Code Python, FastAPI, LangGraph | ~4.7 Go |
| `granite3.3:8b` | Audit sécurité, DevSecOps, CI/CD | ~4.9 Go |
| `deepseek-r1:7b` | Agent brain, raisonnement, orchestration | ~4.7 Go |
| `phi4-mini:3.8b` | Debug rapide, routing, sanity check | ~2.5 Go |
| `mistral:7b-instruct-v0.3-q4_K_M` | Rédaction française, documents | ~4.4 Go |

> **Note :** Un seul modèle 7-8B tient en VRAM à la fois sur 8 Go.  
> `phi4-mini` (2.5 Go) peut coexister avec n'importe quel autre modèle.

---

## Comment ça marche — vue d'ensemble

```
┌─────────────────────────────────────────────────────┐
│                   TON USAGE QUOTIDIEN               │
│                                                     │
│  "Génère un module FastAPI"  →  qwen2.5-coder       │
│  "Audite ce Dockerfile"      →  granite3.3          │
│  "Orchestre cet agent"       →  deepseek-r1         │
│  "Debug rapide"              →  phi4-mini           │
│  "Rédige ce mail"            →  mistral             │
└─────────────────────────────────────────────────────┘
             ↓ via API locale Ollama (port 11434)
┌─────────────────────────────────────────────────────┐
│                      OLLAMA                         │
│         Runtime local — gère les modèles            │
│         API compatible OpenAI sur :11434            │
└─────────────────────────────────────────────────────┘
             ↓ modèles stockés dans
┌─────────────────────────────────────────────────────┐
│  Linux : /usr/share/ollama/.ollama/models/          │
│  Windows : %USERPROFILE%\.ollama\models\            │
│  Blobs vérifiés SHA-256 quotidiennement             │
└─────────────────────────────────────────────────────┘
```

---

## Installation selon ton OS

### Linux (Ubuntu 24.04)

```bash
# 1. Cloner le repo
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture

# 2. Installer Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 3. Lancer le bootstrap (télécharge + vérifie les modèles)
#    Durée : 20-60 min selon le débit réseau
bash bootstrap.sh

# 4. Tester
ollama run phi4-mini:3.8b "Dis bonjour en une phrase"
```

### Windows (PowerShell natif + GPU NVIDIA)

```powershell
# 1. Ouvrir PowerShell 7 en administrateur

# 2. Autoriser l'exécution de scripts
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 3. Cloner le repo
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture

# 4. Lancer le script de déploiement
#    (installe Ollama automatiquement si absent)
.\deploy-windows.ps1

# 5. Tester
ollama run phi4-mini:3.8b "Dis bonjour en une phrase"
```

> Pour le guide complet Windows : voir [DEPLOY_WINDOWS.md](DEPLOY_WINDOWS.md)

---

## Lancement quotidien avec Docker (Linux et Windows)

```bash
# Démarrer Ollama + Open WebUI
docker compose up -d

# Accéder à l'interface web
# → http://localhost:3000

# Arrêter
docker compose down
```

---

## Différences Linux vs Windows

| Aspect | Linux | Windows natif |
|---|---|---|
| Script de déploiement | `bash bootstrap.sh` | `.\deploy-windows.ps1` |
| Répertoire modèles | `/usr/share/ollama/.ollama/models` | `%USERPROFILE%\.ollama\models` |
| Service Ollama | systemd | Process en tâche de fond |
| Recheck intégrité | cron 07h00 | Tâche planifiée (manuelle) |
| GPU | CUDA natif | CUDA natif |
| Docker | Docker Engine | Docker Desktop |

---

## Vérification d'intégrité

Le bootstrap vérifie automatiquement l'intégrité SHA-256 de chaque modèle après téléchargement.  
Sur Linux, un recheck automatique tourne chaque jour à 07h00 via cron.

```bash
# Recheck manuel (Linux)
bash ~/.llm-local/recheck.sh

# Voir le manifest
cat ~/.llm-local/manifests/manifest.json | python3 -m json.tool

# Voir les logs
ls ~/.llm-local/logs/
```

**Statuts possibles :**

| Statut | Signification |
|---|---|
| `trusted` | Hash local = hash source HuggingFace — vérification totale |
| `unverified` | Hash local OK, divergence attendue avec HF (comportement normal Ollama) |
| `quarantine` | Problème détecté — modèle à re-télécharger |

---

## CI/CD — Ce qui se passe automatiquement sur GitHub

### À chaque push sur `dev` ou `main`

Le workflow **CI** se déclenche automatiquement :
- Lint des scripts bash avec `shellcheck`
- Validation du `docker-compose.yml`
- Validation des fichiers JSON

### Chaque lundi à 06h00

Le workflow **Security** se déclenche automatiquement :
- Scan des secrets avec Gitleaks
- Scan de vulnérabilités avec Trivy

### Déploiement sur machine physique (manuel)

Le workflow **Deploy** se lance depuis GitHub :

```
GitHub → Actions → Deploy → Run workflow
→ Choisir la cible : linux-bare-metal ou windows-wsl2
→ Taper "DEPLOY" pour confirmer
```

Le workflow se connecte en SSH à la machine cible et exécute :
```bash
git pull origin main
docker compose pull
docker compose up -d
```

---

## Branching strategy

```
main   ← branche stable, déployable, protégée
  └── dev  ← développement quotidien
        ├── feature/xxx  ← nouvelles fonctionnalités
        └── fix/xxx      ← corrections
```

**Règle :** tu travailles sur `dev`, tu merges vers `main` via Pull Request quand c'est stable.  
Le déploiement physique se fait toujours depuis `main`.

```bash
# Workflow quotidien
git checkout dev
git add .
git commit -m "fix: description du changement"
git push origin dev
# → créer une PR dev → main sur GitHub quand prêt
```

---

## Ajouter une machine cible pour le déploiement

### Linux

```bash
# Sur ta machine dev — générer une clé SSH dédiée
ssh-keygen -t ed25519 -C "deploy@llm-local" -f ~/.ssh/deploy_llm -N ""

# Autoriser la clé sur la machine cible
ssh-copy-id -i ~/.ssh/deploy_llm.pub user@ip-machine-cible

# Ajouter les secrets GitHub
gh secret set DEPLOY_SSH_KEY < ~/.ssh/deploy_llm
gh secret set DEPLOY_HOST --body "ip-machine-cible"
gh secret set DEPLOY_USER --body "user"
```

### Windows

```powershell
# Activer SSH sur la machine Windows cible (en administrateur)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

```bash
# Depuis ta machine dev Linux — autoriser la clé
ssh-keygen -t ed25519 -C "deploy-win@llm" -f ~/.ssh/deploy_win -N ""
# Copier deploy_win.pub dans C:\Users\<user>\.ssh\authorized_keys sur Windows

# Ajouter les secrets GitHub
gh secret set DEPLOY_SSH_KEY_WIN < ~/.ssh/deploy_win
gh secret set DEPLOY_HOST_WIN --body "ip-machine-windows"
gh secret set DEPLOY_USER_WIN --body "user-windows"
```

---

## Structure des fichiers générés (hors repo)

```
~/.llm-local/               (Linux)
%USERPROFILE%\.llm-local\   (Windows)
├── manifests/
│   └── manifest.json       ← état de chaque modèle
├── logs/
│   ├── bootstrap_*.log     ← logs d'installation
│   ├── integrity_*.log     ← logs recheck quotidien
│   └── cron.log            ← logs cron (Linux)
├── trusted/
│   └── trusted_blobs.log
└── quarantine/
    └── quarantine.log
```

Ces fichiers sont locaux à chaque machine et non versionnés (`.gitignore`).

---

## Dépannage rapide

| Problème | Linux | Windows |
|---|---|---|
| Ollama ne répond pas | `systemctl status ollama` | `Get-Process ollama` |
| Modèle en quarantaine | `cat ~/.llm-local/quarantine/quarantine.log` | `notepad $env:USERPROFILE\.llm-local\quarantine\quarantine.log` |
| Relancer le bootstrap | `bash bootstrap.sh` | `.\deploy-windows.ps1` |
| Voir les modèles | `ollama list` | `ollama list` |
| Tester un modèle | `ollama run phi4-mini:3.8b "test"` | `ollama run phi4-mini:3.8b "test"` |
| Open WebUI inaccessible | `docker compose ps` | `docker compose ps` |

---

## Liens utiles

- Repo GitHub : https://github.com/tonygloaguen/llm-local-architecture
- Ollama : https://ollama.ai
- Open WebUI : https://github.com/open-webui/open-webui
- Modèles disponibles : https://ollama.com/library
- Guide Windows complet : [DEPLOY_WINDOWS.md](DEPLOY_WINDOWS.md)
