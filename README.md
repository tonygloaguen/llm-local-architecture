# llm-local-architecture

Environnement local de modèles LLM open-source, orchestrés et sécurisés.  
Pas de cloud. Pas d'API payante. Tout tourne sur ta machine.

---

## Ce que ce repo contient

| Fichier / Dossier | Rôle |
|---|---|
| `bootstrap.sh` | Télécharge les 5 modèles, vérifie leur intégrité, génère le manifest |
| `docker-compose.yml` | Lance Ollama + Open WebUI en conteneurs Docker |
| `.github/workflows/` | CI/CD automatique (lint, sécurité, déploiement) |
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
│                   TON USAGE QUOTIDIEN                │
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
│         API compatible OpenAI sur :8080             │
└─────────────────────────────────────────────────────┘
             ↓ modèles stockés dans
┌─────────────────────────────────────────────────────┐
│         /usr/share/ollama/.ollama/models/           │
│         Blobs vérifiés SHA-256 quotidiennement      │
└─────────────────────────────────────────────────────┘
```

---

## Utilisation — 3 scénarios

### Scénario 1 — Première installation sur une nouvelle machine

```bash
# 1. Cloner le repo
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture

# 2. Installer Ollama si pas déjà fait
curl -fsSL https://ollama.com/install.sh | sh

# 3. Lancer le bootstrap (télécharge + vérifie les modèles)
#    Durée : 20-60 min selon le débit réseau
bash bootstrap.sh

# 4. Tester un modèle
ollama run phi4-mini:3.8b "Dis bonjour en une phrase"
```

### Scénario 2 — Lancement quotidien avec Docker

```bash
# Démarrer Ollama + Open WebUI
docker compose up -d

# Accéder à l'interface web
# → http://localhost:3000

# Arrêter
docker compose down
```

### Scénario 3 — Déploiement sur une nouvelle machine physique

```bash
# Sur la machine physique cible (Linux)
git clone https://github.com/tonygloaguen/llm-local-architecture.git
cd llm-local-architecture
bash bootstrap.sh
docker compose up -d
```

---

## Vérification d'intégrité

Le script `bootstrap.sh` vérifie automatiquement l'intégrité de chaque modèle après téléchargement.  
Un recheck automatique tourne chaque jour à 07h00 via cron.

```bash
# Lancer un recheck manuel
bash ~/.llm-local/recheck.sh

# Voir le manifest (état de chaque modèle)
cat ~/.llm-local/manifests/manifest.json | python3 -m json.tool

# Voir les logs d'intégrité
ls ~/.llm-local/logs/
```

**Statuts possibles :**

| Statut | Signification |
|---|---|
| `trusted` | Hash local = hash source HuggingFace — vérification totale |
| `unverified` | Hash local OK, mais divergence attendue avec HF (comportement normal Ollama) |
| `quarantine` | Problème d'intégrité détecté — modèle à re-télécharger |

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

Le workflow **Deploy** se lance manuellement depuis GitHub :

```
GitHub → Actions → Deploy → Run workflow
→ Choisir la cible (linux-bare-metal ou windows-wsl2)
→ Taper "DEPLOY" pour confirmer
```

Ce workflow se connecte en SSH à la machine cible et exécute :
```bash
git pull origin main
docker compose pull
docker compose up -d
```

> **Prérequis pour le déploiement distant :** configurer les secrets SSH dans  
> `GitHub → Settings → Secrets and variables → Actions`

---

## Branching strategy

```
main   ← branche stable, déployable, protégée
  └── dev  ← développement quotidien
        └── feature/xxx  ← nouvelles fonctionnalités
        └── fix/xxx      ← corrections
```

**Règle simple :**
- Tu travailles sur `dev`
- Quand c'est stable → Pull Request `dev` → `main`
- Le déploiement physique se fait toujours depuis `main`

```bash
# Workflow quotidien
git checkout dev
# ... modifications ...
git add .
git commit -m "fix: description du changement"
git push origin dev
```

---

## Ajouter une nouvelle machine cible

1. Sur la machine cible, autoriser ta clé SSH :
```bash
# Générer une clé dédiée (sur ta machine dev)
ssh-keygen -t ed25519 -C "deploy@llm-local-architecture" -f ~/.ssh/deploy_llm -N ""

# Copier la clé publique sur la machine cible
ssh-copy-id -i ~/.ssh/deploy_llm.pub user@ip-machine-cible
```

2. Ajouter les secrets dans GitHub :
```
GitHub → tonygloaguen/llm-local-architecture → Settings → Secrets and variables → Actions

DEPLOY_SSH_KEY   ← contenu de ~/.ssh/deploy_llm (clé privée)
DEPLOY_HOST      ← IP de la machine cible
DEPLOY_USER      ← nom d'utilisateur SSH
```

3. Lancer le déploiement :
```
GitHub → Actions → Deploy → Run workflow → linux-bare-metal → DEPLOY
```

---

## Structure des fichiers générés (hors repo)

```
~/.llm-local/
├── manifests/
│   └── manifest.json       ← état de chaque modèle (hash, statut, date)
├── logs/
│   ├── bootstrap_*.log     ← logs d'installation
│   ├── integrity_*.log     ← logs de recheck quotidien
│   └── cron.log            ← logs cron
├── trusted/
│   └── trusted_blobs.log   ← hashes des blobs vérifiés
└── quarantine/
    └── quarantine.log      ← modèles en quarantaine
```

Ces fichiers sont **locaux à chaque machine** et ne sont pas versionnés (`.gitignore`).

---

## Dépannage rapide

| Problème | Commande de diagnostic |
|---|---|
| Ollama ne répond pas | `systemctl status ollama` |
| Modèle en quarantaine | `cat ~/.llm-local/quarantine/quarantine.log` |
| Relancer le bootstrap | `bash bootstrap.sh` (idempotent) |
| Voir les modèles installés | `ollama list` |
| Tester un modèle | `ollama run phi4-mini:3.8b "test"` |
| Open WebUI inaccessible | `docker compose ps` puis `docker compose logs open-webui` |
| Logs bootstrap | `cat ~/.llm-local/logs/bootstrap_*.log \| tail -50` |

---

## Liens utiles

- Repo GitHub : https://github.com/tonygloaguen/llm-local-architecture
- Ollama : https://ollama.ai
- Open WebUI : https://github.com/open-webui/open-webui
- Modèles disponibles : https://ollama.com/library
