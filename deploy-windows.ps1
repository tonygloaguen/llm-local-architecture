# =============================================================================
# deploy-windows.ps1 — Déploiement llm-local-architecture sur Windows natif
# Prérequis : PowerShell 7+, GPU NVIDIA, accès internet
# Usage : .\deploy-windows.ps1
# Idempotent : ré-exécutable sans effets de bord
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
$REPO_URL    = "https://github.com/tonygloaguen/llm-local-architecture.git"
$REPO_DIR    = "$env:USERPROFILE\projets\llm-local-architecture"
$LLMHOME     = "$env:USERPROFILE\.llm-local"
$LOGDIR      = "$LLMHOME\logs"
$TIMESTAMP   = Get-Date -Format "yyyyMMdd_HHmmss"
$LOGFILE     = "$LOGDIR\deploy_windows_$TIMESTAMP.log"

# Modèles à télécharger (mêmes que bootstrap.sh)
$MODELS = @(
    "qwen2.5-coder:7b-instruct-q4_K_M",
    "granite3.3:8b",
    "deepseek-r1:7b",
    "phi4-mini:3.8b",
    "mistral:7b-instruct-v0.3-q4_K_M"
)

# ---------------------------------------------------------------------------
# FONCTIONS
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LOGFILE -Value $line
}

function Info  { param([string]$m) Write-Log "INFO " $m }
function Warn  { param([string]$m) Write-Log "WARN " $m }
function Error { param([string]$m) Write-Log "ERROR" $m }

function Step {
    param([string]$m)
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════"
    Write-Host "  $m"
    Write-Host "══════════════════════════════════════════════════════"
    Write-Log "STEP " $m
}

function Test-Command {
    param([string]$cmd)
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3, [int]$DelaySeconds = 5)
    $attempt = 1
    while ($true) {
        try {
            & $ScriptBlock
            return
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw "Échec après $MaxAttempts tentatives : $_"
            }
            Warn "Tentative $attempt/$MaxAttempts échouée. Retry dans ${DelaySeconds}s..."
            Start-Sleep -Seconds $DelaySeconds
            $attempt++
        }
    }
}

# ---------------------------------------------------------------------------
# ÉTAPE 0 — INIT RÉPERTOIRES ET LOG
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null
New-Item -ItemType Directory -Force -Path "$LLMHOME\manifests" | Out-Null
New-Item -ItemType Directory -Force -Path "$LLMHOME\quarantine" | Out-Null
New-Item -ItemType Directory -Force -Path "$LLMHOME\trusted" | Out-Null

Step "ÉTAPE 0 — Initialisation"
Info "Log : $LOGFILE"
Info "Repo cible : $REPO_DIR"

# ---------------------------------------------------------------------------
# ÉTAPE 1 — VÉRIFICATION GPU NVIDIA
# ---------------------------------------------------------------------------
Step "ÉTAPE 1 — Vérification GPU NVIDIA"

try {
    $gpuInfo = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1
    Info "GPU détecté : $gpuInfo"
} catch {
    Warn "nvidia-smi non trouvé ou GPU non détecté"
    Warn "Ollama tournera en CPU-only"
    Warn "Installer les drivers NVIDIA : https://www.nvidia.com/drivers"
}

# ---------------------------------------------------------------------------
# ÉTAPE 2 — INSTALLATION OLLAMA
# ---------------------------------------------------------------------------
Step "ÉTAPE 2 — Vérification / Installation Ollama"

if (Test-Command "ollama") {
    $ollamaVersion = & ollama --version 2>&1
    Info "Ollama déjà installé : $ollamaVersion"
} else {
    Info "Téléchargement de Ollama pour Windows..."
    $ollamaInstaller = "$env:TEMP\OllamaSetup.exe"
    Invoke-WithRetry {
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" `
            -OutFile $ollamaInstaller -UseBasicParsing
    }
    Info "Installation Ollama..."
    Start-Process -FilePath $ollamaInstaller -ArgumentList "/S" -Wait
    # Recharger le PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if (Test-Command "ollama") {
        Info "Ollama installé avec succès"
    } else {
        Error "Ollama non trouvé après installation — redémarre PowerShell et relance"
        exit 1
    }
}

# Démarrer le service Ollama si pas actif
$ollamaProcess = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if (-not $ollamaProcess) {
    Info "Démarrage du service Ollama..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Info "Service Ollama démarré"
} else {
    Info "Service Ollama déjà actif"
}

# ---------------------------------------------------------------------------
# ÉTAPE 3 — INSTALLATION DOCKER DESKTOP (optionnel)
# ---------------------------------------------------------------------------
Step "ÉTAPE 3 — Vérification Docker Desktop"

if (Test-Command "docker") {
    $dockerVersion = & docker --version 2>&1
    Info "Docker déjà installé : $dockerVersion"
} else {
    Warn "Docker Desktop non trouvé"
    Warn "Pour l'interface Open WebUI, installer Docker Desktop :"
    Warn "https://www.docker.com/products/docker-desktop/"
    Warn "Le déploiement continue sans Docker (Ollama seul)"
}

# ---------------------------------------------------------------------------
# ÉTAPE 4 — CLONAGE / MISE À JOUR DU REPO
# ---------------------------------------------------------------------------
Step "ÉTAPE 4 — Repo llm-local-architecture"

if (-not (Test-Command "git")) {
    Error "git non trouvé. Installer depuis https://git-scm.com"
    exit 1
}

if (Test-Path "$REPO_DIR\.git") {
    Info "Repo déjà cloné — mise à jour"
    Set-Location $REPO_DIR
    Invoke-WithRetry { & git pull origin main 2>&1 | ForEach-Object { Info $_ } }
} else {
    Info "Clonage du repo..."
    New-Item -ItemType Directory -Force -Path (Split-Path $REPO_DIR) | Out-Null
    Invoke-WithRetry {
        & git clone $REPO_URL $REPO_DIR 2>&1 | ForEach-Object { Info $_ }
    }
    Set-Location $REPO_DIR
}

Info "Repo à jour dans : $REPO_DIR"

# ---------------------------------------------------------------------------
# ÉTAPE 5 — TÉLÉCHARGEMENT DES MODÈLES
# ---------------------------------------------------------------------------
Step "ÉTAPE 5 — Téléchargement des modèles"

$countOK = 0
$countFail = 0

foreach ($model in $MODELS) {
    # Vérifier si déjà présent
    $ollamaList = & ollama list 2>&1
    if ($ollamaList -match [regex]::Escape($model.Split(":")[0])) {
        Info "Déjà présent : $model"
    } else {
        Info "Pull : $model"
    }

    try {
        Invoke-WithRetry {
            & ollama pull $model 2>&1 | ForEach-Object { Write-Host "  $_" }
        }
        Info "  → Pull réussi : $model"
        $countOK++
    } catch {
        Error "  → Échec pull : $model — $_"
        $countFail++
    }
}

Info "Modèles téléchargés : $countOK OK, $countFail échecs"

# ---------------------------------------------------------------------------
# ÉTAPE 6 — VÉRIFICATION D'INTÉGRITÉ (Windows)
# ---------------------------------------------------------------------------
Step "ÉTAPE 6 — Vérification d'intégrité des blobs"

# Sous Windows, Ollama stocke dans %USERPROFILE%\.ollama\models
$ollamaModelsDir = "$env:USERPROFILE\.ollama\models"

if (-not (Test-Path $ollamaModelsDir)) {
    # Parfois dans AppData
    $ollamaModelsDir = "$env:LOCALAPPDATA\Ollama\models"
}

Info "Répertoire Ollama : $ollamaModelsDir"

$manifestsDir = "$ollamaModelsDir\manifests\registry.ollama.ai\library"
$blobsDir = "$ollamaModelsDir\blobs"

$manifestJson = @{
    generated_at     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    host             = $env:COMPUTERNAME
    schema_version   = "1.2"
    ollama_models_dir = $ollamaModelsDir
    models           = @()
}

foreach ($model in $MODELS) {
    $modelName = $model.Split(":")[0]
    $modelTag  = if ($model.Contains(":")) { $model.Split(":")[1] } else { "latest" }

    $manifestPath = "$manifestsDir\$modelName\$modelTag"
    Info "Vérification : $model"

    if (-not (Test-Path $manifestPath)) {
        Warn "  Manifest introuvable : $manifestPath"
        $manifestJson.models += @{
            name   = $model
            status = "quarantine"
            note   = "manifest introuvable"
        }
        continue
    }

    $manifest = Get-Content $manifestPath | ConvertFrom-Json
    $blobsOK = $true

    foreach ($layer in $manifest.layers) {
        $digest   = $layer.digest
        $hash     = $digest -replace "^sha256:", ""
        $blobPath = "$blobsDir\sha256-$hash"

        if (-not (Test-Path $blobPath)) {
            Warn "  Blob introuvable : $blobPath"
            $blobsOK = $false
            continue
        }

        # Calcul SHA-256 PowerShell natif
        $computed = (Get-FileHash -Algorithm SHA256 -Path $blobPath).Hash.ToLower()

        if ($computed -eq $hash) {
            Info "  Blob OK : $($hash.Substring(0,12))..."
        } else {
            Warn "  DRIFT : attendu=$($hash.Substring(0,12)) calculé=$($computed.Substring(0,12))"
            $blobsOK = $false
        }
    }

    $status = if ($blobsOK) { "unverified" } else { "quarantine" }
    Info "  STATUS : $status"

    $manifestJson.models += @{
        name             = $model
        ollama_models_dir = $ollamaModelsDir
        status           = $status
        last_checked     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }
}

# Écrire le manifest
$manifestFile = "$LLMHOME\manifests\manifest.json"
$manifestJson | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile -Encoding UTF8
Info "Manifest écrit : $manifestFile"

# ---------------------------------------------------------------------------
# ÉTAPE 7 — LANCEMENT DOCKER COMPOSE (si Docker disponible)
# ---------------------------------------------------------------------------
Step "ÉTAPE 7 — Docker Compose (Open WebUI)"

if (Test-Command "docker") {
    Set-Location $REPO_DIR
    try {
        & docker compose up -d 2>&1 | ForEach-Object { Info $_ }
        Info "Open WebUI accessible sur http://localhost:3000"
    } catch {
        Warn "docker compose up échoué : $_"
        Warn "Vérifier que Docker Desktop est lancé"
    }
} else {
    Warn "Docker non disponible — Open WebUI non lancé"
    Warn "Ollama seul accessible sur http://localhost:11434"
}

# ---------------------------------------------------------------------------
# RAPPORT FINAL
# ---------------------------------------------------------------------------
Step "RAPPORT FINAL"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗"
Write-Host "║      DÉPLOIEMENT WINDOWS — RAPPORT FINAL                ║"
Write-Host "╚══════════════════════════════════════════════════════════╝"
Write-Host ""
Write-Host "  Machine         : $env:COMPUTERNAME"
Write-Host "  Repo            : $REPO_DIR"
Write-Host "  Ollama models   : $ollamaModelsDir"
Write-Host "  Manifest        : $manifestFile"
Write-Host "  Log             : $LOGFILE"
Write-Host ""
Write-Host "  MODÈLES INSTALLÉS :"
foreach ($model in $MODELS) {
    Write-Host "    → $model"
}
Write-Host ""
Write-Host "  ACCÈS :"
Write-Host "    Ollama API   : http://localhost:11434"
if (Test-Command "docker") {
    Write-Host "    Open WebUI   : http://localhost:3000"
}
Write-Host ""
Write-Host "  TEST RAPIDE :"
Write-Host "    ollama run phi4-mini:3.8b `"Dis bonjour en une phrase`""
Write-Host ""

Info "Déploiement Windows terminé"
