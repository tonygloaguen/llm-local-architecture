#!/usr/bin/env pwsh
# =============================================================================
# deploy-windows.ps1 - Deploiement llm-local-architecture sur Windows natif
# Prerequis : PowerShell 5+, GPU NVIDIA, acces internet
# Usage : .\deploy-windows.ps1
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
$REPO_URL   = "https://github.com/tonygloaguen/llm-local-architecture.git"
$REPO_DIR   = Join-Path $env:USERPROFILE "projets\llm-local-architecture"
$LLMHOME    = Join-Path $env:USERPROFILE ".llm-local"
$LOGDIR     = Join-Path $LLMHOME "logs"
$TIMESTAMP  = Get-Date -Format "yyyyMMdd_HHmmss"
$LOGFILE    = Join-Path $LOGDIR "deploy_windows_$TIMESTAMP.log"

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
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if (Test-Path (Split-Path $LOGFILE)) {
        Add-Content -Path $LOGFILE -Value $line -Encoding UTF8
    }
}

function Info  { param([string]$m) Write-Log "INFO " $m }
function Warn  { param([string]$m) Write-Log "WARN " $m }
function Err   { param([string]$m) Write-Log "ERROR" $m }

function Step {
    param([string]$m)
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "  $m"
    Write-Host "======================================================"
    Write-Log "STEP " $m
}

function Test-Cmd {
    param([string]$cmd)
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Invoke-Retry {
    param([scriptblock]$Block, [int]$Max = 3, [int]$Delay = 5)
    $attempt = 1
    while ($true) {
        try {
            & $Block
            return
        } catch {
            if ($attempt -ge $Max) { throw $_ }
            Warn "Tentative $attempt/$Max echouee. Retry dans ${Delay}s..."
            Start-Sleep -Seconds $Delay
            $attempt++
        }
    }
}

# ---------------------------------------------------------------------------
# ETAPE 0 - INIT
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $LLMHOME "manifests") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $LLMHOME "quarantine") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $LLMHOME "trusted") | Out-Null

Step "ETAPE 0 - Initialisation"
Info "Log : $LOGFILE"
Info "Repo cible : $REPO_DIR"

# ---------------------------------------------------------------------------
# ETAPE 1 - VERIFICATION GPU NVIDIA
# ---------------------------------------------------------------------------
Step "ETAPE 1 - Verification GPU NVIDIA"

if (Test-Cmd "nvidia-smi") {
    $gpuInfo = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1
    Info "GPU detecte : $gpuInfo"
} else {
    Warn "nvidia-smi non trouve - Ollama tournera en CPU-only"
    Warn "Installer drivers NVIDIA : https://www.nvidia.com/drivers"
}

# ---------------------------------------------------------------------------
# ETAPE 2 - INSTALLATION OLLAMA
# ---------------------------------------------------------------------------
Step "ETAPE 2 - Verification / Installation Ollama"

if (Test-Cmd "ollama") {
    $ver = & ollama --version 2>&1
    Info "Ollama deja installe : $ver"
} else {
    Info "Telechargement de Ollama pour Windows..."
    $installer = Join-Path $env:TEMP "OllamaSetup.exe"
    Invoke-Retry {
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" `
            -OutFile $installer -UseBasicParsing
    }
    Info "Installation Ollama..."
    Start-Process -FilePath $installer -ArgumentList "/S" -Wait
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if (Test-Cmd "ollama") {
        Info "Ollama installe avec succes"
    } else {
        Err "Ollama non trouve apres installation - redemarrer PowerShell et relancer"
        exit 1
    }
}

# Demarrer le service Ollama si pas actif
$proc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if (-not $proc) {
    Info "Demarrage du service Ollama..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Info "Service Ollama demarre"
} else {
    Info "Service Ollama deja actif (PID $($proc.Id))"
}

# ---------------------------------------------------------------------------
# ETAPE 3 - DOCKER DESKTOP
# ---------------------------------------------------------------------------
Step "ETAPE 3 - Verification Docker Desktop"

if (Test-Cmd "docker") {
    $dv = & docker --version 2>&1
    Info "Docker installe : $dv"
} else {
    Warn "Docker Desktop non trouve"
    Warn "Pour Open WebUI : https://www.docker.com/products/docker-desktop/"
    Warn "Le deploiement continue sans Docker (Ollama seul)"
}

# ---------------------------------------------------------------------------
# ETAPE 4 - REPO
# ---------------------------------------------------------------------------
Step "ETAPE 4 - Repo llm-local-architecture"

if (-not (Test-Cmd "git")) {
    Err "git non trouve. Installer : https://git-scm.com"
    exit 1
}

if (Test-Path (Join-Path $REPO_DIR ".git")) {
    Info "Repo deja clone - mise a jour"
    Set-Location $REPO_DIR
    Invoke-Retry { & git pull origin main 2>&1 | ForEach-Object { Info $_ } }
} else {
    Info "Clonage du repo..."
    $parentDir = Split-Path $REPO_DIR
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    Invoke-Retry {
        & git clone $REPO_URL $REPO_DIR 2>&1 | ForEach-Object { Info $_ }
    }
    Set-Location $REPO_DIR
}

Info "Repo a jour : $REPO_DIR"

# ---------------------------------------------------------------------------
# ETAPE 5 - TELECHARGEMENT DES MODELES
# ---------------------------------------------------------------------------
Step "ETAPE 5 - Telechargement des modeles"

$countOK   = 0
$countFail = 0

foreach ($model in $MODELS) {
    Info "Pull : $model"
    try {
        Invoke-Retry {
            & ollama pull $model 2>&1 | ForEach-Object { Write-Host "  $_" }
        }
        Info "  -> Pull reussi : $model"
        $countOK++
    } catch {
        Err "  -> Echec pull : $model"
        $countFail++
    }
}

Info "Modeles : $countOK OK, $countFail echecs"

# ---------------------------------------------------------------------------
# ETAPE 6 - INTEGRITE SHA-256
# ---------------------------------------------------------------------------
Step "ETAPE 6 - Verification integrite des blobs"

$ollamaModelsDir = Join-Path $env:USERPROFILE ".ollama\models"
if (-not (Test-Path $ollamaModelsDir)) {
    $ollamaModelsDir = Join-Path $env:LOCALAPPDATA "Ollama\models"
}
if (-not (Test-Path $ollamaModelsDir)) {
    Warn "Repertoire Ollama introuvable - verification integrite ignoree"
} else {
    Info "Repertoire Ollama : $ollamaModelsDir"
}

$manifestsDir = Join-Path $ollamaModelsDir "manifests\registry.ollama.ai\library"
$blobsDir     = Join-Path $ollamaModelsDir "blobs"

$manifestData = [ordered]@{
    generated_at      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    host              = $env:COMPUTERNAME
    schema_version    = "1.2"
    ollama_models_dir = $ollamaModelsDir
    models            = @()
}

foreach ($model in $MODELS) {
    $modelName = $model.Split(":")[0]
    $modelTag  = if ($model.Contains(":")) { $model.Split(":")[1] } else { "latest" }
    $mPath     = Join-Path $manifestsDir "$modelName\$modelTag"

    Info "Verification : $model"

    if (-not (Test-Path $mPath)) {
        Warn "  Manifest introuvable : $mPath"
        $manifestData.models += [ordered]@{ name = $model; status = "quarantine"; note = "manifest introuvable" }
        continue
    }

    $manifest = Get-Content $mPath -Raw | ConvertFrom-Json
    $blobsOK  = $true

    foreach ($layer in $manifest.layers) {
        $digest   = $layer.digest
        $hash     = $digest -replace "^sha256:", ""
        $blobPath = Join-Path $blobsDir "sha256-$hash"

        if (-not (Test-Path $blobPath)) {
            Warn "  Blob introuvable : sha256-$($hash.Substring(0,12))..."
            $blobsOK = $false
            continue
        }

        $computed = (Get-FileHash -Algorithm SHA256 -Path $blobPath).Hash.ToLower()
        if ($computed -eq $hash) {
            Info "  Blob OK : $($hash.Substring(0,12))..."
        } else {
            Warn "  DRIFT : attendu=$($hash.Substring(0,12)) calcule=$($computed.Substring(0,12))"
            $blobsOK = $false
        }
    }

    $status = if ($blobsOK) { "unverified" } else { "quarantine" }
    Info "  STATUS : $status"
    $manifestData.models += [ordered]@{
        name              = $model
        ollama_models_dir = $ollamaModelsDir
        status            = $status
        last_checked      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }
}

$manifestFile = Join-Path $LLMHOME "manifests\manifest.json"
$manifestData | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile -Encoding UTF8
Info "Manifest ecrit : $manifestFile"

# ---------------------------------------------------------------------------
# ETAPE 7 - DOCKER COMPOSE
# ---------------------------------------------------------------------------
Step "ETAPE 7 - Docker Compose (Open WebUI)"

if (Test-Cmd "docker") {
    Set-Location $REPO_DIR
    try {
        & docker compose up -d 2>&1 | ForEach-Object { Info $_ }
        Info "Open WebUI accessible sur http://localhost:3000"
    } catch {
        Warn "docker compose up echoue : $_"
        Warn "Verifier que Docker Desktop est lance"
    }
} else {
    Warn "Docker non disponible - Open WebUI non lance"
    Info "Ollama accessible sur http://localhost:11434"
}

# ---------------------------------------------------------------------------
# RAPPORT FINAL
# ---------------------------------------------------------------------------
Step "RAPPORT FINAL"

Write-Host ""
Write-Host "======================================================"
Write-Host "  DEPLOIEMENT WINDOWS - RAPPORT FINAL"
Write-Host "======================================================"
Write-Host ""
Write-Host "  Machine         : $env:COMPUTERNAME"
Write-Host "  Repo            : $REPO_DIR"
Write-Host "  Ollama models   : $ollamaModelsDir"
Write-Host "  Manifest        : $manifestFile"
Write-Host "  Log             : $LOGFILE"
Write-Host ""
Write-Host "  MODELES INSTALLES :"
foreach ($model in $MODELS) {
    Write-Host "    -> $model"
}
Write-Host ""
Write-Host "  ACCES :"
Write-Host "    Ollama API : http://localhost:11434"
if (Test-Cmd "docker") {
    Write-Host "    Open WebUI : http://localhost:3000"
}
Write-Host ""
Write-Host "  TEST RAPIDE :"
Write-Host "    ollama run phi4-mini:3.8b `"Dis bonjour en une phrase`""
Write-Host ""

Info "Deploiement Windows termine"
