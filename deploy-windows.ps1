#!/usr/bin/env pwsh
# =============================================================================
# deploy-windows.ps1 - Deploiement llm-local-architecture sur Windows natif
# Prerequis : PowerShell 5+, acces internet, Ollama, Docker Desktop optionnel
# Usage :
#   .\deploy-windows.ps1
#   .\deploy-windows.ps1 -ApproveCandidates
#   .\deploy-windows.ps1 -CheckByPull
#   .\deploy-windows.ps1 -AutoUpdate
#   .\deploy-windows.ps1 -ForceUpdate
#   .\deploy-windows.ps1 -CheckRemoteUpdates
#   .\deploy-windows.ps1 -SetupPythonEnv
#   .\deploy-windows.ps1 -SetupPythonEnv -LaunchApp
# =============================================================================

param(
    [switch]$CheckByPull,
    [switch]$AutoUpdate,
    [switch]$ForceUpdate,
    [switch]$ApproveCandidates,
    [switch]$CheckRemoteUpdates,
    [switch]$SetupPythonEnv,
    [switch]$LaunchApp,
    [Alias("h")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Help) {
    Show-Usage
    exit 0
}

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

$script:TesseractStatus = "ABSENT"
$script:TesseractPath = $null
$script:TesseractLanguages = @()
$script:TesseractImpact = "OCR image / PDF scanne indisponible ; installer Tesseract, la langue fra et les dependances Python OCR."
$script:PythonVenvDir = $null
$script:PythonVenvPython = $null
$script:PythonVenvStatus = "ABSENT"
$script:PythonDepsStatus = "A installer"
$script:OcrPythonModulesStatus = "NON VALIDE"
$script:OcrRuntimeStatus = "NON VALIDE"
$script:OcrFunctionalTestStatus = "NON VALIDE"
$script:OcrOverallStatus = "NON VALIDE"
$script:OcrFailureReason = $null
$script:FastApiUrl = "http://127.0.0.1:8001"

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

function Show-Usage {
    @"
Usage: .\deploy-windows.ps1 [options]

Options:
  -CheckByPull        Fait un pull controle et compare le digest avant/apres.
  -AutoUpdate         Autorise la mise a jour par pull des modeles deja presents.
  -ForceUpdate        Force un pull meme si le modele est deja present.
  -ApproveCandidates  Approuve explicitement les modeles candidate/drifted/trusted.
  -CheckRemoteUpdates Verifie le digest distant via https://ollama.com/api si OLLAMA_API_KEY est defini.
  -SetupPythonEnv     Cree .venv, met a jour pip et installe pip install -e ".[dev]".
  -LaunchApp          Lance FastAPI via .\.venv\Scripts\python.exe -m uvicorn ... --port 8001.
  -Help               Affiche cette aide.
"@
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

function Get-TesseractPath {
    $candidates = @()

    $fromPath = Get-Command "tesseract.exe" -ErrorAction SilentlyContinue
    if ($fromPath) {
        $candidates += $fromPath.Source
    }

    $candidates += @(
        "C:\Program Files\Tesseract-OCR\tesseract.exe",
        "C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
        (Join-Path $env:LOCALAPPDATA "Tesseract-OCR\tesseract.exe")
    )

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Update-PythonStatus {
    if (-not $script:PythonVenvDir) {
        return
    }

    $venvPython = Join-Path $script:PythonVenvDir "Scripts\python.exe"
    $script:PythonVenvPython = $venvPython

    if (Test-Path $venvPython) {
        $script:PythonVenvStatus = "OK"
        try {
            & $venvPython -m pip show llm-local-architecture *> $null
            if ($LASTEXITCODE -eq 0) {
                $script:PythonDepsStatus = "OK"
            } else {
                $script:PythonDepsStatus = "A installer"
            }
        } catch {
            $script:PythonDepsStatus = "A installer"
        }
    } else {
        $script:PythonVenvStatus = "ABSENT"
        $script:PythonDepsStatus = "A installer"
    }
}

function Get-PreferredPythonForVenvCreation {
    $candidates = @("py", "python", "python3")
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Setup-PythonEnvironment {
    Step "ETAPE PY - Preparation de l'environnement Python"

    if (-not (Test-Path $script:PythonVenvDir)) {
        $pythonCmd = Get-PreferredPythonForVenvCreation
        if (-not $pythonCmd) {
            Err "Python introuvable. Installer Python 3.11+ puis relancer avec -SetupPythonEnv."
            exit 1
        }

        Info "Creation du virtualenv : $script:PythonVenvDir"
        & $pythonCmd -m venv $script:PythonVenvDir
        if ($LASTEXITCODE -ne 0) {
            Err "Creation du virtualenv echouee"
            exit 1
        }
    } else {
        Info "Virtualenv deja present : $script:PythonVenvDir"
    }

    Update-PythonStatus
    if (-not (Test-Path $script:PythonVenvPython)) {
        Err "Python du virtualenv introuvable : $script:PythonVenvPython"
        exit 1
    }

    Info "Mise a jour de pip dans le virtualenv"
    & $script:PythonVenvPython -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) {
        Err "Mise a jour de pip echouee"
        exit 1
    }

    Info 'Installation editable : pip install -e ".[dev]"'
    & $script:PythonVenvPython -m pip install -e ".[dev]"
    if ($LASTEXITCODE -ne 0) {
        Err "Installation Python echouee"
        exit 1
    }

    Update-PythonStatus
}

function Start-FastApiApp {
    Step "ETAPE APP - Lancement FastAPI local"

    Update-PythonStatus
    if (-not (Test-Path $script:PythonVenvPython)) {
        if ($SetupPythonEnv) {
            Err "Le virtualenv reste indisponible apres -SetupPythonEnv."
        } else {
            Err "Virtualenv absent. Relancer avec -SetupPythonEnv ou creer .venv avant -LaunchApp."
        }
        exit 1
    }

    if ($script:PythonDepsStatus -ne "OK") {
        Warn "Dependances Python non confirmees dans le virtualenv. Le lancement peut echouer."
    }

    Info "Lancement FastAPI sur $script:FastApiUrl"
    & $script:PythonVenvPython -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
    exit $LASTEXITCODE
}

function Get-TesseractLanguages {
    param([string]$TesseractCmd)

    if (-not $TesseractCmd) {
        return @()
    }

    try {
        $lines = & $TesseractCmd --list-langs 2>$null
        if (-not $lines) {
            return @()
        }

        return @($lines | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch {
        Warn "Impossible de lire les langues Tesseract : $($_.Exception.Message)"
        return @()
    }
}

function Initialize-TesseractStatus {
    $script:TesseractPath = Get-TesseractPath

    if ($script:TesseractPath) {
        $script:TesseractStatus = "OK"
        $script:TesseractLanguages = @(Get-TesseractLanguages -TesseractCmd $script:TesseractPath)
        $env:TESSERACT_CMD = $script:TesseractPath

        if ($script:TesseractLanguages -contains "fra" -and $script:TesseractLanguages -contains "eng") {
            $script:TesseractImpact = "Binaire Tesseract pret avec fra et eng."
        } elseif ($script:TesseractLanguages -contains "fra") {
            $script:TesseractStatus = "WARNING"
            $script:TesseractImpact = "Binaire Tesseract pret avec fra ; fallback eng absent."
        } elseif ($script:TesseractLanguages -contains "eng") {
            $script:TesseractStatus = "ERROR"
            $script:TesseractImpact = "Tesseract detecte mais fra manque ; OCR francais nominal indisponible."
        } else {
            $script:TesseractStatus = "ERROR"
            $script:TesseractImpact = "Tesseract detecte sans fra ; OCR francais indisponible."
        }

        Info "Tesseract detecte : $script:TesseractPath"
        if ($script:TesseractLanguages.Count -gt 0) {
            Info "Langues Tesseract : $($script:TesseractLanguages -join ', ')"
        } else {
            Warn "Langues Tesseract non detectees"
        }
        Info "TESSERACT_CMD recommande pour cette session : $env:TESSERACT_CMD"
        return
    }

    Warn "Tesseract absent sur cette machine Windows"
    Warn "OCR image / PDF scanne indisponible tant que Tesseract et la langue fra ne sont pas installes"
    Warn "Installation recommandee : winget install --id UB-Mannheim.TesseractOCR -e"
    Warn "Chemin attendu ensuite : C:\Program Files\Tesseract-OCR\tesseract.exe"
}

function Test-OcrPythonRuntime {
    if (-not (Test-Path $script:PythonVenvPython)) {
        $script:OcrPythonModulesStatus = "ERROR"
        $script:OcrRuntimeStatus = "ERROR"
        $script:OcrFunctionalTestStatus = "ERROR"
        $script:OcrOverallStatus = "ERROR"
        $script:OcrFailureReason = "Virtualenv absent. Relancer avec -SetupPythonEnv pour installer les dependances OCR."
        return $false
    }

    $pythonSnippet = @'
import os
import re
import sys

from PIL import Image

details = {}

try:
    import cv2
    details["cv2"] = cv2.__version__
except Exception as exc:
    print(f"ERROR:IMPORT:cv2:{exc}")
    sys.exit(2)

try:
    import numpy
    details["numpy"] = numpy.__version__
except Exception as exc:
    print(f"ERROR:IMPORT:numpy:{exc}")
    sys.exit(2)

try:
    import pytesseract
    details["pytesseract"] = pytesseract.__version__
except Exception as exc:
    print(f"ERROR:IMPORT:pytesseract:{exc}")
    sys.exit(2)

tesseract_cmd = os.environ.get("OCR_TESSERACT_CMD", "").strip()
if tesseract_cmd:
    pytesseract.pytesseract.tesseract_cmd = tesseract_cmd

available = set(pytesseract.get_languages(config=""))
ordered_langs = ",".join(sorted(available))
print(f"DETAIL:IMPORTS:cv2={details['cv2']};numpy={details['numpy']};pytesseract={details['pytesseract']}")
print(f"DETAIL:LANGS:{ordered_langs}")

if "fra" not in available:
    print("ERROR:LANG:fra_missing")
    sys.exit(3)

image = numpy.full((220, 900, 3), 255, dtype=numpy.uint8)
cv2.putText(
    image,
    "BONJOUR 2026",
    (30, 140),
    cv2.FONT_HERSHEY_SIMPLEX,
    3.0,
    (0, 0, 0),
    5,
    cv2.LINE_AA,
)

pil_image = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
text = pytesseract.image_to_string(pil_image, lang="fra", config="--oem 3 --psm 7").strip()
normalized = re.sub(r"[^a-z0-9]+", "", text.lower())
print(f"DETAIL:OCR_TEXT:{text}")

if "bonjour" not in normalized:
    print(f"ERROR:FUNCTIONAL:{text}")
    sys.exit(4)

print("OK:OCR_RUNTIME")
'@

    $env:OCR_TESSERACT_CMD = $script:TesseractPath
    $output = @(& $script:PythonVenvPython -c $pythonSnippet 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $script:OcrPythonModulesStatus = "ERROR"
        $script:OcrRuntimeStatus = "ERROR"
        $script:OcrFunctionalTestStatus = "ERROR"
        $script:OcrOverallStatus = "ERROR"
        $script:OcrFailureReason = ($output | Select-Object -Last 1)
        return $false
    }

    foreach ($line in $output) {
        if (-not $line) { continue }
        if ($line -like "DETAIL:IMPORTS:*") {
            Info ("OCR Python imports : {0}" -f $line.Substring("DETAIL:IMPORTS:".Length))
        } elseif ($line -like "DETAIL:LANGS:*") {
            Info ("OCR langues vues depuis pytesseract : {0}" -f $line.Substring("DETAIL:LANGS:".Length))
        } elseif ($line -like "DETAIL:OCR_TEXT:*") {
            Info ("OCR test fonctionnel : {0}" -f $line.Substring("DETAIL:OCR_TEXT:".Length))
        } elseif ($line -eq "OK:OCR_RUNTIME") {
            Info "OCR runtime Python valide"
        }
    }

    $script:OcrPythonModulesStatus = "OK"
    $script:OcrRuntimeStatus = "OK"
    $script:OcrFunctionalTestStatus = "OK"
    $script:OcrOverallStatus = "OK"
    $script:OcrFailureReason = $null
    return $true
}

function Validate-OcrEnvironment {
    $script:OcrPythonModulesStatus = "NON VALIDE"
    $script:OcrRuntimeStatus = "NON VALIDE"
    $script:OcrFunctionalTestStatus = "NON VALIDE"
    $script:OcrOverallStatus = "NON VALIDE"
    $script:OcrFailureReason = $null

    if ($script:TesseractStatus -eq "ABSENT") {
        $script:OcrOverallStatus = "ERROR"
        $script:OcrFailureReason = "Tesseract introuvable."
        return $false
    }

    if (-not ($script:TesseractLanguages -contains "fra")) {
        $script:TesseractStatus = "ERROR"
        $script:TesseractImpact = "Le pack langue fra manque ; l'usage OCR francais nominal est indisponible."
        $script:OcrOverallStatus = "ERROR"
        $script:OcrFailureReason = "Langue fra absente dans Tesseract."
        return $false
    }

    if ($script:TesseractLanguages -contains "eng") {
        $script:TesseractImpact = "OCR pret pour fra avec fallback eng ; image / PDF scanne exploitables."
    } else {
        $script:TesseractImpact = "OCR pret pour fra ; fallback eng absent mais usage francais nominal disponible."
    }

    if (-not (Test-OcrPythonRuntime)) {
        $script:TesseractImpact = "Chaine OCR incomplete ; corriger le runtime Python avant usage image / PDF scanne."
        return $false
    }

    if (-not ($script:TesseractLanguages -contains "eng")) {
        $script:OcrOverallStatus = "WARNING"
    }

    return $true
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

function Get-LocalModelMetadata {
    param(
        [string]$Model,
        [string]$OllamaHost
    )

    try {
        $response = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 10
        $matches = @($response.models | Where-Object { $_.name -eq $Model })
        if ($matches.Count -gt 0) {
            return $matches[0]
        }
    } catch {
        Warn "Impossible de lire /api/tags pour $Model : $($_.Exception.Message)"
    }

    return $null
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

function Get-LocalModelSnapshot {
    param(
        [string]$Model,
        [string]$OllamaHost,
        [string]$OllamaModelsDir
    )

    $metadata    = Get-LocalModelMetadata -Model $Model -OllamaHost $OllamaHost
    $fingerprint = Get-ModelFingerprint -Model $Model -OllamaModelsDir $OllamaModelsDir

    $digest = $null
    $digestSource = "none"
    $exists = $false

    if ($metadata) {
        $exists = $true
        if ($metadata.PSObject.Properties.Name -contains "digest" -and $metadata.digest) {
            $digest = $metadata.digest
            $digestSource = "api_tags"
        }
    }

    if (-not $digest -and $fingerprint.status -ne "missing" -and $fingerprint.manifest_sha) {
        $digest = $fingerprint.manifest_sha
        $digestSource = "manifest_sha"
        $exists = $true
    }

    $modifiedAt = $null
    $size = $null
    $details = $null
    if ($metadata) {
        $modifiedAt = $metadata.modified_at
        $size = $metadata.size
        $details = $metadata.details
    }

    return [pscustomobject]@{
        name          = $Model
        exists        = $exists
        digest        = $digest
        digest_source = $digestSource
        modified_at   = $modifiedAt
        size          = $size
        details       = $details
        fingerprint   = $fingerprint
    }
}

function Get-RemoteModelDigest {
    param([string]$Model)

    if (-not $CheckRemoteUpdates) {
        return [pscustomobject]@{
            status = "skipped"
            digest = $null
            note   = "option disabled"
        }
    }

    if (-not $env:OLLAMA_API_KEY) {
        return [pscustomobject]@{
            status = "skipped"
            digest = $null
            note   = "OLLAMA_API_KEY absent"
        }
    }

    try {
        $headers = @{ Authorization = "Bearer $($env:OLLAMA_API_KEY)" }
        $response = Invoke-RestMethod -Uri "https://ollama.com/api/tags" -Headers $headers -TimeoutSec 15
        $matches = @($response.models | Where-Object { $_.name -eq $Model })
        if ($matches.Count -gt 0 -and $matches[0].digest) {
            return [pscustomobject]@{
                status = "ok"
                digest = $matches[0].digest
                note   = $null
            }
        }

        return [pscustomobject]@{
            status = "failed"
            digest = $null
            note   = "remote digest introuvable"
        }
    } catch {
        return [pscustomobject]@{
            status = "failed"
            digest = $null
            note   = $_.Exception.Message
        }
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
        if ($model.status -in @("candidate", "trusted", "drifted")) {
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
Info "CheckByPull : $CheckByPull"
Info "AutoUpdate : $AutoUpdate"
Info "ForceUpdate : $ForceUpdate"
Info "ApproveCandidates : $ApproveCandidates"
Info "CheckRemoteUpdates : $CheckRemoteUpdates"
Info "SetupPythonEnv : $SetupPythonEnv"
Info "LaunchApp : $LaunchApp"

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
# ETAPE 3B - VERIFICATION OCR TESSERACT
# ---------------------------------------------------------------------------
Step "ETAPE 3B - Verification OCR Tesseract"
Initialize-TesseractStatus
if ($script:TesseractStatus -in @("OK", "WARNING")) {
    Info "Tesseract detecte : $script:TesseractPath"
    Info "Langues Tesseract : $(if ($script:TesseractLanguages.Count -gt 0) { $script:TesseractLanguages -join ', ' } else { 'aucune' })"
} else {
    Warn "Les documents image / PDF scanne resteront indisponibles tant que Tesseract et fra ne sont pas installes"
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
$script:PythonVenvDir = Join-Path $REPO_DIR ".venv"
$script:PythonVenvPython = Join-Path $script:PythonVenvDir "Scripts\python.exe"
Update-PythonStatus

# ---------------------------------------------------------------------------
# ETAPE 5 - TELECHARGEMENT DES MODELES
# ---------------------------------------------------------------------------
Step "ETAPE 5 - Telechargement des modeles"

$installedModels = Get-InstalledModels
$ollamaModelsDirForPull = Get-OllamaModelsDir
$modelOperations = @{}
$countOK   = 0
$countFail = 0

foreach ($model in $MODELS) {
    Info "Traitement : $model"

    $beforeSnapshot = $null
    $remoteCheck = [pscustomobject]@{
        status = "skipped"
        digest = $null
        note   = "not available"
    }

    try {
        $beforeSnapshot = Get-LocalModelSnapshot -Model $model -OllamaHost $env:OLLAMA_HOST -OllamaModelsDir $ollamaModelsDirForPull
        $remoteCheck = Get-RemoteModelDigest -Model $model

        $isInstalled = $beforeSnapshot.exists
        $shouldPull = (-not $isInstalled) -or $ForceUpdate -or $AutoUpdate -or $CheckByPull
        $installState = if ($isInstalled) { "already_present" } else { "installed" }
        $updateState = "up_to_date"
        $pullPerformed = $false
        $pullNote = $null
        $pullReason = "standard_check"
        $afterSnapshot = $beforeSnapshot

        if (-not $isInstalled) {
            $pullReason = "install_missing"
        } elseif ($ForceUpdate) {
            $pullReason = "force_update"
        } elseif ($AutoUpdate) {
            $pullReason = "auto_update"
        } elseif ($CheckByPull) {
            $pullReason = "check_by_pull"
        }

        if ($CheckRemoteUpdates) {
            if ($remoteCheck.status -eq "ok" -and $beforeSnapshot.digest) {
                if ($remoteCheck.digest -ne $beforeSnapshot.digest) {
                    Warn "  -> Digest distant different detecte pour $model"
                    if (-not $shouldPull) {
                        $updateState = "update_unknown"
                    }
                } else {
                    Info "  -> Check distant OK : pas de difference detectee"
                }
            } else {
                Warn "  -> Check distant ignore : $($remoteCheck.note)"
            }
        }

        if (-not $shouldPull) {
            Info "  -> Check standard : deja present localement, aucun pull"
            $modelOperations[$model] = [pscustomobject]@{
                install_state      = $installState
                update_state       = $updateState
                pull_performed     = $pullPerformed
                pull_reason        = $pullReason
                pull_note          = $pullNote
                before_digest      = $beforeSnapshot.digest
                after_digest       = $afterSnapshot.digest
                local_digest_source= $afterSnapshot.digest_source
                remote_check       = $remoteCheck
            }
            $countOK++
            continue
        }

        if ($ForceUpdate -and $isInstalled) {
            Warn "  -> ForceUpdate actif : repull de $model"
        } elseif ($AutoUpdate -and $isInstalled) {
            Warn "  -> AutoUpdate actif : pull controle de $model"
        } elseif ($CheckByPull -and $isInstalled) {
            Info "  -> CheckByPull actif : verification via pull controle de $model"
        } elseif (-not $isInstalled) {
            Info "  -> Installation du modele manquant : $model"
        }

        $pullPerformed = $true
        Invoke-Retry {
            & ollama pull $model
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "ollama pull a echoue pour $model (exit code $exitCode)"
            }
        }

        $afterSnapshot = Get-LocalModelSnapshot -Model $model -OllamaHost $env:OLLAMA_HOST -OllamaModelsDir $ollamaModelsDirForPull

        if (-not $afterSnapshot.exists -or -not $afterSnapshot.digest) {
            $updateState = "update_unknown"
            $pullNote = "pull reussi mais digest courant introuvable"
            Warn "  -> Pull reussi mais digest courant introuvable : $model"
        } elseif (-not $isInstalled) {
            $installState = "installed"
            $updateState = "up_to_date"
            Info "  -> Installation reussie : $model"
        } elseif ($beforeSnapshot.digest -eq $afterSnapshot.digest) {
            $updateState = "up_to_date"
            Info "  -> Pull reussi sans changement de digest : $model"
        } else {
            $updateState = "updated"
            Warn "  -> Mise a jour detectee apres pull : $model"
        }

        $modelOperations[$model] = [pscustomobject]@{
            install_state       = $installState
            update_state        = $updateState
            pull_performed      = $pullPerformed
            pull_reason         = $pullReason
            pull_note           = $pullNote
            before_digest       = $beforeSnapshot.digest
            after_digest        = $afterSnapshot.digest
            local_digest_source = $afterSnapshot.digest_source
            remote_check        = $remoteCheck
        }

        $countOK++
    } catch {
        Err "  -> Echec pull : $model"
        Err "     Detail : $($_.Exception.Message)"
        $afterSnapshot = Get-LocalModelSnapshot -Model $model -OllamaHost $env:OLLAMA_HOST -OllamaModelsDir $ollamaModelsDirForPull
        $beforeDigest = $null
        if ($beforeSnapshot) {
            $beforeDigest = $beforeSnapshot.digest
        }
        $modelOperations[$model] = [pscustomobject]@{
            install_state       = "pull_failed"
            update_state        = "update_unknown"
            pull_performed      = $true
            pull_reason         = "pull_failed"
            pull_note           = $_.Exception.Message
            before_digest       = $beforeDigest
            after_digest        = $afterSnapshot.digest
            local_digest_source = $afterSnapshot.digest_source
            remote_check        = $remoteCheck
        }
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
    if ($modelOperations.ContainsKey($model)) {
        $operation = $modelOperations[$model]
    } else {
        $defaultInstallState = "already_present"
        $defaultUpdateState = "up_to_date"
        if ($fingerprint.status -eq "missing") {
            $defaultInstallState = "pull_failed"
            $defaultUpdateState = "update_unknown"
        }

        $operation = [pscustomobject]@{
            install_state       = $defaultInstallState
            update_state        = $defaultUpdateState
            pull_performed      = $false
            pull_reason         = "standard_check"
            pull_note           = $null
            before_digest       = $null
            after_digest        = $null
            local_digest_source = "unknown"
            remote_check        = [pscustomobject]@{ status = "skipped"; digest = $null; note = "not available" }
        }
    }

    $entry = [pscustomobject]@{
        name          = $fingerprint.name
        install_state = $operation.install_state
        trust_state   = $trustState
        update_state  = $operation.update_state
        manifest_path = $fingerprint.manifest_path
        manifest_sha  = $fingerprint.manifest_sha
        local_digest  = $operation.after_digest
        previous_digest = $operation.before_digest
        local_digest_source = $operation.local_digest_source
        remote_digest = $operation.remote_check.digest
        remote_check_status = $operation.remote_check.status
        remote_check_note = $operation.remote_check.note
        pull_performed = $operation.pull_performed
        pull_reason    = $operation.pull_reason
        pull_note      = $operation.pull_note
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
        $dockerProfile = "webui-only"
        Info "Profil Docker Compose selectionne : $dockerProfile"

        $services = & docker compose --profile $dockerProfile config --services 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose --profile $dockerProfile config --services a echoue : $services"
        }

        $serviceList = @($services | Where-Object { $_ -and $_.Trim() -ne "" })
        if ($serviceList.Count -eq 0) {
            throw "aucun service selectionne pour le profil $dockerProfile"
        }

        Info "Services Docker Compose : $($serviceList -join ', ')"

        & docker compose --profile $dockerProfile up -d
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose --profile $dockerProfile up -d a echoue"
        }
        Info "Open WebUI accessible sur http://localhost:3000"
    } catch {
        Warn "docker compose profil webui-only echoue : $($_.Exception.Message)"
        Warn "Verifier que Docker Desktop est lance"
    }
} else {
    Warn "Docker non disponible - Open WebUI non lance"
    Info "Ollama accessible sur http://localhost:11434"
}

if ($SetupPythonEnv) {
    Set-Location $REPO_DIR
    Setup-PythonEnvironment
} else {
    Update-PythonStatus
}

# ---------------------------------------------------------------------------
# ETAPE 9 - VALIDATION OCR RUNTIME
# ---------------------------------------------------------------------------
Step "ETAPE 9 - Validation OCR runtime"
if (Validate-OcrEnvironment) {
    if ($script:OcrOverallStatus -eq "WARNING") {
        Warn "OCR exploitable avec limitation : $script:TesseractImpact"
    } else {
        Info "OCR exploitable : chaine locale validee"
    }
} else {
    Err "OCR non exploitable : $script:OcrFailureReason"
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
Write-Host "  OCR :"
Write-Host "    Tesseract : $script:TesseractStatus"
Write-Host "    Chemin    : $(if ($script:TesseractPath) { $script:TesseractPath } else { 'non detecte' })"
Write-Host "    Langues   : $(if ($script:TesseractLanguages.Count -gt 0) { $script:TesseractLanguages -join ', ' } else { 'aucune' })"
Write-Host "    Imports   : $script:OcrPythonModulesStatus"
Write-Host "    Runtime   : $script:OcrRuntimeStatus"
Write-Host "    Test OCR  : $script:OcrFunctionalTestStatus"
Write-Host "    Statut    : $script:OcrOverallStatus"
Write-Host "    Impact    : $script:TesseractImpact"
if ($script:OcrFailureReason) {
    Write-Host "    Diagnostic: $script:OcrFailureReason"
}
Write-Host ""
Write-Host "  PYTHON :"
Write-Host "    Virtualenv       : $script:PythonVenvStatus"
Write-Host "    Dependances      : $script:PythonDepsStatus"
Write-Host "    Python du venv   : $(if ($script:PythonVenvPython) { $script:PythonVenvPython } else { 'non detecte' })"
Write-Host "    FastAPI locale   : $script:FastApiUrl"
Write-Host ""
Write-Host "  MODELES CIBLES :"
foreach ($model in $MODELS) {
    Write-Host "    -> $model"
}
Write-Host ""
Write-Host "  ETAT ACTUEL :"
foreach ($model in $currentManifest.models) {
    Write-Host ("    -> {0} [{1}] [{2}] [{3}]" -f $model.name, $model.trust_state, $model.update_state, $model.install_state)
}
Write-Host ""
Write-Host "  ACCES :"
Write-Host "    Ollama API : http://localhost:11434"
Write-Host "    FastAPI locale : http://127.0.0.1:8001 (usage principal du projet)"
if (Test-Cmd "docker") {
    Write-Host "    Open WebUI optionnel : http://localhost:3000"
}
Write-Host ""
Write-Host "  OPTIONS :"
Write-Host "    -CheckByPull        $CheckByPull"
Write-Host "    -AutoUpdate         $AutoUpdate"
Write-Host "    -ForceUpdate        $ForceUpdate"
Write-Host "    -ApproveCandidates  $ApproveCandidates"
Write-Host "    -CheckRemoteUpdates $CheckRemoteUpdates"
Write-Host "    -SetupPythonEnv     $SetupPythonEnv"
Write-Host "    -LaunchApp          $LaunchApp"
Write-Host ""
Write-Host "  TEST RAPIDE :"
Write-Host '    ollama run phi4-mini "Dis bonjour en une phrase"'
Write-Host ""

if ($script:OcrOverallStatus -eq "ERROR") {
    Err "Deploiement Windows termine avec echec OCR"
    exit 1
}

Info "Deploiement Windows termine (ocr=$($script:OcrOverallStatus))"

if ($LaunchApp) {
    Set-Location $REPO_DIR
    Start-FastApiApp
}
