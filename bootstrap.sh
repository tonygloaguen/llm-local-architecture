#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Déploiement et vérification du batch LLM local
# Usage :
#   bash bootstrap.sh
#   bash bootstrap.sh --check-by-pull
#   bash bootstrap.sh --auto-update --approve-candidates
#   bash bootstrap.sh --force-update
#   bash bootstrap.sh --setup-python-env
#   bash bootstrap.sh --setup-python-env --launch-app
# =============================================================================
set -euo pipefail

CHECK_BY_PULL=false
AUTO_UPDATE=false
FORCE_UPDATE=false
APPROVE_CANDIDATES=false
CHECK_REMOTE_UPDATES=false
SETUP_PYTHON_ENV=false
LAUNCH_APP=false
PYTHON_VENV_STATUS="ABSENT"
PYTHON_DEPS_STATUS="À installer"
OCR_PYTHON_MODULES_STATUS="NON VALIDÉ"
OCR_RUNTIME_STATUS="NON VALIDÉ"
OCR_FUNCTIONAL_TEST_STATUS="NON VALIDÉ"
OCR_OVERALL_STATUS="NON VALIDÉ"
APP_URL="http://127.0.0.1:8001"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${REPO_DIR}/.venv"
VENV_PYTHON="${VENV_DIR}/bin/python"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-by-pull)
      CHECK_BY_PULL=true
      ;;
    --auto-update)
      AUTO_UPDATE=true
      ;;
    --force-update)
      FORCE_UPDATE=true
      ;;
    --approve-candidates)
      APPROVE_CANDIDATES=true
      ;;
    --check-remote-updates)
      CHECK_REMOTE_UPDATES=true
      ;;
    --setup-python-env)
      SETUP_PYTHON_ENV=true
      ;;
    --launch-app)
      LAUNCH_APP=true
      ;;
    -h|--help)
      cat <<'EOF'
Usage: bash bootstrap.sh [options]

Options:
  --check-by-pull         Effectue un pull contrôlé et compare le digest avant/après.
  --auto-update           Autorise la mise à jour par pull des modèles déjà présents.
  --force-update          Force un pull même si le modèle est déjà présent.
  --approve-candidates    Approuve explicitement les modèles candidate/drifted/trusted.
  --check-remote-updates  Vérifie le digest distant via https://ollama.com/api si OLLAMA_API_KEY est défini.
  --setup-python-env      Crée .venv, met à jour pip et installe pip install -e ".[dev]".
  --launch-app            Lance FastAPI via .venv/bin/python -m uvicorn ... --port 8001.
EOF
      exit 0
      ;;
    *)
      echo "Option inconnue : $1" >&2
      exit 1
      ;;
  esac
  shift
done

LLMHOME="${HOME}/.llm-local"
LOG_DIR="${LLMHOME}/logs"
MANIFEST_DIR="${LLMHOME}/manifests"
REGISTRY_DIR="${LLMHOME}/registry"
QUARANTINE_DIR="${LLMHOME}/quarantine"
TRUSTED_DIR="${LLMHOME}/trusted"
CURRENT_MANIFEST="${MANIFEST_DIR}/current_manifest.json"
APPROVED_REGISTRY="${REGISTRY_DIR}/approved_models.json"
RECHECK_SCRIPT="${LLMHOME}/recheck.sh"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="${LOG_DIR}/bootstrap_${TIMESTAMP}.log"
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME_VAL=$(hostname)
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

MODELS=(
  "qwen2.5-coder:7b-instruct|code|Qwen/Qwen2.5-Coder-7B-Instruct|bartowski|Qwen2.5-Coder-7B-Instruct-GGUF"
  "granite3.3:8b|audit|ibm-granite/granite-3.3-8b-instruct|lmstudio-community|granite-3.3-8b-instruct-GGUF"
  "deepseek-r1:7b|agent|deepseek-ai/DeepSeek-R1-Distill-Qwen-7B|bartowski|DeepSeek-R1-Distill-Qwen-7B-GGUF"
  "phi4-mini|debug|microsoft/Phi-4-mini-instruct|bartowski|Phi-4-mini-instruct-GGUF"
  "mistral:7b-instruct-v0.3-q4_K_M|redaction|mistralai/Mistral-7B-Instruct-v0.3|TheBloke|Mistral-7B-Instruct-v0.3-GGUF"
)

COUNT_TRUSTED=0
COUNT_CANDIDATE=0
COUNT_DRIFTED=0
COUNT_QUARANTINE=0
COUNT_MISSING=0
COUNT_PULL_FAILED=0
COUNT_UPDATED=0
COUNT_INSTALLED=0
TESSERACT_STATUS="ABSENT"
TESSERACT_PATH_DISPLAY="non détecté"
TESSERACT_LANGS_DISPLAY="aucune"
TESSERACT_IMPACT="OCR image / PDF scanné indisponible ; installez Tesseract, la langue fra et les dépendances Python OCR."
OCR_FAILURE_REASON=""

update_python_status() {
  if [[ -x "${VENV_PYTHON}" ]]; then
    PYTHON_VENV_STATUS="OK"
    if "${VENV_PYTHON}" -m pip show llm-local-architecture >/dev/null 2>&1; then
      PYTHON_DEPS_STATUS="OK"
    else
      PYTHON_DEPS_STATUS="À installer"
    fi
  else
    PYTHON_VENV_STATUS="ABSENT"
    PYTHON_DEPS_STATUS="À installer"
  fi
}

validate_ocr_python_runtime_linux() {
  if [[ ! -x "${VENV_PYTHON}" ]]; then
    OCR_PYTHON_MODULES_STATUS="ERROR"
    OCR_RUNTIME_STATUS="ERROR"
    OCR_FUNCTIONAL_TEST_STATUS="ERROR"
    OCR_OVERALL_STATUS="ERROR"
    OCR_FAILURE_REASON="Virtualenv absent. Relancez avec --setup-python-env pour installer les dépendances OCR."
    return 1
  fi

  local python_output
  if ! python_output=$(
    OCR_TESSERACT_CMD="${TESSERACT_PATH_DISPLAY}" \
    "${VENV_PYTHON}" - <<'PY'
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
PY
  ); then
    OCR_PYTHON_MODULES_STATUS="ERROR"
    OCR_RUNTIME_STATUS="ERROR"
    OCR_FUNCTIONAL_TEST_STATUS="ERROR"
    OCR_OVERALL_STATUS="ERROR"
    OCR_FAILURE_REASON="$(printf '%s' "${python_output}" | tail -n 1)"
    return 1
  fi

  OCR_PYTHON_MODULES_STATUS="OK"
  OCR_RUNTIME_STATUS="OK"
  OCR_FUNCTIONAL_TEST_STATUS="OK"
  OCR_OVERALL_STATUS="OK"
  OCR_FAILURE_REASON=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    case "${line}" in
      DETAIL:IMPORTS:*)
        info "OCR Python imports : ${line#DETAIL:IMPORTS:}"
        ;;
      DETAIL:LANGS:*)
        info "OCR langues vues depuis pytesseract : ${line#DETAIL:LANGS:}"
        ;;
      DETAIL:OCR_TEXT:*)
        info "OCR test fonctionnel : ${line#DETAIL:OCR_TEXT:}"
        ;;
      OK:OCR_RUNTIME)
        info "OCR runtime Python validé"
        ;;
    esac
  done <<< "${python_output}"
}

validate_ocr_linux() {
  OCR_PYTHON_MODULES_STATUS="NON VALIDÉ"
  OCR_RUNTIME_STATUS="NON VALIDÉ"
  OCR_FUNCTIONAL_TEST_STATUS="NON VALIDÉ"
  OCR_OVERALL_STATUS="NON VALIDÉ"
  OCR_FAILURE_REASON=""

  if [[ "${TESSERACT_STATUS}" != "OK" && "${TESSERACT_STATUS}" != "WARNING" ]]; then
    OCR_OVERALL_STATUS="ERROR"
    OCR_FAILURE_REASON="Tesseract introuvable."
    return 1
  fi

  local has_fra=false
  local has_eng=false
  local lang
  IFS=',' read -ra _langs <<< "${TESSERACT_LANGS_DISPLAY}"
  for lang in "${_langs[@]}"; do
    lang="$(echo "${lang}" | xargs)"
    [[ "${lang}" == "fra" ]] && has_fra=true
    [[ "${lang}" == "eng" ]] && has_eng=true
  done

  if [[ "${has_fra}" != "true" ]]; then
    TESSERACT_STATUS="ERROR"
    TESSERACT_IMPACT="Le pack langue fra manque ; l'usage OCR français nominal est indisponible."
    OCR_OVERALL_STATUS="ERROR"
    OCR_FAILURE_REASON="Langue fra absente dans Tesseract."
    return 1
  fi

  if [[ "${has_eng}" == "true" ]]; then
    TESSERACT_IMPACT="OCR prêt pour fra avec fallback eng ; image / PDF scanné exploitables."
  else
    TESSERACT_IMPACT="OCR prêt pour fra ; fallback eng absent mais usage français nominal disponible."
  fi

  if ! validate_ocr_python_runtime_linux; then
    TESSERACT_IMPACT="Chaîne OCR incomplète ; corrigez le runtime Python avant usage image / PDF scanné."
    return 1
  fi

  if [[ "${has_eng}" != "true" ]]; then
    OCR_OVERALL_STATUS="WARNING"
  fi
  return 0
}

setup_python_env() {
  local python_cmd=""

  step "ÉTAPE PY — Préparation de l'environnement Python"
  if [[ ! -d "${VENV_DIR}" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python_cmd="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then
      python_cmd="$(command -v python)"
    else
      error "Python introuvable. Installez Python 3.11+ puis relancez avec --setup-python-env."
      exit 1
    fi

    info "Création du virtualenv : ${VENV_DIR}"
    "${python_cmd}" -m venv "${VENV_DIR}"
  else
    info "Virtualenv déjà présent : ${VENV_DIR}"
  fi

  if [[ ! -x "${VENV_PYTHON}" ]]; then
    error "Python du virtualenv introuvable : ${VENV_PYTHON}"
    exit 1
  fi

  info "Mise à jour de pip dans ${VENV_DIR}"
  "${VENV_PYTHON}" -m pip install --upgrade pip
  info 'Installation editable : pip install -e ".[dev]"'
  "${VENV_PYTHON}" -m pip install -e ".[dev]"
  update_python_status
}

launch_app() {
  step "ÉTAPE APP — Lancement FastAPI local"
  if [[ ! -x "${VENV_PYTHON}" ]]; then
    if [[ "${SETUP_PYTHON_ENV}" == "true" ]]; then
      error "Le virtualenv reste indisponible après --setup-python-env."
      exit 1
    fi
    error "Virtualenv absent. Relancez avec --setup-python-env ou créez ${VENV_DIR} avant --launch-app."
    exit 1
  fi

  if [[ "${PYTHON_DEPS_STATUS}" != "OK" ]]; then
    warn "Dépendances Python non confirmées dans ${VENV_DIR}. L'application peut échouer au démarrage."
  fi

  info "Lancement FastAPI sur ${APP_URL}"
  exec "${VENV_PYTHON}" -m uvicorn llm_local_architecture.orchestrator:app --host 127.0.0.1 --port 8001
}

log() {
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" | tee -a "${LOGFILE}"
}

info() { log "INFO " "$1"; }
warn() { log "WARN " "$1"; }
error() { log "ERROR" "$1"; }
step() {
  echo ""
  echo "══════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════"
  log "STEP " "$1"
}

retry() {
  local -r max_attempts=3
  local -r delay=5
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      error "Échec après ${max_attempts} tentatives : $*"
      return 1
    fi
    warn "Tentative ${attempt}/${max_attempts} échouée. Retry dans ${delay}s..."
    sleep "${delay}"
    (( attempt++ ))
  done
}

ensure_json_value() {
  local var_name="$1"
  local raw_value="${2-}"
  local fallback_json="$3"
  local ts line

  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ -z "${raw_value}" ]]; then
    line="[${ts}] [ERROR] Valeur JSON invalide pour ${var_name} : vide. Fallback=${fallback_json}"
    printf '%s\n' "${line}" >&2
    printf '%s\n' "${line}" >> "${LOGFILE}"
    echo "${fallback_json}"
    return
  fi

  if echo "${raw_value}" | jq -e 'type' >/dev/null 2>&1; then
    echo "${raw_value}"
    return
  fi

  line="[${ts}] [ERROR] Valeur JSON invalide pour ${var_name}. Fallback=${fallback_json}"
  printf '%s\n' "${line}" >&2
  printf '%s\n' "${line}" >> "${LOGFILE}"
  echo "${fallback_json}"
}

parse_model_name() { echo "${1%%:*}"; }

parse_model_tag() {
  local full="$1"
  if [[ "${full}" == *":"* ]]; then
    echo "${full#*:}"
  else
    echo "latest"
  fi
}

detect_ollama_base() {
  if [[ -n "${OLLAMA_MODELS:-}" ]] && [[ -d "${OLLAMA_MODELS}" ]]; then
    echo "${OLLAMA_MODELS}"
    return
  fi
  if [[ -d "/usr/share/ollama/.ollama/models" ]]; then
    echo "/usr/share/ollama/.ollama/models"
    return
  fi
  if [[ -d "/var/lib/ollama/models" ]]; then
    echo "/var/lib/ollama/models"
    return
  fi
  if [[ -d "${HOME}/.ollama/models" ]]; then
    echo "${HOME}/.ollama/models"
    return
  fi
  echo "${HOME}/.ollama/models"
}

get_tesseract_languages() {
  local tesseract_cmd="$1"
  local langs=""

  if langs=$("${tesseract_cmd}" --list-langs 2>/dev/null); then
    echo "${langs}" | tail -n +2 | awk 'NF {print $1}'
  fi
}

attempt_tesseract_install_linux() {
  local packages=(tesseract-ocr tesseract-ocr-eng tesseract-ocr-fra)

  if ! command -v apt-get >/dev/null 2>&1; then
    warn "Installation automatique Tesseract non tentee : apt-get indisponible"
    warn "Commande recommandee : sudo apt-get update && sudo apt-get install -y ${packages[*]}"
    return 1
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    info "Tentative d'installation automatique de Tesseract via apt-get"
    if apt-get update && apt-get install -y "${packages[@]}"; then
      return 0
    fi
    warn "Installation automatique de Tesseract via apt-get echouee"
    return 1
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    info "Tentative d'installation automatique de Tesseract via sudo apt-get"
    if sudo apt-get update && sudo apt-get install -y "${packages[@]}"; then
      return 0
    fi
    warn "Installation automatique de Tesseract via sudo apt-get echouee"
    return 1
  fi

  warn "Tesseract absent et installation automatique non possible sans elevation"
  warn "Commande recommandee : sudo apt-get update && sudo apt-get install -y ${packages[*]}"
  return 1
}

check_tesseract_linux() {
  local tesseract_cmd=""
  local langs=()
  local has_eng=false
  local has_fra=false

  if command -v tesseract >/dev/null 2>&1; then
    tesseract_cmd="$(command -v tesseract)"
  else
    warn "Tesseract absent du PATH"
    attempt_tesseract_install_linux || true
    if command -v tesseract >/dev/null 2>&1; then
      tesseract_cmd="$(command -v tesseract)"
    fi
  fi

  if [[ -n "${tesseract_cmd}" ]]; then
    mapfile -t langs < <(get_tesseract_languages "${tesseract_cmd}")
    TESSERACT_STATUS="OK"
    TESSERACT_PATH_DISPLAY="${tesseract_cmd}"
    if [[ ${#langs[@]} -gt 0 ]]; then
      TESSERACT_LANGS_DISPLAY="$(printf '%s, ' "${langs[@]}")"
      TESSERACT_LANGS_DISPLAY="${TESSERACT_LANGS_DISPLAY%, }"
    else
      TESSERACT_LANGS_DISPLAY="langues non détectées"
    fi

    for lang in "${langs[@]}"; do
      [[ "${lang}" == "eng" ]] && has_eng=true
      [[ "${lang}" == "fra" ]] && has_fra=true
    done

    if [[ "${has_eng}" == "true" && "${has_fra}" == "true" ]]; then
      TESSERACT_IMPACT="Binaire Tesseract prêt avec fra et eng."
    elif [[ "${has_fra}" == "true" ]]; then
      TESSERACT_STATUS="WARNING"
      TESSERACT_IMPACT="Binaire Tesseract prêt avec fra ; fallback eng absent."
    elif [[ "${has_eng}" == "true" ]]; then
      TESSERACT_STATUS="ERROR"
      TESSERACT_IMPACT="Tesseract détecté mais fra manque ; OCR français nominal indisponible."
    else
      TESSERACT_STATUS="ERROR"
      TESSERACT_IMPACT="Tesseract détecté sans fra ; OCR français indisponible."
    fi
  fi
}

OLLAMA_MODELS_DIR=$(detect_ollama_base)

ollama_manifest_path() {
  local name tag
  name=$(parse_model_name "$1")
  tag=$(parse_model_tag "$1")
  echo "${OLLAMA_MODELS_DIR}/manifests/registry.ollama.ai/library/${name}/${tag}"
}

digest_to_blob_path() {
  local hash="${1#sha256:}"
  echo "${OLLAMA_MODELS_DIR}/blobs/sha256-${hash}"
}

load_approved_registry() {
  if [[ -f "${APPROVED_REGISTRY}" ]]; then
    cat "${APPROVED_REGISTRY}"
  else
    jq -n '{schema_version:"2.0",approved_at:null,models:[]}'
  fi
}

save_approved_registry() {
  local registry_json="$1"
  mkdir -p "${REGISTRY_DIR}"
  printf '%s\n' "${registry_json}" > "${APPROVED_REGISTRY}"
}

get_approved_model_entry() {
  local registry_json="$1"
  local model="$2"
  echo "${registry_json}" | jq -c --arg model "${model}" '.models[]? | select(.name == $model)' | head -n 1
}

test_ollama_api() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if curl -sf --max-time 5 "${OLLAMA_HOST}/api/tags" >/dev/null; then
      info "API Ollama OK (tentative ${attempt})"
      return 0
    fi
    warn "API Ollama non disponible (tentative ${attempt}/5) - attente 3s..."
    sleep 3
  done
  return 1
}

get_model_fingerprint() {
  local model="$1"
  local manifest_path
  local manifest_sha
  local layers_json="[]"
  local status="intact"
  local note="null"
  local checked_at
  checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  manifest_path=$(ollama_manifest_path "${model}")
  if [[ ! -f "${manifest_path}" ]]; then
    jq -n \
      --arg name "${model}" \
      --arg manifest_path "${manifest_path}" \
      --arg checked_at "${checked_at}" \
      '{name:$name,manifest_path:$manifest_path,manifest_sha:null,layers:[],blob_count:0,status:"missing",note:"manifest introuvable",checked_at:$checked_at}'
    return
  fi

  if ! jq -e '.' "${manifest_path}" >/dev/null 2>&1; then
    jq -n \
      --arg name "${model}" \
      --arg manifest_path "${manifest_path}" \
      --arg checked_at "${checked_at}" \
      '{name:$name,manifest_path:$manifest_path,manifest_sha:null,layers:[],blob_count:0,status:"corrupt",note:"manifest JSON invalide",checked_at:$checked_at}'
    return
  fi

  manifest_sha=$(sha256sum "${manifest_path}" | awk '{print $1}')

  while IFS= read -r layer; do
    local digest hash blob_path computed size exists
    digest=$(echo "${layer}" | jq -r '.digest // empty')
    [[ -z "${digest}" ]] && continue
    hash="${digest#sha256:}"
    blob_path=$(digest_to_blob_path "${digest}")

    if [[ -f "${blob_path}" ]]; then
      computed=$(sha256sum "${blob_path}" | awk '{print $1}')
      size=$(stat -c '%s' "${blob_path}")
      exists=true
      if [[ "${computed}" != "${hash}" ]]; then
        status="corrupt"
      fi
    else
      computed=""
      size=0
      exists=false
      status="corrupt"
    fi

    layers_json=$(echo "${layers_json}" | jq \
      --arg digest "${digest}" \
      --arg path "${blob_path}" \
      --arg computed "${computed}" \
      --argjson exists "${exists}" \
      --argjson size "${size}" \
      '. + [{digest:$digest,path:$path,computed:(if ($computed | length) > 0 then $computed else null end),exists:$exists,size:$size}]')
  done < <(jq -c '.layers[]?' "${manifest_path}")

  if [[ "${status}" == "corrupt" ]]; then
    note='"integrité locale invalide"'
  fi

  layers_json=$(ensure_json_value "layers_json" "${layers_json}" '[]')
  note=$(ensure_json_value "note" "${note}" 'null')

  jq -n \
    --arg name "${model}" \
    --arg manifest_path "${manifest_path}" \
    --arg manifest_sha "${manifest_sha}" \
    --arg status "${status}" \
    --arg checked_at "${checked_at}" \
    --argjson layers "${layers_json}" \
    --argjson note "${note}" \
    '{name:$name,manifest_path:$manifest_path,manifest_sha:$manifest_sha,layers:$layers,blob_count:($layers|length),status:$status,note:$note,checked_at:$checked_at}'
}

get_local_model_snapshot() {
  local model="$1"
  local tags_json tag_json fingerprint_json
  local digest=""
  local digest_source="none"
  local modified_at=""
  local size=0
  local details="null"
  local exists=false

  tags_json=$(curl -sf --max-time 10 "${OLLAMA_HOST}/api/tags" 2>/dev/null || echo '{}')
  tag_json=$(echo "${tags_json}" | jq -c --arg model "${model}" '.models[]? | select(.name == $model)' | head -n 1)

  if [[ -n "${tag_json}" ]]; then
    digest=$(echo "${tag_json}" | jq -r '.digest // empty')
    modified_at=$(echo "${tag_json}" | jq -r '.modified_at // empty')
    size=$(echo "${tag_json}" | jq -r '.size // 0')
    details=$(echo "${tag_json}" | jq -c '.details // null')
    exists=true
    if [[ -n "${digest}" ]]; then
      digest_source="api_tags"
    fi
  fi

  fingerprint_json=$(get_model_fingerprint "${model}")
  if [[ -z "${digest}" ]]; then
    local manifest_sha
    manifest_sha=$(echo "${fingerprint_json}" | jq -r '.manifest_sha // empty')
    if [[ -n "${manifest_sha}" ]]; then
      digest="${manifest_sha}"
      digest_source="manifest_sha"
      exists=true
    fi
  fi

  size=$(ensure_json_value "size" "${size}" '0')
  details=$(ensure_json_value "details" "${details}" 'null')
  exists=$(ensure_json_value "exists" "${exists}" 'false')
  fingerprint_json=$(ensure_json_value "fingerprint_json" "${fingerprint_json}" 'null')

  jq -n \
    --arg model "${model}" \
    --arg digest "${digest}" \
    --arg digest_source "${digest_source}" \
    --arg modified_at "${modified_at}" \
    --argjson size "${size}" \
    --argjson details "${details}" \
    --argjson exists "${exists}" \
    --argjson fingerprint "${fingerprint_json}" \
    '{name:$model,exists:$exists,digest:(if ($digest | length) > 0 then $digest else null end),digest_source:$digest_source,modified_at:(if ($modified_at | length) > 0 then $modified_at else null end),size:$size,details:$details,fingerprint:$fingerprint}'
}

get_remote_model_digest() {
  local model="$1"

  if [[ "${CHECK_REMOTE_UPDATES}" != "true" ]]; then
    jq -n '{status:"skipped",digest:null,note:"option disabled"}'
    return
  fi

  if [[ -z "${OLLAMA_API_KEY:-}" ]]; then
    jq -n '{status:"skipped",digest:null,note:"OLLAMA_API_KEY absent"}'
    return
  fi

  local response
  if ! response=$(curl -sf --max-time 15 \
    -H "Authorization: Bearer ${OLLAMA_API_KEY}" \
    "https://ollama.com/api/tags" 2>/dev/null); then
    jq -n '{status:"failed",digest:null,note:"remote tags unreachable"}'
    return
  fi

  local digest
  digest=$(echo "${response}" | jq -r --arg model "${model}" '.models[]? | select(.name == $model) | .digest // empty' | head -n 1)
  if [[ -n "${digest}" ]]; then
    jq -n --arg digest "${digest}" '{status:"ok",digest:$digest,note:null}'
  else
    jq -n '{status:"failed",digest:null,note:"remote digest not found"}'
  fi
}

compare_trust_state() {
  local fingerprint_json="$1"
  local approved_entry_json="${2:-}"
  local fingerprint_status manifest_sha approved_sha

  fingerprint_status=$(echo "${fingerprint_json}" | jq -r '.status')
  if [[ "${fingerprint_status}" == "missing" ]]; then
    echo "missing"
    return
  fi
  if [[ "${fingerprint_status}" != "intact" ]]; then
    echo "quarantine"
    return
  fi
  if [[ -z "${approved_entry_json}" ]]; then
    echo "candidate"
    return
  fi

  manifest_sha=$(echo "${fingerprint_json}" | jq -r '.manifest_sha // empty')
  approved_sha=$(echo "${approved_entry_json}" | jq -r '.manifest_sha // empty')
  if [[ "${manifest_sha}" != "${approved_sha}" ]]; then
    echo "drifted"
    return
  fi

  local approved_digests current_digests
  approved_digests=$(echo "${approved_entry_json}" | jq -r '[.layers[]?.digest] | sort | join("|")')
  current_digests=$(echo "${fingerprint_json}" | jq -r '[.layers[]?.digest] | sort | join("|")')

  if [[ "${approved_digests}" == "${current_digests}" ]]; then
    echo "trusted"
  else
    echo "drifted"
  fi
}

approve_models() {
  local current_manifest_json="$1"
  local registry_json="$2"
  local approved_at
  approved_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  while IFS= read -r model_json; do
    [[ -z "${model_json}" ]] && continue
    local model_name trust_state
    model_name=$(echo "${model_json}" | jq -r '.name')
    trust_state=$(echo "${model_json}" | jq -r '.trust_state')

    if [[ "${trust_state}" != "candidate" && "${trust_state}" != "drifted" && "${trust_state}" != "trusted" ]]; then
      warn "Modèle non approuvable automatiquement : ${model_name} [${trust_state}]"
      continue
    fi

    local entry_json
    entry_json=$(echo "${model_json}" | jq -c \
      --arg approved_at "${approved_at}" \
      '{name,approved_at:$approved_at,manifest_sha,layers:[.layers[]? | {digest,size}]}')
    entry_json=$(ensure_json_value "entry_json" "${entry_json}" '{}')

    registry_json=$(echo "${registry_json}" | jq \
      --arg model "${model_name}" \
      --argjson entry "${entry_json}" \
      '.models = ((.models // []) | map(select(.name != $model)) + [$entry])')
    info "Modèle approuvé : ${model_name}"
  done < <(echo "${current_manifest_json}" | jq -c '.models[]?')

  echo "${registry_json}" | jq --arg approved_at "${approved_at}" '.schema_version = "2.0" | .approved_at = $approved_at'
}

mkdir -p "${LOG_DIR}" "${MANIFEST_DIR}" "${REGISTRY_DIR}" "${QUARANTINE_DIR}" "${TRUSTED_DIR}" "${HOME}/projets/llm-local-architecture"

step "ÉTAPE 0 — Initialisation"
info "Log : ${LOGFILE}"
info "Machine : ${HOSTNAME_VAL}"
info "Ollama host : ${OLLAMA_HOST}"
info "Répertoire Ollama détecté : ${OLLAMA_MODELS_DIR}"
update_python_status
info "Repo : ${REPO_DIR}"
info "check_by_pull=${CHECK_BY_PULL} auto_update=${AUTO_UPDATE} force_update=${FORCE_UPDATE} approve_candidates=${APPROVE_CANDIDATES} check_remote_updates=${CHECK_REMOTE_UPDATES} setup_python_env=${SETUP_PYTHON_ENV} launch_app=${LAUNCH_APP}"

step "ÉTAPE 1 — Vérification des prérequis"
command -v ollama >/dev/null 2>&1 || { error "ollama introuvable dans PATH."; exit 1; }
command -v jq >/dev/null 2>&1 || { error "jq introuvable dans PATH."; exit 1; }
command -v curl >/dev/null 2>&1 || { error "curl introuvable dans PATH."; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { error "sha256sum introuvable dans PATH."; exit 1; }

info "Version Ollama : $(ollama --version 2>/dev/null || echo 'inconnue')"
if ! test_ollama_api; then
  error "API Ollama inaccessible sur ${OLLAMA_HOST}"
  exit 1
fi

step "ÉTAPE 1B — Vérification OCR Tesseract"
check_tesseract_linux
if [[ "${TESSERACT_STATUS}" == "OK" || "${TESSERACT_STATUS}" == "WARNING" ]]; then
  info "Tesseract détecté : ${TESSERACT_PATH_DISPLAY}"
  info "Langues Tesseract : ${TESSERACT_LANGS_DISPLAY}"
else
  warn "Tesseract absent"
  warn "Les documents image / PDF scannés resteront indisponibles tant que Tesseract et la langue fra ne sont pas installés"
fi

step "ÉTAPE 2 — Installation / mise à jour contrôlée des modèles"

MODEL_RUNTIME_JSON='[]'

for model_spec in "${MODELS[@]}"; do
  IFS='|' read -r model_full role repo_hf _ _ <<< "${model_spec}"
  [[ -z "${model_full}" ]] && continue

  info "Traitement : ${model_full}"

  before_snapshot=$(get_local_model_snapshot "${model_full}")
  before_exists=$(echo "${before_snapshot}" | jq -r '.exists')
  before_digest=$(echo "${before_snapshot}" | jq -r '.digest // empty')
  remote_json=$(get_remote_model_digest "${model_full}")
  remote_status=$(echo "${remote_json}" | jq -r '.status')
  remote_digest=$(echo "${remote_json}" | jq -r '.digest // empty')
  remote_note=$(echo "${remote_json}" | jq -r '.note // empty')

  should_pull=false
  pull_reason="standard_check"

  if [[ "${before_exists}" != "true" ]]; then
    should_pull=true
    pull_reason="install_missing"
  elif [[ "${FORCE_UPDATE}" == "true" ]]; then
    should_pull=true
    pull_reason="force_update"
  elif [[ "${AUTO_UPDATE}" == "true" ]]; then
    should_pull=true
    pull_reason="auto_update"
  elif [[ "${CHECK_BY_PULL}" == "true" ]]; then
    should_pull=true
    pull_reason="check_by_pull"
  fi

  install_state="already_present"
  update_state="up_to_date"
  pull_performed=false
  pull_note=""

  if [[ "${CHECK_REMOTE_UPDATES}" == "true" ]]; then
    if [[ "${remote_status}" == "ok" ]]; then
      if [[ -n "${before_digest}" && "${before_digest}" != "${remote_digest}" ]]; then
        warn "  Digest distant différent pour ${model_full} (check distant uniquement)"
        if [[ "${should_pull}" != "true" ]]; then
          update_state="update_unknown"
        fi
      else
        info "  Check distant : pas de divergence détectée"
      fi
    else
      warn "  Check distant ignoré : ${remote_note:-status ${remote_status}}"
    fi
  fi

  after_snapshot="${before_snapshot}"

  if [[ "${should_pull}" == "true" ]]; then
    pull_performed=true
    if [[ "${before_exists}" == "true" ]]; then
      info "  Pull contrôlé : ${model_full} (${pull_reason})"
    else
      info "  Installation : ${model_full}"
    fi

    if retry ollama pull "${model_full}"; then
      after_snapshot=$(get_local_model_snapshot "${model_full}")
      after_exists=$(echo "${after_snapshot}" | jq -r '.exists')
      after_digest=$(echo "${after_snapshot}" | jq -r '.digest // empty')

      if [[ "${before_exists}" != "true" ]]; then
        install_state="installed"
        COUNT_INSTALLED=$((COUNT_INSTALLED + 1))
      fi

      if [[ "${after_exists}" != "true" || -z "${after_digest}" ]]; then
        update_state="update_unknown"
        pull_note="pull succeeded but current digest unavailable"
        warn "  Pull réussi mais digest courant introuvable"
      elif [[ "${before_exists}" != "true" ]]; then
        update_state="up_to_date"
        info "  Modèle installé : ${model_full}"
      elif [[ "${before_digest}" == "${after_digest}" ]]; then
        update_state="up_to_date"
        info "  Modèle inchangé : ${model_full}"
      else
        update_state="updated"
        COUNT_UPDATED=$((COUNT_UPDATED + 1))
        warn "  Mise à jour détectée : ${model_full}"
      fi
    else
      install_state="pull_failed"
      update_state="update_unknown"
      COUNT_PULL_FAILED=$((COUNT_PULL_FAILED + 1))
      pull_note="ollama pull failed"
      after_snapshot=$(get_local_model_snapshot "${model_full}")
      error "  Échec du pull : ${model_full}"
    fi
  else
    info "  Check standard : modèle conservé sans pull"
  fi

  pull_performed=$(ensure_json_value "pull_performed" "${pull_performed}" 'false')
  before_snapshot=$(ensure_json_value "before_snapshot" "${before_snapshot}" 'null')
  after_snapshot=$(ensure_json_value "after_snapshot" "${after_snapshot}" 'null')
  remote_json=$(ensure_json_value "remote_json" "${remote_json}" 'null')

  runtime_json=$(jq -n \
    --arg name "${model_full}" \
    --arg role "${role}" \
    --arg source_repo "https://huggingface.co/${repo_hf}" \
    --arg install_state "${install_state}" \
    --arg update_state "${update_state}" \
    --arg pull_reason "${pull_reason}" \
    --argjson pull_performed "${pull_performed}" \
    --arg pull_note "${pull_note}" \
    --argjson before "${before_snapshot}" \
    --argjson after "${after_snapshot}" \
    --argjson remote "${remote_json}" \
    '{name:$name,role:$role,source_repo:$source_repo,install_state:$install_state,update_state:$update_state,pull_reason:$pull_reason,pull_performed:$pull_performed,pull_note:(if ($pull_note | length) > 0 then $pull_note else null end),before:$before,after:$after,remote_check:$remote}')
  runtime_json=$(ensure_json_value "runtime_json" "${runtime_json}" '{}')
  MODEL_RUNTIME_JSON=$(echo "${MODEL_RUNTIME_JSON}" | jq --argjson item "${runtime_json}" '. + [$item]')
done

step "ÉTAPE 3 — Vérification d’intégrité et calcul de confiance"

approved_registry=$(load_approved_registry)
CURRENT_MODELS_JSON='[]'

for model_spec in "${MODELS[@]}"; do
  IFS='|' read -r model_full role repo_hf _ _ <<< "${model_spec}"
  [[ -z "${model_full}" ]] && continue

  runtime_json=$(echo "${MODEL_RUNTIME_JSON}" | jq -c --arg model "${model_full}" '.[] | select(.name == $model)' | head -n 1)
  after_snapshot=$(echo "${runtime_json}" | jq -c '.after')
  fingerprint_json=$(echo "${after_snapshot}" | jq -c '.fingerprint')
  approved_entry=$(get_approved_model_entry "${approved_registry}" "${model_full}")
  trust_state=$(compare_trust_state "${fingerprint_json}" "${approved_entry}")
  install_state=$(echo "${runtime_json}" | jq -r '.install_state')
  update_state=$(echo "${runtime_json}" | jq -r '.update_state')
  before_digest=$(echo "${runtime_json}" | jq -r '.before.digest // empty')
  current_digest=$(echo "${after_snapshot}" | jq -r '.digest // empty')
  digest_source=$(echo "${after_snapshot}" | jq -r '.digest_source')
  remote_digest=$(echo "${runtime_json}" | jq -r '.remote_check.digest // empty')

  if [[ "${trust_state}" == "trusted" ]]; then
    COUNT_TRUSTED=$((COUNT_TRUSTED + 1))
  elif [[ "${trust_state}" == "candidate" ]]; then
    COUNT_CANDIDATE=$((COUNT_CANDIDATE + 1))
  elif [[ "${trust_state}" == "drifted" ]]; then
    COUNT_DRIFTED=$((COUNT_DRIFTED + 1))
  elif [[ "${trust_state}" == "quarantine" ]]; then
    COUNT_QUARANTINE=$((COUNT_QUARANTINE + 1))
    echo "${model_full} — intégrité KO — ${DATE_ISO}" >> "${QUARANTINE_DIR}/quarantine.log"
  elif [[ "${trust_state}" == "missing" ]]; then
    COUNT_MISSING=$((COUNT_MISSING + 1))
  fi

  pull_performed_json=$(echo "${runtime_json}" | jq -c '.pull_performed')
  blob_count_json=$(echo "${fingerprint_json}" | jq -r '.blob_count')
  layers_json=$(echo "${fingerprint_json}" | jq -c '.layers')
  details_json=$(echo "${after_snapshot}" | jq -c '.details')

  pull_performed_json=$(ensure_json_value "pull_performed_json" "${pull_performed_json}" 'false')
  blob_count_json=$(ensure_json_value "blob_count_json" "${blob_count_json}" '0')
  layers_json=$(ensure_json_value "layers_json" "${layers_json}" '[]')
  details_json=$(ensure_json_value "details_json" "${details_json}" 'null')

  entry_json=$(jq -n \
    --arg name "${model_full}" \
    --arg role "${role}" \
    --arg source_repo "https://huggingface.co/${repo_hf}" \
    --arg install_state "${install_state}" \
    --arg trust_state "${trust_state}" \
    --arg update_state "${update_state}" \
    --arg status "${trust_state}" \
    --arg note "$(echo "${fingerprint_json}" | jq -r '.note // empty')" \
    --arg manifest_path "$(echo "${fingerprint_json}" | jq -r '.manifest_path')" \
    --arg manifest_sha "$(echo "${fingerprint_json}" | jq -r '.manifest_sha // empty')" \
    --arg local_digest "${current_digest}" \
    --arg local_digest_source "${digest_source}" \
    --arg previous_digest "${before_digest}" \
    --arg remote_digest "${remote_digest}" \
    --arg checked_at "$(echo "${fingerprint_json}" | jq -r '.checked_at')" \
    --arg pull_reason "$(echo "${runtime_json}" | jq -r '.pull_reason')" \
    --argjson pull_performed "${pull_performed_json}" \
    --arg pull_note "$(echo "${runtime_json}" | jq -r '.pull_note // empty')" \
    --argjson blob_count "${blob_count_json}" \
    --argjson layers "${layers_json}" \
    --argjson details "${details_json}" \
    '{
      name:$name,
      role:$role,
      source_repo:$source_repo,
      install_state:$install_state,
      trust_state:$trust_state,
      update_state:$update_state,
      status:$status,
      note:(if ($note | length) > 0 then $note else null end),
      manifest_path:$manifest_path,
      manifest_sha:(if ($manifest_sha | length) > 0 then $manifest_sha else null end),
      local_digest:(if ($local_digest | length) > 0 then $local_digest else null end),
      local_digest_source:$local_digest_source,
      previous_digest:(if ($previous_digest | length) > 0 then $previous_digest else null end),
      remote_digest:(if ($remote_digest | length) > 0 then $remote_digest else null end),
      checked_at:$checked_at,
      pull_reason:$pull_reason,
      pull_performed:$pull_performed,
      pull_note:(if ($pull_note | length) > 0 then $pull_note else null end),
      blob_count:$blob_count,
      layers:$layers,
      details:$details
    }')
  entry_json=$(ensure_json_value "entry_json" "${entry_json}" '{}')
  CURRENT_MODELS_JSON=$(echo "${CURRENT_MODELS_JSON}" | jq --argjson item "${entry_json}" '. + [$item]')

  if [[ "${install_state}" == "pull_failed" ]]; then
    error "  ${model_full} [${trust_state}] [${update_state}] [${install_state}]"
  elif [[ "${trust_state}" == "quarantine" || "${trust_state}" == "drifted" ]]; then
    warn "  ${model_full} [${trust_state}] [${update_state}] [${install_state}]"
  else
    info "  ${model_full} [${trust_state}] [${update_state}] [${install_state}]"
  fi
done

CHECK_BY_PULL_JSON=$(ensure_json_value "CHECK_BY_PULL" "${CHECK_BY_PULL}" 'false')
AUTO_UPDATE_JSON=$(ensure_json_value "AUTO_UPDATE" "${AUTO_UPDATE}" 'false')
FORCE_UPDATE_JSON=$(ensure_json_value "FORCE_UPDATE" "${FORCE_UPDATE}" 'false')
APPROVE_CANDIDATES_JSON=$(ensure_json_value "APPROVE_CANDIDATES" "${APPROVE_CANDIDATES}" 'false')
CHECK_REMOTE_UPDATES_JSON=$(ensure_json_value "CHECK_REMOTE_UPDATES" "${CHECK_REMOTE_UPDATES}" 'false')
CURRENT_MODELS_JSON=$(ensure_json_value "CURRENT_MODELS_JSON" "${CURRENT_MODELS_JSON}" '[]')

current_manifest=$(jq -n \
  --arg generated_at "${DATE_ISO}" \
  --arg host "${HOSTNAME_VAL}" \
  --arg ollama_models_dir "${OLLAMA_MODELS_DIR}" \
  --argjson check_by_pull "${CHECK_BY_PULL_JSON}" \
  --argjson auto_update "${AUTO_UPDATE_JSON}" \
  --argjson force_update "${FORCE_UPDATE_JSON}" \
  --argjson approve_candidates "${APPROVE_CANDIDATES_JSON}" \
  --argjson check_remote_updates "${CHECK_REMOTE_UPDATES_JSON}" \
  --argjson models "${CURRENT_MODELS_JSON}" \
  '{
    generated_at:$generated_at,
    host:$host,
    schema_version:"2.0",
    ollama_models_dir:$ollama_models_dir,
    options:{
      check_by_pull:$check_by_pull,
      auto_update:$auto_update,
      force_update:$force_update,
      approve_candidates:$approve_candidates,
      check_remote_updates:$check_remote_updates
    },
    models:$models
  }')
current_manifest=$(ensure_json_value "current_manifest" "${current_manifest}" '{}')

printf '%s\n' "${current_manifest}" > "${CURRENT_MANIFEST}"
info "Manifest écrit : ${CURRENT_MANIFEST}"

step "ÉTAPE 4 — Approbation explicite"
if [[ "${APPROVE_CANDIDATES}" == "true" ]]; then
  approved_registry=$(approve_models "${current_manifest}" "${approved_registry}")
  save_approved_registry "${approved_registry}"
  info "Registre approuvé mis à jour : ${APPROVED_REGISTRY}"
else
  warn "Aucune approbation automatique"
  warn "Relancer avec --approve-candidates après validation fonctionnelle"
fi

step "ÉTAPE 5 — Création de recheck.sh"

cat > "${RECHECK_SCRIPT}" <<'RECHECK_SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

LLMHOME="${HOME}/.llm-local"
MANIFEST_FILE="${LLMHOME}/manifests/current_manifest.json"
LOG_DATE=$(date +"%Y%m%d")
LOGFILE="${LLMHOME}/logs/integrity_${LOG_DATE}.log"
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log() { printf '[%s] [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" "$2" | tee -a "${LOGFILE}"; }
info() { log "INFO " "$1"; }
warn() { log "WARN " "$1"; }
error() { log "ERROR" "$1"; }

[[ -f "${MANIFEST_FILE}" ]] || { error "Manifest introuvable. Lancer bootstrap.sh."; exit 1; }

OLLAMA_MODELS_DIR=$(jq -r '.ollama_models_dir // empty' "${MANIFEST_FILE}")
if [[ -z "${OLLAMA_MODELS_DIR}" ]]; then
  OLLAMA_MODELS_DIR="${HOME}/.ollama/models"
  warn "ollama_models_dir absent du manifest — fallback : ${OLLAMA_MODELS_DIR}"
fi

COUNT_OK=0
COUNT_DRIFT=0
DRIFT_FOUND=false
model_count=$(jq '.models | length' "${MANIFEST_FILE}")

for i in $(seq 0 $((model_count - 1))); do
  model_name=$(jq -r ".models[${i}].name" "${MANIFEST_FILE}")
  trust_state=$(jq -r ".models[${i}].trust_state // .models[${i}].status" "${MANIFEST_FILE}")
  [[ "${trust_state}" == "missing" ]] && { warn "SKIP missing : ${model_name}"; continue; }

  info "Vérification : ${model_name}"
  blob_count=$(jq ".models[${i}].layers | length" "${MANIFEST_FILE}")
  model_ok=true

  for j in $(seq 0 $((blob_count - 1))); do
    digest=$(jq -r ".models[${i}].layers[${j}].digest" "${MANIFEST_FILE}")
    stored_path=$(jq -r ".models[${i}].layers[${j}].path" "${MANIFEST_FILE}")
    [[ -z "${digest}" || "${digest}" == "null" ]] && continue

    blob_hash="${digest#sha256:}"
    blob_path="${OLLAMA_MODELS_DIR}/blobs/sha256-${blob_hash}"
    [[ ! -f "${blob_path}" && -f "${stored_path}" ]] && blob_path="${stored_path}"

    if [[ ! -f "${blob_path}" ]]; then
      error "  BLOB DISPARU : ${blob_path}"
      model_ok=false
      continue
    fi

    current_hash=$(sha256sum "${blob_path}" | awk '{print $1}')
    if [[ "${current_hash}" != "${blob_hash}" ]]; then
      error "  DRIFT : ${model_name} — ${blob_path}"
      model_ok=false
      DRIFT_FOUND=true
    fi
  done

  tmp_manifest=$(mktemp)
  if [[ "${model_ok}" == "false" ]]; then
    jq --argjson idx "${i}" --arg ts "${DATE_ISO}" \
      '.models[$idx].trust_state="quarantine" | .models[$idx].status="quarantine" | .models[$idx].last_checked=$ts | .models[$idx].quarantine_reason="drift recheck"' \
      "${MANIFEST_FILE}" > "${tmp_manifest}"
    mv "${tmp_manifest}" "${MANIFEST_FILE}"
    error "  → QUARANTINE : ${model_name}"
    COUNT_DRIFT=$((COUNT_DRIFT + 1))
  else
    jq --argjson idx "${i}" --arg ts "${DATE_ISO}" \
      '.models[$idx].last_checked=$ts' "${MANIFEST_FILE}" > "${tmp_manifest}"
    mv "${tmp_manifest}" "${MANIFEST_FILE}"
    info "  → OK"
    COUNT_OK=$((COUNT_OK + 1))
  fi
done

info "Terminé. OK=${COUNT_OK} DRIFT=${COUNT_DRIFT}"
[[ "${DRIFT_FOUND}" == "true" ]] && exit 1
exit 0
RECHECK_SCRIPT_EOF

chmod +x "${RECHECK_SCRIPT}"
info "recheck.sh créé : ${RECHECK_SCRIPT}"

step "ÉTAPE 6 — Installation du cron quotidien (07h00)"
CRON_LINE="0 7 * * * ${RECHECK_SCRIPT} >> ${LLMHOME}/logs/cron.log 2>&1"
(crontab -l 2>/dev/null | grep -v "recheck.sh" || true; echo "${CRON_LINE}") | crontab -
if crontab -l 2>/dev/null | grep -qF "${RECHECK_SCRIPT}"; then
  info "Cron OK"
else
  warn "Cron non trouvé — vérifier : crontab -l"
fi

if [[ "${SETUP_PYTHON_ENV}" == "true" ]]; then
  setup_python_env
else
  update_python_status
fi

step "ÉTAPE 7 — Validation OCR runtime"
if validate_ocr_linux; then
  if [[ "${OCR_OVERALL_STATUS}" == "WARNING" ]]; then
    warn "OCR exploitable avec limitation : ${TESSERACT_IMPACT}"
  else
    info "OCR exploitable : chaîne locale validée"
  fi
else
  error "OCR non exploitable : ${OCR_FAILURE_REASON}"
fi

step "ÉTAPE 8 — Rapport final"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           BOOTSTRAP LLM LOCAL — RAPPORT FINAL           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Répertoire Ollama : ${OLLAMA_MODELS_DIR}"
echo "  Manifest          : ${CURRENT_MANIFEST}"
echo "  Registre approuvé : ${APPROVED_REGISTRY}"
echo "  Log               : ${LOGFILE}"
echo ""
echo "  OCR :"
echo "    Tesseract : ${TESSERACT_STATUS}"
echo "    Chemin    : ${TESSERACT_PATH_DISPLAY}"
echo "    Langues   : ${TESSERACT_LANGS_DISPLAY}"
echo "    Imports   : ${OCR_PYTHON_MODULES_STATUS}"
echo "    Runtime   : ${OCR_RUNTIME_STATUS}"
echo "    Test OCR  : ${OCR_FUNCTIONAL_TEST_STATUS}"
echo "    Statut    : ${OCR_OVERALL_STATUS}"
echo "    Impact    : ${TESSERACT_IMPACT}"
if [[ -n "${OCR_FAILURE_REASON}" ]]; then
  echo "    Diagnostic: ${OCR_FAILURE_REASON}"
fi
echo ""
echo "  Python :"
echo "    Virtualenv       : ${PYTHON_VENV_STATUS}"
echo "    Dépendances      : ${PYTHON_DEPS_STATUS}"
echo "    Python du venv   : ${VENV_PYTHON}"
echo "    FastAPI locale   : ${APP_URL}"
echo ""
echo "  Options :"
echo "    --check-by-pull      ${CHECK_BY_PULL}"
echo "    --auto-update        ${AUTO_UPDATE}"
echo "    --force-update       ${FORCE_UPDATE}"
echo "    --approve-candidates ${APPROVE_CANDIDATES}"
echo "    --check-remote-updates ${CHECK_REMOTE_UPDATES}"
echo "    --setup-python-env  ${SETUP_PYTHON_ENV}"
echo "    --launch-app        ${LAUNCH_APP}"
echo ""
echo "  Résumé :"
echo "    trusted     : ${COUNT_TRUSTED}"
echo "    candidate   : ${COUNT_CANDIDATE}"
echo "    drifted     : ${COUNT_DRIFTED}"
echo "    quarantine  : ${COUNT_QUARANTINE}"
echo "    missing     : ${COUNT_MISSING}"
echo "    pull_failed : ${COUNT_PULL_FAILED}"
echo "    installed   : ${COUNT_INSTALLED}"
echo "    updated     : ${COUNT_UPDATED}"
echo ""
echo "  Usage principal :"
echo "    FastAPI locale : ${APP_URL}"
echo "    Open WebUI     : optionnel"
echo ""

if [[ "${LAUNCH_APP}" == "true" ]]; then
  launch_app
fi
echo "  États par modèle :"
while IFS= read -r model_json; do
  [[ -z "${model_json}" ]] && continue
  name=$(echo "${model_json}" | jq -r '.name')
  trust_state=$(echo "${model_json}" | jq -r '.trust_state')
  update_state=$(echo "${model_json}" | jq -r '.update_state')
  install_state=$(echo "${model_json}" | jq -r '.install_state')
  echo "    -> ${name} [${trust_state}] [${update_state}] [${install_state}]"
done < <(echo "${current_manifest}" | jq -c '.models[]')
echo ""
echo "  API Ollama : ${OLLAMA_HOST}"
echo "  Recheck    : ${RECHECK_SCRIPT}"
echo ""

if [[ "${OCR_OVERALL_STATUS}" == "ERROR" ]]; then
  error "Bootstrap terminé avec échec OCR"
  exit 1
fi

info "Bootstrap terminé. trusted=${COUNT_TRUSTED} candidate=${COUNT_CANDIDATE} drifted=${COUNT_DRIFTED} quarantine=${COUNT_QUARANTINE} ocr=${OCR_OVERALL_STATUS}"
exit 0
