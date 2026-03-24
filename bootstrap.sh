#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Déploiement et vérification du batch LLM local
# Machine : UbuntuDevStation / RTX 5060 8GB / Ubuntu 24.04
# Dépendances : ollama, jq, curl, sha256sum, python3 (tous présents Ubuntu 24.04)
# Usage : bash bootstrap.sh
# Idempotent : ré-exécutable sans effets de bord
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
LOGFILE="${LOG_DIR}/bootstrap_${TIMESTAMP}.log"
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME_VAL="UbuntuDevStation"

# Batch de modèles : nom_ollama|role|repo_hf|gguf_hf_owner|gguf_hf_repo
MODELS=(
  "qwen2.5-coder:7b-instruct-q4_K_M|code|Qwen/Qwen2.5-Coder-7B-Instruct|bartowski|Qwen2.5-Coder-7B-Instruct-GGUF"
  "granite3.3:8b-instruct|audit|ibm-granite/granite-3.3-8b-instruct|lmstudio-community|granite-3.3-8b-instruct-GGUF"
  "deepseek-r1:7b|agent|deepseek-ai/DeepSeek-R1-Distill-Qwen-7B|bartowski|DeepSeek-R1-Distill-Qwen-7B-GGUF"
  "phi4-mini:instruct|debug|microsoft/Phi-4-mini-instruct|bartowski|Phi-4-mini-instruct-GGUF"
  "mistral:7b-instruct-v0.3-q4_K_M|redaction|mistralai/Mistral-7B-Instruct-v0.3|TheBloke|Mistral-7B-Instruct-v0.3-GGUF"
)

# Compteurs
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
step()  { echo ""; echo "══════════════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════════════"; log "STEP " "$1"; }

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

# Convertit "qwen2.5-coder:7b-instruct-q4_K_M" → "qwen2.5-coder" et "7b-instruct-q4_K_M"
parse_model_name() {
  local full="$1"
  echo "${full%%:*}"
}
parse_model_tag() {
  local full="$1"
  if [[ "$full" == *":"* ]]; then
    echo "${full#*:}"
  else
    echo "latest"
  fi
}

# Chemin manifest Ollama pour un modèle donné
ollama_manifest_path() {
  local name
  local tag
  name=$(parse_model_name "$1")
  tag=$(parse_model_tag "$1")
  echo "${HOME}/.ollama/models/manifests/registry.ollama.ai/library/${name}/${tag}"
}

# Convertit "sha256:abcdef..." → "sha256-abcdef..." (nom de fichier blob Ollama)
digest_to_blob_path() {
  local digest="$1"
  local hash="${digest#sha256:}"
  echo "${HOME}/.ollama/models/blobs/sha256-${hash}"
}

# ---------------------------------------------------------------------------
# ÉTAPE 1 — STRUCTURE DE RÉPERTOIRES
# ---------------------------------------------------------------------------
step "ÉTAPE 1 — Création de la structure de répertoires"

mkdir -p "${LLMHOME}/manifests"
mkdir -p "${LLMHOME}/checksums"
mkdir -p "${LLMHOME}/quarantine"
mkdir -p "${LLMHOME}/trusted"
mkdir -p "${LLMHOME}/logs"
mkdir -p "${HOME}/projets/llm-local-architecture"

info "Répertoires créés/vérifiés dans ${LLMHOME}"

# Initialiser le logfile maintenant que le répertoire existe
info "Bootstrap démarré — log : ${LOGFILE}"
info "Machine : ${HOSTNAME_VAL}"
info "Modèles à traiter : ${#MODELS[@]}"

# ---------------------------------------------------------------------------
# ÉTAPE 2 — TÉLÉCHARGEMENT DES MODÈLES
# ---------------------------------------------------------------------------
step "ÉTAPE 2 — Téléchargement des modèles via ollama pull"

# Vérification préalable Ollama
if ! command -v ollama &>/dev/null; then
  error "ollama non trouvé dans PATH. Installer depuis https://ollama.ai"
  exit 1
fi

info "Version Ollama : $(ollama --version 2>/dev/null || echo 'inconnue')"

for model_spec in "${MODELS[@]}"; do
  model_full="${model_spec%%|*}"
  model_name=$(parse_model_name "${model_full}")
  model_tag=$(parse_model_tag "${model_full}")

  info "Pull : ${model_full}"

  # Vérifier si déjà présent
  if ollama list 2>/dev/null | grep -q "^${model_name}.*${model_tag}"; then
    info "  → Déjà présent, pull de mise à jour quand même"
  fi

  if ! retry ollama pull "${model_full}"; then
    error "Échec du pull pour ${model_full} — abandon du modèle"
    # On continue avec les autres modèles mais on note l'échec
    continue
  fi
  info "  → Pull réussi : ${model_full}"
done

# ---------------------------------------------------------------------------
# ÉTAPE 3 — VÉRIFICATION D'INTÉGRITÉ PAR MODÈLE
# ---------------------------------------------------------------------------
step "ÉTAPE 3 — Vérification d'intégrité des blobs"

# Initialiser le tableau JSON des modèles
MODELS_JSON="[]"

for model_spec in "${MODELS[@]}"; do
  IFS='|' read -r model_full role repo_hf hf_owner hf_repo <<< "${model_spec}"
  model_name=$(parse_model_name "${model_full}")
  model_tag=$(parse_model_tag "${model_full}")
  manifest_path=$(ollama_manifest_path "${model_full}")
  pulled_at="${DATE_ISO}"

  info "Vérification : ${model_full}"

  # --- a. Localiser et lire le manifest Ollama ---
  if [[ ! -f "${manifest_path}" ]]; then
    warn "  Manifest introuvable : ${manifest_path}"
    warn "  Le modèle n'a peut-être pas été téléchargé correctement → quarantine"
    model_status="quarantine"
    COUNT_QUARANTINE=$((COUNT_QUARANTINE + 1))

    model_json=$(jq -n \
      --arg name "${model_full}" \
      --arg role "${role}" \
      --arg source "https://huggingface.co/${repo_hf}" \
      --arg manifest_path "${manifest_path}" \
      --arg sha256_hf "unavailable" \
      --arg hf_match "unverified" \
      --arg status "${model_status}" \
      --arg pulled_at "${pulled_at}" \
      --arg last_checked "${DATE_ISO}" \
      '{
        name: $name, role: $role, source_repo: $source,
        ollama_manifest_path: $manifest_path,
        blobs: [],
        sha256_hf_official: $sha256_hf,
        hf_match: $hf_match,
        status: $status,
        pulled_at: $pulled_at,
        last_checked: $last_checked,
        note: "manifest Ollama introuvable après pull"
      }')
    MODELS_JSON=$(echo "${MODELS_JSON}" | jq --argjson m "${model_json}" '. + [$m]')
    continue
  fi

  info "  Manifest trouvé : ${manifest_path}"

  # --- b. Vérification locale des blobs ---
  BLOBS_JSON="[]"
  LOCAL_INTEGRITY="ok"
  LARGEST_BLOB_HASH=""
  LARGEST_BLOB_SIZE=0

  # Extraire les layers du manifest
  while IFS= read -r layer; do
    digest=$(echo "${layer}" | jq -r '.digest')
    layer_size=$(echo "${layer}" | jq -r '.size // 0')
    media_type=$(echo "${layer}" | jq -r '.mediaType // "unknown"')

    blob_path=$(digest_to_blob_path "${digest}")
    hash_only="${digest#sha256:}"

    if [[ ! -f "${blob_path}" ]]; then
      warn "    Blob introuvable : ${blob_path}"
      LOCAL_INTEGRITY="fail"
      blob_json=$(jq -n \
        --arg digest "${digest}" \
        --arg blob_path "${blob_path}" \
        --arg sha256_recalculated "blob_missing" \
        --arg integrity_local "fail" \
        --arg media_type "${media_type}" \
        '{digest: $digest, blob_path: $blob_path, sha256_recalculated: $sha256_recalculated, integrity_local: $integrity_local, media_type: $media_type}')
      BLOBS_JSON=$(echo "${BLOBS_JSON}" | jq --argjson b "${blob_json}" '. + [$b]')
      continue
    fi

    # Recalculer le SHA-256
    computed_hash=$(sha256sum "${blob_path}" | awk '{print $1}')

    if [[ "${computed_hash}" == "${hash_only}" ]]; then
      integrity_local="ok"
      info "    Blob OK : ${hash_only:0:12}... (${media_type})"
    else
      integrity_local="fail"
      LOCAL_INTEGRITY="fail"
      warn "    DRIFT DÉTECTÉ : ${blob_path}"
      warn "    Attendu : ${hash_only}"
      warn "    Calculé : ${computed_hash}"
    fi

    # Identifier le plus gros blob (= modèle GGUF principal)
    if (( layer_size > LARGEST_BLOB_SIZE )) && [[ "${media_type}" == *"model"* ]]; then
      LARGEST_BLOB_SIZE="${layer_size}"
      LARGEST_BLOB_HASH="${computed_hash}"
    fi

    blob_json=$(jq -n \
      --arg digest "${digest}" \
      --arg blob_path "${blob_path}" \
      --arg sha256_recalculated "${computed_hash}" \
      --arg integrity_local "${integrity_local}" \
      --arg media_type "${media_type}" \
      '{digest: $digest, blob_path: $blob_path, sha256_recalculated: $sha256_recalculated, integrity_local: $integrity_local, media_type: $media_type}')
    BLOBS_JSON=$(echo "${BLOBS_JSON}" | jq --argjson b "${blob_json}" '. + [$b]')

  done < <(jq -c '.layers[]' "${manifest_path}" 2>/dev/null || true)

  # Config layer (separate from layers array in some manifest formats)
  config_digest=$(jq -r '.config.digest // empty' "${manifest_path}" 2>/dev/null || true)
  if [[ -n "${config_digest}" ]]; then
    config_blob_path=$(digest_to_blob_path "${config_digest}")
    config_hash="${config_digest#sha256:}"
    if [[ -f "${config_blob_path}" ]]; then
      computed_config=$(sha256sum "${config_blob_path}" | awk '{print $1}')
      [[ "${computed_config}" != "${config_hash}" ]] && LOCAL_INTEGRITY="fail"
    fi
  fi

  # --- c. Vérification contre HuggingFace ---
  HF_SHA="unavailable"
  HF_MATCH="unverified"

  # Note : les blobs Ollama proviennent des builds Ollama, pas directement
  # des GGUF HuggingFace. Le SHA du blob Ollama ≠ SHA du GGUF HF.
  # La vérification HF ci-dessous documente le SHA HF officiel pour
  # référence croisée manuelle — la non-correspondance est attendue.

  if [[ -n "${LARGEST_BLOB_HASH}" ]]; then
    info "  Interrogation HuggingFace API : ${hf_owner}/${hf_repo}"
    hf_response=$(curl -sf --max-time 15 \
      "https://huggingface.co/api/models/${hf_owner}/${hf_repo}/tree/main" \
      2>/dev/null || echo "[]")

    # Chercher un fichier GGUF Q4_K_M dans la réponse
    hf_gguf_sha=$(echo "${hf_response}" | jq -r \
      '[.[] | select(.path | test("Q4_K_M.*\\.gguf$"; "i"))] | .[0].lfs.sha256 // empty' \
      2>/dev/null || echo "")

    if [[ -n "${hf_gguf_sha}" ]]; then
      HF_SHA="${hf_gguf_sha}"
      # Comparaison directe : presque toujours "mismatch" car Ollama rebuild
      # On documente sans bloquer
      if [[ "${LARGEST_BLOB_HASH}" == "${hf_gguf_sha}" ]]; then
        HF_MATCH="confirmed"
        info "  HF SHA : correspondance confirmée"
      else
        HF_MATCH="unverified"
        info "  HF SHA : non-correspondance attendue (Ollama rebuild ≠ GGUF HF brut)"
        info "    SHA Ollama blob : ${LARGEST_BLOB_HASH:0:16}..."
        info "    SHA GGUF HF     : ${hf_gguf_sha:0:16}..."
      fi
    else
      info "  HF API : GGUF Q4_K_M non trouvé dans ${hf_owner}/${hf_repo}/tree/main"
      HF_SHA="unavailable"
      HF_MATCH="unverified"
    fi
  fi

  # --- d. Statut final ---
  if [[ "${LOCAL_INTEGRITY}" == "fail" ]]; then
    model_status="quarantine"
    COUNT_QUARANTINE=$((COUNT_QUARANTINE + 1))
    error "  QUARANTINE : ${model_full} — intégrité locale KO"
    # Créer un marker de quarantaine
    echo "${model_full} — intégrité KO — ${DATE_ISO}" >> "${LLMHOME}/quarantine/quarantine.log"
  elif [[ "${HF_MATCH}" == "confirmed" ]]; then
    model_status="trusted"
    COUNT_TRUSTED=$((COUNT_TRUSTED + 1))
    info "  STATUS : trusted"
  else
    model_status="unverified"
    COUNT_UNVERIFIED=$((COUNT_UNVERIFIED + 1))
    info "  STATUS : unverified (intégrité locale OK, SHA HF non concordant — comportement normal pour Ollama)"
    # Copier le SHA dans trusted pour référence
    echo "${model_full}|${LARGEST_BLOB_HASH}|${DATE_ISO}" >> "${LLMHOME}/trusted/trusted_blobs.log"
  fi

  # Construire l'objet JSON du modèle
  model_json=$(jq -n \
    --arg name "${model_full}" \
    --arg role "${role}" \
    --arg source "https://huggingface.co/${repo_hf}" \
    --arg manifest_path "${manifest_path}" \
    --argjson blobs "${BLOBS_JSON}" \
    --arg sha256_hf "${HF_SHA}" \
    --arg hf_match "${HF_MATCH}" \
    --arg status "${model_status}" \
    --arg pulled_at "${pulled_at}" \
    --arg last_checked "${DATE_ISO}" \
    '{
      name: $name,
      role: $role,
      source_repo: $source,
      ollama_manifest_path: $manifest_path,
      blobs: $blobs,
      sha256_hf_official: $sha256_hf,
      hf_match: $hf_match,
      status: $status,
      pulled_at: $pulled_at,
      last_checked: $last_checked,
      note: "SHA HF vs blob Ollama : divergence attendue — Ollama utilise ses propres builds GGUF. Intégrité locale (blob name == sha256sum) est la vérification primaire fiable."
    }')

  MODELS_JSON=$(echo "${MODELS_JSON}" | jq --argjson m "${model_json}" '. + [$m]')
done

# ---------------------------------------------------------------------------
# ÉTAPE 4 — GÉNÉRATION DU MANIFEST
# ---------------------------------------------------------------------------
step "ÉTAPE 4 — Génération du manifest"

jq -n \
  --arg generated_at "${DATE_ISO}" \
  --arg host "${HOSTNAME_VAL}" \
  --argjson models "${MODELS_JSON}" \
  '{
    generated_at: $generated_at,
    host: $host,
    schema_version: "1.0",
    models: $models
  }' > "${MANIFEST_FILE}"

info "Manifest écrit : ${MANIFEST_FILE}"
info "Taille : $(wc -c < "${MANIFEST_FILE}") bytes"

# ---------------------------------------------------------------------------
# ÉTAPE 5 — CRÉATION DU SCRIPT DE RECHECK QUOTIDIEN
# ---------------------------------------------------------------------------
step "ÉTAPE 5 — Création de recheck.sh"

cat > "${RECHECK_SCRIPT}" << 'RECHECK_SCRIPT_EOF'
#!/usr/bin/env bash
# recheck.sh — Vérification quotidienne d'intégrité des modèles LLM
set -euo pipefail

LLMHOME="${HOME}/.llm-local"
MANIFEST_FILE="${LLMHOME}/manifests/manifest.json"
LOG_DATE=$(date +"%Y%m%d")
LOGFILE="${LLMHOME}/logs/integrity_${LOG_DATE}.log"
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [$1] $2" | tee -a "${LOGFILE}"; }
info() { log "INFO " "$1"; }
warn() { log "WARN " "$1"; }
error() { log "ERROR" "$1"; }

if [[ ! -f "${MANIFEST_FILE}" ]]; then
  error "Manifest introuvable : ${MANIFEST_FILE}"
  error "Lancer bootstrap.sh d'abord."
  exit 1
fi

info "=== Recheck intégrité démarré ==="
info "Manifest : ${MANIFEST_FILE}"

COUNT_OK=0
COUNT_DRIFT=0
DRIFT_FOUND=false

# Lire tous les modèles du manifest
model_count=$(jq '.models | length' "${MANIFEST_FILE}")
info "Modèles à vérifier : ${model_count}"

for i in $(seq 0 $((model_count - 1))); do
  model_name=$(jq -r ".models[${i}].name" "${MANIFEST_FILE}")
  model_status=$(jq -r ".models[${i}].status" "${MANIFEST_FILE}")

  # Vérifier seulement trusted et unverified
  if [[ "${model_status}" == "quarantine" ]]; then
    warn "  SKIP (quarantine) : ${model_name}"
    continue
  fi

  info "Vérification : ${model_name} [${model_status}]"

  blob_count=$(jq ".models[${i}].blobs | length" "${MANIFEST_FILE}")
  model_ok=true

  for j in $(seq 0 $((blob_count - 1))); do
    blob_path=$(jq -r ".models[${i}].blobs[${j}].blob_path" "${MANIFEST_FILE}" | sed "s|^~|${HOME}|")
    expected_hash=$(jq -r ".models[${i}].blobs[${j}].sha256_recalculated" "${MANIFEST_FILE}")
    stored_integrity=$(jq -r ".models[${i}].blobs[${j}].integrity_local" "${MANIFEST_FILE}")

    # Skip blobs qui étaient déjà KO au bootstrap
    if [[ "${stored_integrity}" == "fail" ]] || [[ "${expected_hash}" == "blob_missing" ]]; then
      continue
    fi

    if [[ ! -f "${blob_path}" ]]; then
      error "  BLOB DISPARU : ${blob_path}"
      model_ok=false
      continue
    fi

    current_hash=$(sha256sum "${blob_path}" | awk '{print $1}')

    if [[ "${current_hash}" != "${expected_hash}" ]]; then
      error "  DRIFT DÉTECTÉ : ${model_name}"
      error "    Blob     : ${blob_path}"
      error "    Attendu  : ${expected_hash}"
      error "    Calculé  : ${current_hash}"
      model_ok=false
      DRIFT_FOUND=true
    fi
  done

  if [[ "${model_ok}" == "false" ]]; then
    # Mettre à jour le statut en quarantine dans le manifest (en place)
    tmp_manifest=$(mktemp)
    jq --argjson idx "${i}" \
       --arg ts "${DATE_ISO}" \
       '.models[$idx].status = "quarantine" | .models[$idx].last_checked = $ts | .models[$idx].quarantine_reason = "drift détecté lors du recheck"' \
       "${MANIFEST_FILE}" > "${tmp_manifest}"
    mv "${tmp_manifest}" "${MANIFEST_FILE}"
    error "  → Modèle passé en QUARANTINE : ${model_name}"
    COUNT_DRIFT=$((COUNT_DRIFT + 1))
  else
    # Mettre à jour last_checked
    tmp_manifest=$(mktemp)
    jq --argjson idx "${i}" --arg ts "${DATE_ISO}" \
       '.models[$idx].last_checked = $ts' \
       "${MANIFEST_FILE}" > "${tmp_manifest}"
    mv "${tmp_manifest}" "${MANIFEST_FILE}"
    info "  → OK : ${model_name}"
    COUNT_OK=$((COUNT_OK + 1))
  fi
done

echo ""
echo "══════════════════════════════════"
echo "  RÉSUMÉ RECHECK ${DATE_ISO}"
echo "  ✅ Modèles OK        : ${COUNT_OK}"
echo "  ❌ Dérives détectées : ${COUNT_DRIFT}"
echo "══════════════════════════════════"

info "Recheck terminé. OK=${COUNT_OK} DRIFT=${COUNT_DRIFT}"

if [[ "${DRIFT_FOUND}" == "true" ]]; then
  error "ALERTE : ${COUNT_DRIFT} modèle(s) en dérive — vérification manuelle requise"
  exit 1
fi

exit 0
RECHECK_SCRIPT_EOF

chmod +x "${RECHECK_SCRIPT}"
info "recheck.sh créé et rendu exécutable : ${RECHECK_SCRIPT}"

# ---------------------------------------------------------------------------
# ÉTAPE 6 — INSTALLATION DU CRON QUOTIDIEN
# ---------------------------------------------------------------------------
step "ÉTAPE 6 — Installation du cron quotidien (07h00)"

CRON_LINE="0 7 * * * ${RECHECK_SCRIPT} >> ${LLMHOME}/logs/cron.log 2>&1"

# Supprimer les lignes existantes recheck pour éviter les doublons
(crontab -l 2>/dev/null | grep -v "recheck" || true; echo "${CRON_LINE}") | crontab -

info "Cron installé : ${CRON_LINE}"

# Vérification
if crontab -l 2>/dev/null | grep -q "recheck"; then
  info "Cron vérifié OK dans crontab"
else
  warn "Cron non trouvé dans crontab — vérifier manuellement avec : crontab -l"
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
echo "  ✅ Modèles trusted    : ${COUNT_TRUSTED}"
echo "  ⚠️  Modèles unverified : ${COUNT_UNVERIFIED}"
echo "  ❌ Modèles quarantine : ${COUNT_QUARANTINE}"
echo ""
echo "  📄 Manifest : ${MANIFEST_FILE}"
echo "  📋 Log      : ${LOGFILE}"
echo "  🔁 Recheck  : ${RECHECK_SCRIPT}"
echo "  🕐 Prochain recheck automatique : demain 07h00"
echo ""

if [[ "${COUNT_QUARANTINE}" -gt 0 ]]; then
  echo "  ⚠️  ATTENTION : ${COUNT_QUARANTINE} modèle(s) en quarantaine."
  echo "     Consulter : ${LLMHOME}/quarantine/quarantine.log"
  echo ""
fi

echo "  NOTE : Status 'unverified' est normal pour les modèles Ollama."
echo "  Ollama construit ses propres GGUF — le SHA blob ≠ SHA GGUF HuggingFace."
echo "  L'intégrité locale (blob name == sha256sum) est la garantie primaire."
echo ""

info "Bootstrap terminé. trusted=${COUNT_TRUSTED} unverified=${COUNT_UNVERIFIED} quarantine=${COUNT_QUARANTINE}"

# Exit 1 si quarantine
if [[ "${COUNT_QUARANTINE}" -gt 0 ]]; then
  exit 1
fi

exit 0
