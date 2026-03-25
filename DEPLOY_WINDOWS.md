# Déploiement sur Windows (PowerShell natif + GPU NVIDIA)

Ce guide explique comment déployer `llm-local-architecture` sur une machine Windows
avec GPU NVIDIA, sans WSL2, en PowerShell natif.

---

## Prérequis

| Outil | Où l'obtenir | Obligatoire |
|---|---|---|
| PowerShell 7+ | https://github.com/PowerShell/PowerShell/releases | ✅ |
| Git for Windows | https://git-scm.com/download/win | ✅ |
| Drivers NVIDIA récents (570+) | https://www.nvidia.com/drivers | ✅ |
| Docker Desktop | https://www.docker.com/products/docker-desktop | ⚠️ Pour Open WebUI uniquement |

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
.\$env:TEMP\deploy-windows.ps1
```

Ou depuis un clone local :

```powershell
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture
.\deploy-windows.ps1
```

---

## Ce que fait le script

1. Vérifie le GPU NVIDIA via `nvidia-smi`
2. Installe Ollama si absent (téléchargement silencieux)
3. Démarre le service Ollama
4. Clone ou met à jour le repo
5. Télécharge les 5 modèles via `ollama pull`
6. Vérifie l'intégrité SHA-256 de chaque blob
7. Génère le manifest dans `%USERPROFILE%\.llm-local\manifests\manifest.json`
8. Lance Docker Compose si Docker Desktop est installé

---

## Où sont stockés les fichiers

```
%USERPROFILE%\
├── .ollama\
│   └── models\
│       ├── manifests\   ← index des modèles
│       └── blobs\       ← fichiers GGUF
├── .llm-local\
│   ├── manifests\manifest.json   ← état d'intégrité
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
ollama run phi4-mini:3.8b "Dis bonjour en une phrase"

# API Ollama
Invoke-RestMethod -Uri "http://localhost:11434/api/tags"

# Open WebUI (si Docker Desktop lancé)
Start-Process "http://localhost:3000"
```

---

## Différences avec Linux

| Aspect | Linux | Windows natif |
|---|---|---|
| Répertoire modèles | `/usr/share/ollama/.ollama/models` | `%USERPROFILE%\.ollama\models` |
| Service Ollama | systemd | Process en tâche de fond |
| Script bootstrap | `bash bootstrap.sh` | `.\deploy-windows.ps1` |
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
| Docker compose échoue | Vérifier que Docker Desktop est lancé et WSL2 activé dans ses paramètres |
| SSH refusé depuis GitHub Actions | Vérifier `authorized_keys` et que le service `sshd` tourne |
