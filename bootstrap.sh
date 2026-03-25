#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Déploiement et vérification du batch LLM local
# Machine : UbuntuDevStation / RTX 5060 8GB / Ubuntu 24.04
# Dépendances : ollama, jq, curl, sha256sum, python3 (tous présents Ubuntu 24.04)
# Usage : bash bootstrap.sh
# Idempotent : ré-exécutable sans effets de bord
# v1.2 — fix détection automatique répertoire Ollama (systemd vs user),
#         tags corrigés granite3.3:8b et phi4-mini:3.8b
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
LLMHOME="${HOME}/.llm-local"
LOG_DIR="${LLMHOME}/logs"
MANIFEST_DIR="${LLMHOME}/manifests"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.json"
RECHECK_SCRIPT="${LLMHOME}/recheck.sh"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
mkdir -p "${LOG_DIR}"
LOGFILE="${LOG_DIR}/bootstrap_${TIMESTAMP}.log"
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME_VAL="UbuntuDevStation"

# ---------------------------------------------------------------------------
# DÉTECTION AUTOMATIQUE DU RÉPERTOIRE OLLAMA
# Ollama peut stocker ses modèles dans différents emplacements selon
# le mode d'installation (user vs systemd service).
# Priorité : OLLAMA_MODELS env > /usr/share/ollama/.ollama > ~/.ollama
# ---------------------------------------------------------------------------
detect_ollama_base() {
  if [[ -n "${OLLAMA_MODELS:-}" ]] && [[ -d "${OLLAMA_MODELS}" ]]; then
    echo "${OLLAMA_MODELS}"
    return
  fi
  if [[ -d "/usr/share/ollama/.ollama/models" ]]; then
    echo "/usr/share/ollama/.ollama/models"
    return
  fi
  if [[ -d "${HOME}/.ollama/models" ]]; then
    echo "${HOME}/.ollama/models"
    return
  fi
  echo "${HOME}/.ollama/models"
}

OLLAMA_MODELS_DIR=$(detect_ollama_base)

# Batch de modèles : nom_ollama|role|repo_hf|gguf_hf_owner|gguf_hf_repo
# v1.2 : tags corrigés granite3.3:8b et phi4-mini:3.8b
MODELS=(
  "qwen2.5-coder:7b-instruct-q4_K_M|code|Qwen/Qwen2.5-Coder-7B-Instruct|bartowski|Qwen2.5-Coder-7B-Instruct-GGUF"
  "granite3.3:8b|audit|ibm-granite/granite-3.3-8b-instruct|lmstudio-community|granite-3.3-8b-instruct-GGUF"
  "deepseek-r1:7b|agent|deepseek-ai/DeepSeek-R1-Distill-Qwen-7B|bartowski|DeepSeek-R1-Distill-Qwen-7B-GGUF"
  "phi4-mini:3.8b|debug|microsoft/Phi-4-mini-instruct|bartowski|Phi-4-mini-instruct-GGUF"
  "mistral:7b-instruct-v0.3-q4_K_M|redaction|mistralai/Mistral-7B-Instruct-v0.3|TheBloke|Mistral-7B-Instruct-v0.3-GGUF"
)

COUNT_TRUSTED=0
COUNT_UNVERIFIED=0
COUNT_QUARANTINE=0

# ---------------------------------------------------------------------------
# FONCTIONS UTILITAIRES
# ---------------------------------------------------------------------------
log() {
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOGFILE}"
}

info()  { log "INFO " "$1"; }
warn()  { log "WARN " "$1"; }
error() { log "ERROR" "$1"; }
step()  {
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

parse_model_name() { echo "${1%%:*}"; }

parse_model_tag() {
  local full="$1"
  if [[ "$full" == *":"* ]]; then echo "${full#*:}"; else echo "latest"; fi
}

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

# ---------------------------------------------------------------------------
# ÉTAPE 1 — STRUCTURE DE RÉPERTOIRES
# ---------------------------------------------------------------------------
step "ÉTAPE 1 — Création de la structure de répertoires"

mkdir -p "${LLMHOME}/manifests" "${LLMHOME}/checksums" "${LLMHOME}/quarantine" \
         "${LLMHOME}/trusted" "${LLMHOME}/logs" "${HOME}/projets/llm-local-architecture"

info "Bootstrap démarré — log : ${LOGFILE}"
info "Machine : ${HOSTNAME_VAL}"
info "Modèles à traiter : ${#MODELS[@]}"
info "Répertoire Ollama détecté : ${OLLAMA_MODELS_DIR}"

# ---------------------------------------------------------------------------
# ÉTAPE 2 — TÉLÉCHARGEMENT DES MODÈLES
# ---------------------------------------------------------------------------
step "ÉTAPE 2 — Téléchargement des modèles via ollama pull"

if ! command -v ollama &>/dev/null; then
  error "ollama non trouvé dans PATH. Installer depuis https://ollama.ai"
  exit 1
fi

info "Version Ollama : $(ollama --version 2>/dev/null || echo 'inconnue')"

for model_spec in "${MODELS[@]}"; do
  model_full="${model_spec%%|*}"
  [[ -z "${model_full}" ]] && { warn "model_spec vide, skip"; continue; }

  model_name=$(parse_model_name "${model_full}")
  model_tag=$(parse_model_tag "${model_full}")

  if ollama list 2>/dev/null | grep -qF "${model_name}:${model_tag}"; then
    info "Pull : ${model_full} (déjà présent)"
  else
    info "Pull : ${model_full} (nouveau téléchargement)"
  fi

  if ! retry ollama pull "${model_full}"; then
    error "Échec du pull pour ${model_full} — modèle ignoré"
    continue
  fi
  info "  → Pull réussi : ${model_full}"
done

# Après les pulls, re-détecter le répertoire Ollama (peut avoir été créé)
OLLAMA_MODELS_DIR=$(detect_ollama_base)
info "Répertoire Ollama après pulls : ${OLLAMA_MODELS_DIR}"

# ---------------------------------------------------------------------------
# ÉTAPE 3 — VÉRIFICATION D'INTÉGRITÉ PAR MODÈLE
# ---------------------------------------------------------------------------
step "ÉTAPE 3 — Vérification d'intégrité des blobs"

MODELS_JSON="[]"

for model_spec in "${MODELS[@]}"; do
  [[ -z "${model_spec}" ]] && continue

  IFS='|' read -r model_full role repo_hf hf_owner hf_repo <<< "${model_spec}"
  [[ -z "${model_full}" ]] && { warn "Entrée malformée, skip : ${model_spec}"; continue; }

  model_name=$(parse_model_name "${model_full}")
  model_tag=$(parse_model_tag "${model_full}")
  manifest_path=$(ollama_manifest_path "${model_full}")
  pulled_at="${DATE_ISO}"

  info "Vérification : ${model_full}"

  # Recherche du manifest dans tous les emplacements connus si introuvable
  if [[ ! -f "${manifest_path}" ]]; then
    found=false
    for search_base in "/usr/share/ollama/.ollama/models" "${HOME}/.ollama/models" "/var/lib/ollama/models"; do
      candidate="${search_base}/manifests/registry.ollama.ai/library/${model_name}/${model_tag}"
      if [[ -f "${candidate}" ]]; then
        manifest_path="${candidate}"
        OLLAMA_MODELS_DIR="${search_base}"
        info "  Manifest trouvé (chemin alternatif) : ${manifest_path}"
        found=true
        break
      fi
    done

    if [[ "${found}" == "false" ]]; then
      warn "  Manifest introuvable dans tous les chemins connus → quarantine"
      COUNT_QUARANTINE=$((COUNT_QUARANTINE + 1))
      echo "${model_full} — manifest introuvable — ${DATE_ISO}" >> "${LLMHOME}/quarantine/quarantine.log"
      model_json=$(jq -n \
        --arg name "${model_full}" --arg role "${role}" \
        --arg source "https://huggingface.co/${repo_hf}" \
        --arg manifest_path "${manifest_path}" \
        --arg ollama_models_dir "${OLLAMA_MODELS_DIR}" \
        --arg status "quarantine" --arg pulled_at "${pulled_at}" \
        --arg last_checked "${DATE_ISO}" \
        '{name:$name,role:$role,source_repo:$source,ollama_manifest_path:$manifest_path,
          ollama_models_dir:$ollama_models_dir,blobs:[],sha256_hf_official:"unavailable",
          hf_match:"unverified",status:$status,pulled_at:$pulled_at,last_checked:$last_checked,
          note:"manifest Ollama introuvable après pull"}')
      MODELS_JSON=$(echo "${MODELS_JSON}" | jq --argjson m "${model_json}" '. + [$m]')
      continue
    fi
  else
    info "  Manifest trouvé : ${manifest_path}"
  fi

  # --- Vérification locale des blobs ---
  BLOBS_JSON="[]"
  LOCAL_INTEGRITY="ok"
  LARGEST_BLOB_HASH=""
  LARGEST_BLOB_SIZE=0

  if ! jq -e '.layers' "${manifest_path}" &>/dev/null; then
    warn "  Manifest JSON invalide → quarantine"
    LOCAL_INTEGRITY="fail"
  else
    while IFS= read -r layer; do
      digest=$(echo "${layer}" | jq -r '.digest // empty')
      media_type=$(echo "${layer}" | jq -r '.mediaType // "unknown"')
      layer_size_raw=$(echo "${layer}" | jq -r '.size // 0')
      layer_size=$([[ "${layer_size_raw}" =~ ^[0-9]+$ ]] && echo "${layer_size_raw}" || echo "0")

      [[ -z "${digest}" ]] && { warn "    Layer sans digest, skip"; continue; }

      blob_path=$(digest_to_blob_path "${digest}")
      hash_only="${digest#sha256:}"

      if [[ ! -f "${blob_path}" ]]; then
        warn "    Blob introuvable : ${blob_path}"
        LOCAL_INTEGRITY="fail"
        blob_json=$(jq -n --arg d "${digest}" --arg p "${blob_path}" --arg m "${media_type}" \
          '{digest:$d,blob_path:$p,sha256_recalculated:"blob_missing",integrity_local:"fail",media_type:$m}')
        BLOBS_JSON=$(echo "${BLOBS_JSON}" | jq --argjson b "${blob_json}" '. + [$b]')
        continue
      fi

      computed_hash=$(sha256sum "${blob_path}" | awk '{print $1}')
      if [[ "${computed_hash}" == "${hash_only}" ]]; then
        integrity_local="ok"
        info "    Blob OK : ${hash_only:0:12}... (${media_type})"
      else
        integrity_local="fail"
        LOCAL_INTEGRITY="fail"
        warn "    DRIFT : attendu=${hash_only:0:12} calculé=${computed_hash:0:12}"
      fi

      if (( layer_size > LARGEST_BLOB_SIZE )) && [[ "${media_type}" == *"model"* ]]; then
        LARGEST_BLOB_SIZE="${layer_size}"
        LARGEST_BLOB_HASH="${computed_hash}"
      fi

      blob_json=$(jq -n --arg d "${digest}" --arg p "${blob_path}" \
        --arg h "${computed_hash}" --arg i "${integrity_local}" --arg m "${media_type}" \
        '{digest:$d,blob_path:$p,sha256_recalculated:$h,integrity_local:$i,media_type:$m}')
      BLOBS_JSON=$(echo "${BLOBS_JSON}" | jq --argjson b "${blob_json}" '. + [$b]')

    done < <(jq -c '.layers[]' "${manifest_path}" 2>/dev/null)
  fi

  # Config layer
  config_digest=$(jq -r '.config.digest // empty' "${manifest_path}" 2>/dev/null || true)
  if [[ -n "${config_digest}" ]]; then
    config_blob=$(digest_to_blob_path "${config_digest}")
    config_hash="${config_digest#sha256:}"
    if [[ -f "${config_blob}" ]]; then
      computed_config=$(sha256sum "${config_blob}" | awk '{print $1}')
      [[ "${computed_config}" != "${config_hash}" ]] && { warn "  Config blob drift"; LOCAL_INTEGRITY="fail"; }
    fi
  fi

  # Vérification HuggingFace
  HF_SHA="unavailable"
  HF_MATCH="unverified"

  if [[ -n "${LARGEST_BLOB_HASH}" ]]; then
    info "  Interrogation HuggingFace : ${hf_owner}/${hf_repo}"
    hf_response=$(curl -sf --max-time 15 \
      "https://huggingface.co/api/models/${hf_owner}/${hf_repo}/tree/main" 2>/dev/null || echo "[]")
    hf_gguf_sha=$(echo "${hf_response}" | jq -r \
      '[.[] | select(.path | test("Q4_K_M.*\\.gguf$";"i"))] | .[0].lfs.sha256 // empty' 2>/dev/null || echo "")

    if [[ -n "${hf_gguf_sha}" ]]; then
      HF_SHA="${hf_gguf_sha}"
      if [[ "${LARGEST_BLOB_HASH}" == "${hf_gguf_sha}" ]]; then
        HF_MATCH="confirmed"; info "  HF SHA : confirmé"
      else
        HF_MATCH="unverified"
        info "  HF SHA : divergence attendue (Ollama rebuild ≠ GGUF HF)"
      fi
    else
      info "  HF API : GGUF Q4_K_M non trouvé"
    fi
  fi

  # Statut final
  if [[ "${LOCAL_INTEGRITY}" == "fail" ]]; then
    model_status="quarantine"; COUNT_QUARANTINE=$((COUNT_QUARANTINE + 1))
    error "  QUARANTINE : ${model_full}"
    echo "${model_full} — intégrité KO — ${DATE_ISO}" >> "${LLMHOME}/quarantine/quarantine.log"
  elif [[ "${HF_MATCH}" == "confirmed" ]]; then
    model_status="trusted"; COUNT_TRUSTED=$((COUNT_TRUSTED + 1))
    info "  STATUS : trusted"
  else
    model_status="unverified"; COUNT_UNVERIFIED=$((COUNT_UNVERIFIED + 1))
    info "  STATUS : unverified (intégrité locale OK — comportement normal Ollama)"
    echo "${model_full}|${LARGEST_BLOB_HASH}|${DATE_ISO}" >> "${LLMHOME}/trusted/trusted_blobs.log"
  fi

  model_json=$(jq -n \
    --arg name "${model_full}" --arg role "${role}" \
    --arg source "https://huggingface.co/${repo_hf}" \
    --arg manifest_path "${manifest_path}" \
    --arg ollama_models_dir "${OLLAMA_MODELS_DIR}" \
    --argjson blobs "${BLOBS_JSON}" \
    --arg sha256_hf "${HF_SHA}" --arg hf_match "${HF_MATCH}" \
    --arg status "${model_status}" --arg pulled_at "${pulled_at}" \
    --arg last_checked "${DATE_ISO}" \
    '{name:$name,role:$role,source_repo:$source,ollama_manifest_path:$manifest_path,
      ollama_models_dir:$ollama_models_dir,blobs:$blobs,sha256_hf_official:$sha256_hf,
      hf_match:$hf_match,status:$status,pulled_at:$pulled_at,last_checked:$last_checked,
      note:"Intégrité locale (blob name == sha256sum) est la vérification primaire."}')
  MODELS_JSON=$(echo "${MODELS_JSON}" | jq --argjson m "${model_json}" '. + [$m]')
done

# ---------------------------------------------------------------------------
# ÉTAPE 4 — GÉNÉRATION DU MANIFEST
# ---------------------------------------------------------------------------
step "ÉTAPE 4 — Génération du manifest"

jq -n \
  --arg generated_at "${DATE_ISO}" --arg host "${HOSTNAME_VAL}" \
  --arg ollama_models_dir "${OLLAMA_MODELS_DIR}" \
  --argjson models "${MODELS_JSON}" \
  '{generated_at:$generated_at,host:$host,schema_version:"1.2",
    ollama_models_dir:$ollama_models_dir,models:$models}' > "${MANIFEST_FILE}"

info "Manifest écrit : ${MANIFEST_FILE} ($(wc -c < "${MANIFEST_FILE}") bytes)"

# ---------------------------------------------------------------------------
# ÉTAPE 5 — CRÉATION DU SCRIPT DE RECHECK QUOTIDIEN
# ---------------------------------------------------------------------------
step "ÉTAPE 5 — Création de recheck.sh"

cat > "${RECHECK_SCRIPT}" << 'RECHECK_SCRIPT_EOF'
#!/usr/bin/env bash
# recheck.sh — Vérification quotidienne d'intégrité des modèles LLM
# v1.2 — lit ollama_models_dir depuis le manifest, trap tmpfiles
set -euo pipefail

LLMHOME="${HOME}/.llm-local"
MANIFEST_FILE="${LLMHOME}/manifests/manifest.json"
LOG_DATE=$(date +"%Y%m%d")
LOGFILE="${LLMHOME}/logs/integrity_${LOG_DATE}.log"
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT INT TERM

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [$1] $2" | tee -a "${LOGFILE}"; }
info() { log "INFO " "$1"; }
warn() { log "WARN " "$1"; }
error() { log "ERROR" "$1"; }

[[ ! -f "${MANIFEST_FILE}" ]] && { error "Manifest introuvable. Lancer bootstrap.sh."; exit 1; }

# Lire le répertoire Ollama depuis le manifest
OLLAMA_MODELS_DIR=$(jq -r '.ollama_models_dir // empty' "${MANIFEST_FILE}" 2>/dev/null || echo "")
if [[ -z "${OLLAMA_MODELS_DIR}" ]]; then
  if [[ -d "/usr/share/ollama/.ollama/models" ]]; then
    OLLAMA_MODELS_DIR="/usr/share/ollama/.ollama/models"
  else
    OLLAMA_MODELS_DIR="${HOME}/.ollama/models"
  fi
  warn "ollama_models_dir absent du manifest — auto : ${OLLAMA_MODELS_DIR}"
fi

info "=== Recheck intégrité ==="
info "Ollama models : ${OLLAMA_MODELS_DIR}"

COUNT_OK=0; COUNT_DRIFT=0; DRIFT_FOUND=false
model_count=$(jq '.models | length' "${MANIFEST_FILE}")
info "Modèles : ${model_count}"

for i in $(seq 0 $((model_count - 1))); do
  model_name=$(jq -r ".models[${i}].name" "${MANIFEST_FILE}")
  model_status=$(jq -r ".models[${i}].status" "${MANIFEST_FILE}")

  [[ "${model_status}" == "quarantine" ]] && { warn "  SKIP quarantine : ${model_name}"; continue; }

  info "Vérification : ${model_name}"
  blob_count=$(jq ".models[${i}].blobs | length" "${MANIFEST_FILE}")
  model_ok=true

  for j in $(seq 0 $((blob_count - 1))); do
    stored_blob_path=$(jq -r ".models[${i}].blobs[${j}].blob_path" "${MANIFEST_FILE}")
    expected_hash=$(jq -r ".models[${i}].blobs[${j}].sha256_recalculated" "${MANIFEST_FILE}")
    stored_integrity=$(jq -r ".models[${i}].blobs[${j}].integrity_local" "${MANIFEST_FILE}")

    [[ "${stored_integrity}" == "fail" || "${expected_hash}" == "blob_missing" ]] && continue

    # Reconstruire le chemin blob avec le bon répertoire Ollama
    blob_hash=$(basename "${stored_blob_path}" | sed 's/^sha256-//')
    blob_path="${OLLAMA_MODELS_DIR}/blobs/sha256-${blob_hash}"
    [[ ! -f "${blob_path}" && -f "${stored_blob_path}" ]] && blob_path="${stored_blob_path}"

    if [[ ! -f "${blob_path}" ]]; then
      error "  BLOB DISPARU : ${blob_path}"; model_ok=false; continue
    fi

    current_hash=$(sha256sum "${blob_path}" | awk '{print $1}')
    if [[ "${current_hash}" != "${expected_hash}" ]]; then
      error "  DRIFT : ${model_name} — ${blob_path}"
      model_ok=false; DRIFT_FOUND=true
    fi
  done

  tmp_manifest=$(mktemp); TMPFILES+=("${tmp_manifest}")
  if [[ "${model_ok}" == "false" ]]; then
    jq --argjson idx "${i}" --arg ts "${DATE_ISO}" \
      '.models[$idx].status="quarantine"|.models[$idx].last_checked=$ts|.models[$idx].quarantine_reason="drift recheck"' \
      "${MANIFEST_FILE}" > "${tmp_manifest}"
    error "  → QUARANTINE : ${model_name}"; COUNT_DRIFT=$((COUNT_DRIFT + 1))
  else
    jq --argjson idx "${i}" --arg ts "${DATE_ISO}" \
      '.models[$idx].last_checked=$ts' "${MANIFEST_FILE}" > "${tmp_manifest}"
    info "  → OK"; COUNT_OK=$((COUNT_OK + 1))
  fi
  mv "${tmp_manifest}" "${MANIFEST_FILE}"; unset 'TMPFILES[-1]'
done

echo ""
echo "══════════════════════════════════"
echo "  ✅ OK : ${COUNT_OK}   ❌ Drift : ${COUNT_DRIFT}"
echo "══════════════════════════════════"
info "Terminé. OK=${COUNT_OK} DRIFT=${COUNT_DRIFT}"

[[ "${DRIFT_FOUND}" == "true" ]] && { error "ALERTE : dérive détectée"; exit 1; }
exit 0
RECHECK_SCRIPT_EOF

chmod +x "${RECHECK_SCRIPT}"
info "recheck.sh créé : ${RECHECK_SCRIPT}"

# ---------------------------------------------------------------------------
# ÉTAPE 6 — CRON
# ---------------------------------------------------------------------------
step "ÉTAPE 6 — Installation du cron quotidien (07h00)"

CRON_LINE="0 7 * * * ${RECHECK_SCRIPT} >> ${LLMHOME}/logs/cron.log 2>&1"
(crontab -l 2>/dev/null | grep -v "recheck" || true; echo "${CRON_LINE}") | crontab -

if crontab -l 2>/dev/null | grep -qF "${RECHECK_SCRIPT}"; then
  info "Cron OK"
else
  warn "Cron non trouvé — vérifier : crontab -l"
fi

# ---------------------------------------------------------------------------
# ÉTAPE 7 — RAPPORT FINAL
# ---------------------------------------------------------------------------
step "ÉTAPE 7 — Rapport final"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           BOOTSTRAP LLM LOCAL — RAPPORT FINAL           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Répertoire Ollama : ${OLLAMA_MODELS_DIR}"
echo ""
echo "  ✅ Modèles trusted    : ${COUNT_TRUSTED}"
echo "  ⚠️  Modèles unverified : ${COUNT_UNVERIFIED}"
echo "  ❌ Modèles quarantine : ${COUNT_QUARANTINE}"
echo ""
echo "  📄 Manifest : ${MANIFEST_FILE}"
echo "  📋 Log      : ${LOGFILE}"
echo "  🔁 Recheck  : ${RECHECK_SCRIPT}"
echo "  🕐 Prochain recheck : demain 07h00"
echo ""

[[ "${COUNT_QUARANTINE}" -gt 0 ]] && \
  echo "  ⚠️  ${COUNT_QUARANTINE} modèle(s) en quarantaine — voir : ${LLMHOME}/quarantine/quarantine.log"

echo ""
echo "  NOTE : 'unverified' est normal pour Ollama (SHA blob ≠ SHA GGUF HF)."
echo ""

info "Bootstrap terminé. trusted=${COUNT_TRUSTED} unverified=${COUNT_UNVERIFIED} quarantine=${COUNT_QUARANTINE}"
info "OLLAMA_MODELS_DIR=${OLLAMA_MODELS_DIR}"

[[ "${COUNT_QUARANTINE}" -gt 0 ]] && exit 1
exit 0
