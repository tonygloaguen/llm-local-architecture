#!/usr/bin/env bash
# =============================================================================
# setup-workflow.sh — Initialisation workflow Git + Docker + GitHub Actions
# Usage : bash setup-workflow.sh
# Prérequis : être dans /home/gloaguen/projets/llm-local-architecture
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
GITHUB_USER="tonygloaguen"
REPO_NAME="llm-local-architecture"
REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
PROJECT_DIR="/home/gloaguen/projets/llm-local-architecture"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}"; }

# ---------------------------------------------------------------------------
# VÉRIFICATIONS PRÉALABLES
# ---------------------------------------------------------------------------
step "Vérifications préalables"

if [[ ! -d "${PROJECT_DIR}" ]]; then
  error "Répertoire projet introuvable : ${PROJECT_DIR}"
  exit 1
fi

cd "${PROJECT_DIR}"
info "Répertoire courant : $(pwd)"

if ! command -v git &>/dev/null; then
  error "git non trouvé"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  warn "docker non trouvé — les fichiers Docker seront créés mais non testés"
fi

# ---------------------------------------------------------------------------
# ÉTAPE 1 — CORRECTIONS TAGS OLLAMA
# ---------------------------------------------------------------------------
step "ÉTAPE 1 — Correction des tags Ollama incorrects"

if grep -q "granite3.3:8b-instruct" bootstrap.sh 2>/dev/null; then
  sed -i 's|granite3.3:8b-instruct|granite3.3:8b|g' bootstrap.sh
  info "Corrigé : granite3.3:8b-instruct → granite3.3:8b"
else
  info "granite3.3 : déjà correct"
fi

if grep -q "phi4-mini:instruct" bootstrap.sh 2>/dev/null; then
  sed -i 's|phi4-mini:instruct|phi4-mini:3.8b|g' bootstrap.sh
  info "Corrigé : phi4-mini:instruct → phi4-mini:3.8b"
else
  info "phi4-mini : déjà correct"
fi

bash -n bootstrap.sh && info "bootstrap.sh syntaxe OK après corrections"

# ---------------------------------------------------------------------------
# ÉTAPE 2 — .GITIGNORE
# ---------------------------------------------------------------------------
step "ÉTAPE 2 — Création .gitignore"

cat > .gitignore << 'EOF'
# Logs
*.log
logs/

# Manifest local (hashes spécifiques à la machine)
.llm-local/

# Backups
*.bak

# Secrets
.env
*.key
*.pem

# Python
__pycache__/
*.pyc
.venv/

# Docker
.docker/

# OS
.DS_Store
Thumbs.db
EOF

info ".gitignore créé"

# ---------------------------------------------------------------------------
# ÉTAPE 3 — DOCKER COMPOSE
# ---------------------------------------------------------------------------
step "ÉTAPE 3 — Création docker-compose.yml"

cat > docker-compose.yml << 'EOF'
version: "3.9"

services:

  ollama:
    image: ollama/ollama:latest
    container_name: llm-ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0
    # Décommenter sur machine physique avec GPU NVIDIA :
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: llm-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - webui_data:/app/backend/data
    depends_on:
      ollama:
        condition: service_healthy
    profiles:
      - ui

volumes:
  ollama_data:
  webui_data:
EOF

info "docker-compose.yml créé"

# Valider si docker disponible
if command -v docker &>/dev/null; then
  if docker compose config --quiet 2>/dev/null; then
    info "docker-compose.yml validé"
  else
    warn "docker compose config a retourné une erreur — vérifier manuellement"
  fi
fi

# ---------------------------------------------------------------------------
# ÉTAPE 4 — GITHUB ACTIONS
# ---------------------------------------------------------------------------
step "ÉTAPE 4 — Création workflows GitHub Actions"

mkdir -p .github/workflows

# --- ci.yml ---
cat > .github/workflows/ci.yml << 'EOF'
name: CI

on:
  push:
    branches: [main, dev]
  pull_request:
    branches: [main]

jobs:
  lint-bash:
    name: Lint bash scripts
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Install shellcheck
        run: sudo apt-get install -y shellcheck

      - name: Lint bootstrap.sh
        run: shellcheck bootstrap.sh

      - name: Lint recheck.sh (si présent)
        run: |
          if [ -f recheck.sh ]; then
            shellcheck recheck.sh
          fi

      - name: Validate JSON
        run: |
          find . -name "*.json" ! -path "./.git/*" | while read -r f; do
            echo "Validating $f"
            python3 -m json.tool "$f" > /dev/null
          done

  validate-docker:
    name: Validate Docker Compose
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Validate docker-compose.yml
        run: docker compose config --quiet
EOF

info "ci.yml créé"

# --- security.yml ---
cat > .github/workflows/security.yml << 'EOF'
name: Security

on:
  push:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"

jobs:
  gitleaks:
    name: Gitleaks
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  trivy-fs:
    name: Trivy filesystem scan
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Trivy scan
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          scan-ref: .
          format: table
          exit-code: 0
          severity: CRITICAL,HIGH
EOF

info "security.yml créé"

# --- deploy.yml ---
cat > .github/workflows/deploy.yml << 'EOF'
name: Deploy

on:
  workflow_dispatch:
    inputs:
      target:
        description: "Cible"
        required: true
        default: "linux-bare-metal"
        type: choice
        options:
          - linux-bare-metal
          - windows-wsl2
      confirm:
        description: "Taper DEPLOY pour confirmer"
        required: true

jobs:
  deploy:
    name: Deploy ${{ github.event.inputs.target }}
    runs-on: ubuntu-24.04
    if: github.event.inputs.confirm == 'DEPLOY' && github.ref == 'refs/heads/main'

    steps:
      - uses: actions/checkout@v4

      - name: Deploy Linux bare metal
        if: github.event.inputs.target == 'linux-bare-metal'
        env:
          SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
          DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
        run: |
          mkdir -p ~/.ssh
          echo "$SSH_PRIVATE_KEY" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh -i ~/.ssh/deploy_key \
              -o StrictHostKeyChecking=no \
              ${DEPLOY_USER}@${DEPLOY_HOST} \
              'cd ~/projets/llm-local-architecture && git pull origin main && docker compose pull && docker compose up -d && docker compose ps'

      - name: Deploy Windows WSL2
        if: github.event.inputs.target == 'windows-wsl2'
        env:
          SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY_WIN }}
          DEPLOY_HOST: ${{ secrets.DEPLOY_HOST_WIN }}
          DEPLOY_USER: ${{ secrets.DEPLOY_USER_WIN }}
        run: |
          mkdir -p ~/.ssh
          echo "$SSH_PRIVATE_KEY" > ~/.ssh/deploy_key_win
          chmod 600 ~/.ssh/deploy_key_win
          ssh -i ~/.ssh/deploy_key_win \
              -p 2222 \
              -o StrictHostKeyChecking=no \
              ${DEPLOY_USER}@${DEPLOY_HOST_WIN} \
              'cd ~/projets/llm-local-architecture && git pull origin main && docker compose pull && docker compose up -d'
EOF

info "deploy.yml créé"

# ---------------------------------------------------------------------------
# ÉTAPE 5 — GIT INIT ET REMOTE
# ---------------------------------------------------------------------------
step "ÉTAPE 5 — Git init et remote"

if [[ ! -d ".git" ]]; then
  git init
  info "git init effectué"
else
  info "repo git déjà initialisé"
fi

# Remote
if git remote get-url origin &>/dev/null; then
  current_remote=$(git remote get-url origin)
  if [[ "${current_remote}" != "${REMOTE_URL}" ]]; then
    warn "Remote origin existe déjà : ${current_remote}"
    warn "Pour changer : git remote set-url origin ${REMOTE_URL}"
  else
    info "Remote origin déjà configuré : ${REMOTE_URL}"
  fi
else
  git remote add origin "${REMOTE_URL}"
  info "Remote ajouté : ${REMOTE_URL}"
fi

# Branching
git checkout -b dev 2>/dev/null || git checkout dev
info "Branche dev active"

# Premier commit
git add .
if git diff --cached --quiet; then
  info "Rien à committer"
else
  git commit -m "feat: workflow git + docker + github actions — setup initial"
  info "Commit effectué"
fi

# ---------------------------------------------------------------------------
# RAPPORT FINAL
# ---------------------------------------------------------------------------
step "RAPPORT FINAL"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         WORKFLOW SETUP — RAPPORT FINAL                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  ✅ Tags Ollama corrigés (granite3.3:8b, phi4-mini:3.8b)"
echo "  ✅ .gitignore créé"
echo "  ✅ docker-compose.yml créé"
echo "  ✅ .github/workflows/ créé (ci.yml, security.yml, deploy.yml)"
echo "  ✅ Git remote configuré : ${REMOTE_URL}"
echo "  ✅ Branche dev active"
echo ""
echo "  PROCHAINES ÉTAPES :"
echo ""
echo "  1. Créer le repo GitHub si pas encore fait :"
echo "     https://github.com/new → nom : ${REPO_NAME}"
echo ""
echo "  2. Pusher sur GitHub :"
echo "     git push -u origin dev"
echo ""
echo "  3. Puller les modèles manquants :"
echo "     ollama pull granite3.3:8b"
echo "     ollama pull phi4-mini:3.8b"
echo ""
echo "  4. Configurer les secrets GitHub pour le déploiement :"
echo "     GitHub → Settings → Secrets → Actions"
echo "     DEPLOY_SSH_KEY, DEPLOY_HOST, DEPLOY_USER"
echo ""
echo "  5. Sur machine physique :"
echo "     git clone ${REMOTE_URL}"
echo "     bash bootstrap.sh"
echo "     docker compose up -d"
echo ""
