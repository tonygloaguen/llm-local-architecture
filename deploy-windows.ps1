#!/usr/bin/env pwsh
# =============================================================================
# deploy-windows.ps1 - Deploiement llm-local-architecture sur Windows natif
# Prerequis : PowerShell 5+, acces internet, Ollama, Docker Desktop optionnel
# Usage :
#   .\deploy-windows.ps1
#   .\deploy-windows.ps1 -ApproveCandidates
#   .\deploy-windows.ps1 -ForceUpdate
# =============================================================================

param(
    [switch]$ForceUpdate,
    [switch]$ApproveCandidates
)

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

$MANIFESTS_DIR       = Join-Path $LLMHOME "manifests"
$REGISTRY_DIR        = Join-Path $LLMHOME "registry"
$QUARANTINE_DIR      = Join-Path $LLMHOME "quarantine"
$TRUSTED_DIR         = Join-Path $LLMHOME "trusted"
$CURRENT_MANIFEST    = Join-Path $MANIFESTS_DIR "current_manifest.json"
$APPROVED_REGISTRY   = Join-Path $REGISTRY_DIR "approved_models.json"

$MODELS = @(
    "qwen2.5-coder:7b-instruct",
    "granite3.3:8b",
    "deepseek-r1:7b",
    "phi4-mini",
    "mistral:7b-instruct-v0.3-q4_K_M"
)

# ---------------------------------------------------------------------------
# FONCTIONS LOG
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
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

# ---------------------------------------------------------------------------
# FONCTIONS GENERALES
# ---------------------------------------------------------------------------
function Test-Cmd {
    param([string]$cmd)
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Invoke-Retry {
    param(
        [scriptblock]$Block,
        [int]$Max = 3,
        [int]$Delay = 5
    )

    $attempt = 1
    while ($true) {
        try {
            & $Block
            return
        } catch {
            if ($attempt -ge $Max) { throw }
            Warn "Tentative $attempt/$Max echouee. Retry dans ${Delay}s..."
            Start-Sleep -Seconds $Delay
            $attempt++
        }
    }
}

function Ensure-Directory {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Get-Sha256String {
    param([string]$InputString)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes)).Replace("-", "").ToLower()
    } finally {
        $sha.Dispose()
    }
}

# ---------------------------------------------------------------------------
# REGISTRE APPROUVE
# ---------------------------------------------------------------------------
function Load-ApprovedRegistry {
    if (Test-Path $APPROVED_REGISTRY) {
        return (Get-Content $APPROVED_REGISTRY -Raw | ConvertFrom-Json)
    }

    return [pscustomobject]@{
        schema_version = "1.0"
        approved_at    = $null
        models         = @()
    }
}

function Save-ApprovedRegistry {
    param([object]$Registry)
    Ensure-Directory -Path $REGISTRY_DIR
    $Registry | ConvertTo-Json -Depth 30 | Set-Content -Path $APPROVED_REGISTRY -Encoding UTF8
}

function Get-ApprovedModelEntry {
    param(
        [object]$Registry,
        [string]$ModelName
    )

    $matches = @($Registry.models | Where-Object { $_.name -eq $ModelName })
    if ($matches.Count -gt 0) {
        return $matches[0]
    }
    return $null
}

# ---------------------------------------------------------------------------
# OLLAMA
# ---------------------------------------------------------------------------
function Get-OllamaModelsDir {
    $path1 = Join-Path $env:USERPROFILE ".ollama\models"
    if (Test-Path $path1) { return $path1 }

    $path2 = Join-Path $env:LOCALAPPDATA "Ollama\models"
    if (Test-Path $path2) { return $path2 }

    return $path1
}

function Test-OllamaApi {
    param([string]$OllamaHost)

    for ($i = 1; $i -le 5; $i++) {
        try {
            $null = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 5
            Info "API Ollama OK (tentative $i)"
            return $true
        } catch {
            Warn "API Ollama non disponible (tentative $i/5) - attente 3s..."
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

function Get-InstalledModels {
    $result = @()
    try {
        $lines = & ollama list
        foreach ($line in $lines) {
            if (-not $line) { continue }
            if ($line -match "^\s*NAME\s+") { continue }

            $parts = ($line -split "\s+") | Where-Object { $_ -ne "" }
            if ($parts.Count -ge 1) {
                $result += $parts[0]
            }
        }
    } catch {
        Warn "Impossible de lire la liste des modeles Ollama"
    }
    return $result
}

function Get-ModelFingerprint {
    param(
        [string]$Model,
        [string]$OllamaModelsDir
    )

    $manifestsDir = Join-Path $OllamaModelsDir "manifests\registry.ollama.ai\library"
    $blobsDir     = Join-Path $OllamaModelsDir "blobs"

    $modelName = $Model.Split(":")[0]
    $modelTag  = if ($Model.Contains(":")) { $Model.Split(":")[1] } else { "latest" }
    $manifestPath = Join-Path $manifestsDir "$modelName\$modelTag"

    if (-not (Test-Path $manifestPath)) {
        return [pscustomobject]@{
            name          = $Model
            manifest_path = $manifestPath
            manifest_sha  = $null
            layers        = @()
            blob_count    = 0
            status        = "missing"
            note          = "manifest introuvable"
            checked_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    $manifestRaw = Get-Content $manifestPath -Raw
    $manifest    = $manifestRaw | ConvertFrom-Json
    $manifestShaHex = Get-Sha256String -InputString $manifestRaw

    $layers = @()
    $allOk  = $true

    foreach ($layer in $manifest.layers) {
        $digest   = $layer.digest
        $hash     = $digest -replace "^sha256:", ""
        $blobPath = Join-Path $blobsDir "sha256-$hash"

        if (-not (Test-Path $blobPath)) {
            $allOk = $false
            $layers += [pscustomobject]@{
                digest   = $digest
                path     = $blobPath
                exists   = $false
                computed = $null
                size     = $null
            }
            continue
        }

        $computed = (Get-FileHash -Algorithm SHA256 -Path $blobPath).Hash.ToLower()
        $size = (Get-Item $blobPath).Length

        if ($computed -ne $hash) {
            $allOk = $false
        }

        $layers += [pscustomobject]@{
            digest   = $digest
            path     = $blobPath
            exists   = $true
            computed = $computed
            size     = $size
        }
    }

    return [pscustomobject]@{
        name          = $Model
        manifest_path = $manifestPath
        manifest_sha  = $manifestShaHex
        layers        = $layers
        blob_count    = $layers.Count
        status        = if ($allOk) { "intact" } else { "corrupt" }
        note          = $null
        checked_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
}

function Compare-ModelWithApproved {
    param(
        [object]$CurrentFingerprint,
        [object]$ApprovedEntry
    )

    if ($CurrentFingerprint.status -eq "missing") {
        return "missing"
    }

    if ($CurrentFingerprint.status -ne "intact") {
        return "quarantine"
    }

    if (-not $ApprovedEntry) {
        return "candidate"
    }

    if ($ApprovedEntry.manifest_sha -ne $CurrentFingerprint.manifest_sha) {
        return "drifted"
    }

    $approvedDigests = @($ApprovedEntry.layers | ForEach-Object { $_.digest }) | Sort-Object
    $currentDigests  = @($CurrentFingerprint.layers | ForEach-Object { $_.digest }) | Sort-Object

    $sameCount = ($approvedDigests.Count -eq $currentDigests.Count)
    $sameList  = (($approvedDigests -join "|") -eq ($currentDigests -join "|"))

    if ($sameCount -and $sameList) {
        return "trusted"
    }

    return "drifted"
}

function Approve-CandidateModels {
    param(
        [object]$CurrentManifest,
        [object]$Registry
    )

    foreach ($model in $CurrentManifest.models) {
        if ($model.status -in @("candidate", "trusted")) {
            $existing = Get-ApprovedModelEntry -Registry $Registry -ModelName $model.name

            if ($existing) {
                $Registry.models = @($Registry.models | Where-Object { $_.name -ne $model.name })
            }

            $Registry.models += [pscustomobject]@{
                name         = $model.name
                approved_at  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                manifest_sha = $model.manifest_sha
                layers       = @(
                    $model.layers | ForEach-Object {
                        [pscustomobject]@{
                            digest = $_.digest
                            size   = $_.size
                        }
                    }
                )
            }

            Info "Modele approuve : $($model.name)"
        } else {
            Warn "Modele non approuvable automatiquement : $($model.name) [$($model.status)]"
        }
    }

    $Registry.approved_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    return $Registry
}

# ---------------------------------------------------------------------------
# PREPARATION DOSSIERS
# ---------------------------------------------------------------------------
Ensure-Directory -Path $LOGDIR
Ensure-Directory -Path $MANIFESTS_DIR
Ensure-Directory -Path $REGISTRY_DIR
Ensure-Directory -Path $QUARANTINE_DIR
Ensure-Directory -Path $TRUSTED_DIR

# ---------------------------------------------------------------------------
# ETAPE 0 - INIT
# ---------------------------------------------------------------------------
Step "ETAPE 0 - Initialisation"
Info "Log : $LOGFILE"
Info "Repo cible : $REPO_DIR"
Info "ForceUpdate : $ForceUpdate"
Info "ApproveCandidates : $ApproveCandidates"

# ---------------------------------------------------------------------------
# ETAPE 1 - VERIFICATION GPU NVIDIA
# ---------------------------------------------------------------------------
Step "ETAPE 1 - Verification GPU NVIDIA"

$nvidiaSmiPath = $null

if (Test-Path "C:\Windows\System32\nvidia-smi.exe") {
    $nvidiaSmiPath = "C:\Windows\System32\nvidia-smi.exe"
} elseif (Test-Path "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
    $nvidiaSmiPath = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
} elseif (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
    $nvidiaSmiPath = (Get-Command "nvidia-smi").Source
}

if ($nvidiaSmiPath) {
    $gpuInfo = & $nvidiaSmiPath --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1
    Info "GPU NVIDIA detecte : $gpuInfo"
} else {
    Warn "nvidia-smi introuvable - verification GPU NVIDIA incomplète"
    Warn "Le GPU NVIDIA peut etre present physiquement, mais non verifiable via l'outil CLI"
}

# ---------------------------------------------------------------------------
# ETAPE 2 - VERIFICATION / INSTALLATION OLLAMA
# ---------------------------------------------------------------------------
Step "ETAPE 2 - Verification / Installation Ollama"

if (Test-Cmd "ollama") {
    $ver = & ollama --version 2>&1
    Info "Ollama deja installe : $ver"
} else {
    Info "Telechargement de Ollama pour Windows..."
    $installer = Join-Path $env:TEMP "OllamaSetup.exe"

    Invoke-Retry {
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installer -UseBasicParsing
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

# Service Ollama
$proc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if (-not $proc) {
    Info "Demarrage du service Ollama..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Info "Service Ollama demarre"
} else {
    Info "Service Ollama deja actif (PID $($proc.Id -join ', '))"
}

$env:OLLAMA_HOST = "http://localhost:11434"
Info "Test API Ollama sur $env:OLLAMA_HOST ..."

if (-not (Test-OllamaApi -OllamaHost $env:OLLAMA_HOST)) {
    Err "API Ollama inaccessible apres 5 tentatives"
    exit 1
}

# ---------------------------------------------------------------------------
# ETAPE 3 - VERIFICATION DOCKER DESKTOP
# ---------------------------------------------------------------------------
Step "ETAPE 3 - Verification Docker Desktop"

if (Test-Cmd "docker") {
    $dv = & docker --version 2>&1
    Info "Docker installe : $dv"
} else {
    Warn "Docker Desktop non trouve"
    Warn "Le deploiement continue sans Docker (Ollama seul)"
}

# ---------------------------------------------------------------------------
# ETAPE 4 - REPO
# ---------------------------------------------------------------------------
Step "ETAPE 4 - Repo llm-local-architecture"

if (-not (Test-Cmd "git")) {
    Err "git non trouve. Installer Git puis relancer."
    exit 1
}

if (Test-Path (Join-Path $REPO_DIR ".git")) {
    Info "Repo deja clone - verification a jour"
    Set-Location $REPO_DIR

    Invoke-Retry {
        & git fetch origin
        if ($LASTEXITCODE -ne 0) {
            throw "git fetch a echoue"
        }
    }

    Info "Repo a jour (fetch OK)"
} else {
    Info "Clonage du repo..."
    $parentDir = Split-Path $REPO_DIR
    Ensure-Directory -Path $parentDir

    Invoke-Retry {
        & git clone $REPO_URL $REPO_DIR
        if ($LASTEXITCODE -ne 0) {
            throw "git clone a echoue"
        }
    }

    Set-Location $REPO_DIR
}

Info "Repo a jour : $REPO_DIR"

# ---------------------------------------------------------------------------
# ETAPE 5 - TELECHARGEMENT DES MODELES
# ---------------------------------------------------------------------------
Step "ETAPE 5 - Telechargement des modeles"

$installedModels = Get-InstalledModels
$countOK   = 0
$countFail = 0

foreach ($model in $MODELS) {
    Info "Pull : $model"

    try {
        $isInstalled = $false
        if ($installedModels) {
            $isInstalled = [bool](@($installedModels | Where-Object { $_ -eq $model }).Count)
        }

        if ($isInstalled -and -not $ForceUpdate) {
            Info "  -> Deja present localement : $model"
            $countOK++
            continue
        }

        if ($ForceUpdate -and $isInstalled) {
            Warn "  -> ForceUpdate actif : repull de $model"
        }

        Invoke-Retry {
            & ollama pull $model
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "ollama pull a echoue pour $model (exit code $exitCode)"
            }
        }

        Info "  -> Pull reussi : $model"
        $countOK++
    } catch {
        Err "  -> Echec pull : $model"
        Err "     Detail : $($_.Exception.Message)"
        $countFail++
    }
}

Info "Modeles : $countOK OK, $countFail echecs"

# ---------------------------------------------------------------------------
# ETAPE 6 - VERIFICATION INTEGRITE ET CONFIANCE
# ---------------------------------------------------------------------------
Step "ETAPE 6 - Verification integrite et confiance"

$ollamaModelsDir = Get-OllamaModelsDir
if (-not (Test-Path $ollamaModelsDir)) {
    Err "Repertoire Ollama introuvable : $ollamaModelsDir"
    exit 1
}

Info "Repertoire Ollama : $ollamaModelsDir"

$approvedRegistry = Load-ApprovedRegistry

$currentManifest = [pscustomobject]@{
    generated_at   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    host           = $env:COMPUTERNAME
    schema_version = "1.0"
    models         = @()
}

foreach ($model in $MODELS) {
    Info "Verification : $model"

    $fingerprint = Get-ModelFingerprint -Model $model -OllamaModelsDir $ollamaModelsDir
    $approved    = Get-ApprovedModelEntry -Registry $approvedRegistry -ModelName $model
    $trustState  = Compare-ModelWithApproved -CurrentFingerprint $fingerprint -ApprovedEntry $approved

    $entry = [pscustomobject]@{
        name          = $fingerprint.name
        manifest_path = $fingerprint.manifest_path
        manifest_sha  = $fingerprint.manifest_sha
        local_status  = $fingerprint.status
        status        = $trustState
        note          = $fingerprint.note
        checked_at    = $fingerprint.checked_at
        blob_count    = $fingerprint.blob_count
        layers        = $fingerprint.layers
    }

    $currentManifest.models += $entry

    switch ($trustState) {
        "trusted"    { Info "  STATUS : trusted" }
        "candidate"  { Warn "  STATUS : candidate (jamais approuve)" }
        "drifted"    { Warn "  STATUS : drifted (contenu different du modele approuve)" }
        "quarantine" { Err  "  STATUS : quarantine (integrite non validee)" }
        "missing"    { Warn "  STATUS : missing" }
        default      { Warn "  STATUS : $trustState" }
    }
}

$currentManifest | ConvertTo-Json -Depth 30 | Set-Content -Path $CURRENT_MANIFEST -Encoding UTF8
Info "Manifest courant ecrit : $CURRENT_MANIFEST"

# ---------------------------------------------------------------------------
# ETAPE 7 - APPROBATION EXPLICITE
# ---------------------------------------------------------------------------
Step "ETAPE 7 - Approbation"

if ($ApproveCandidates) {
    $approvedRegistry = Approve-CandidateModels -CurrentManifest $currentManifest -Registry $approvedRegistry
    Save-ApprovedRegistry -Registry $approvedRegistry
    Info "Registre approuve mis a jour : $APPROVED_REGISTRY"
} else {
    Warn "Aucune approbation automatique"
    Warn "Relancer avec -ApproveCandidates apres validation fonctionnelle"
}

# ---------------------------------------------------------------------------
# ETAPE 8 - DOCKER COMPOSE
# ---------------------------------------------------------------------------
Step "ETAPE 8 - Docker Compose (Open WebUI)"

if (Test-Cmd "docker") {
    Set-Location $REPO_DIR
    try {
        & docker compose up -d
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose up a echoue"
        }
        Info "Open WebUI accessible sur http://localhost:3000"
    } catch {
        Warn "docker compose up echoue : $($_.Exception.Message)"
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
Write-Host "  Machine           : $env:COMPUTERNAME"
Write-Host "  Repo              : $REPO_DIR"
Write-Host "  Ollama models dir : $ollamaModelsDir"
Write-Host "  Manifest courant  : $CURRENT_MANIFEST"
Write-Host "  Registre approuve : $APPROVED_REGISTRY"
Write-Host "  Log               : $LOGFILE"
Write-Host ""
Write-Host "  MODELES CIBLES :"
foreach ($model in $MODELS) {
    Write-Host "    -> $model"
}
Write-Host ""
Write-Host "  ETAT ACTUEL :"
foreach ($model in $currentManifest.models) {
    Write-Host ("    -> {0} [{1}]" -f $model.name, $model.status)
}
Write-Host ""
Write-Host "  ACCES :"
Write-Host "    Ollama API : http://localhost:11434"
if (Test-Cmd "docker") {
    Write-Host "    Open WebUI : http://localhost:3000"
}
Write-Host ""
Write-Host "  TEST RAPIDE :"
Write-Host '    ollama run phi4-mini "Dis bonjour en une phrase"'
Write-Host ""

Info "Deploiement Windows termine"

