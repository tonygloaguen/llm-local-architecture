#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/.venv"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"
ENV_FILE="${PROJECT_ROOT}/.env"

run_checked() {
  local description="$1"
  shift

  local output=""
  if ! output="$("$@" 2>&1)"; then
    if [[ -n "${output}" ]]; then
      fail "${description}
${output}"
    fi
    fail "${description}"
  fi
}

log() {
  local level="$1"
  local message="$2"
  printf '[%s] %s\n' "${level}" "${message}"
}

info() {
  log "INFO" "$1"
}

warn() {
  log "WARN" "$1"
}

fail() {
  log "FAIL" "$1" >&2
  exit 1
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

confirm() {
  local prompt="$1"
  local default_answer
  local response

  default_answer="${2:-N}"
  response=""

  if ! is_interactive; then
    [[ "${default_answer}" =~ ^[Yy]$ ]]
    return
  fi

  read -r -p "${prompt} " response || response=""
  response="${response:-${default_answer}}"
  [[ "${response}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

require_python() {
  command -v python3 >/dev/null 2>&1 || fail "python3 introuvable dans PATH."

  local python_version
  local python_major
  local python_minor

  python_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  python_major="${python_version%%.*}"
  python_minor="${python_version#*.}"

  if (( python_major < 3 || (python_major == 3 && python_minor < 11) )); then
    fail "Python 3.11+ requis, version détectée: ${python_version}"
  fi
}

make_scripts_executable() {
  local scripts

  scripts=("${PROJECT_ROOT}"/scripts/*.sh)

  if [[ ! -e "${scripts[0]}" ]]; then
    info "Aucun script shell à rendre exécutable dans ${PROJECT_ROOT}/scripts."
    return
  fi

  chmod +x "${scripts[@]}"
}

ensure_codex_available() {
  command -v codex >/dev/null 2>&1 || fail "codex introuvable dans PATH."
  run_checked "codex --version a échoué." codex --version
}

install_third_party_binary() {
  local name="$1"
  local url="$2"
  local destination="$3"
  local expected_sha256
  local tmp_dir
  local archive_path
  local actual_sha256

  expected_sha256="${4:-}"

  tmp_dir="$(mktemp -d)"
  archive_path="${tmp_dir}/${name}"
  trap 'rm -rf -- "${tmp_dir}"' RETURN

  # 3a-download: récupérer le binaire tiers dans un emplacement temporaire.
  curl --fail --location --silent --show-error --output "${archive_path}" "${url}"

  # 3b-verify SHA-256: activer en fournissant expected_sha256.
  if [[ -n "${expected_sha256}" ]]; then
    actual_sha256=""
    actual_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
    [[ "${actual_sha256}" == "${expected_sha256}" ]] || fail "SHA-256 invalide pour ${name}: attendu ${expected_sha256}, obtenu ${actual_sha256}."
  fi

  # 3c-install: installer le binaire validé à sa destination finale.
  install -m 0755 "${archive_path}" "${destination}"
}

ensure_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    info ".env déjà présent, aucune copie nécessaire."
    return
  fi

  if [[ ! -f "${ENV_EXAMPLE_FILE}" ]]; then
    fail ".env.example introuvable: ${ENV_EXAMPLE_FILE}. Impossible de créer .env."
  fi

  if confirm "Créer ${ENV_FILE} depuis .env.example ? [Y/n]" "Y"; then
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
    info ".env créé depuis .env.example."
    return
  fi

  fail "Initialisation annulée: .env est requis."
}

create_or_reuse_venv() {
  if [[ ! -d "${VENV_DIR}" ]]; then
    info "Création du virtualenv dans ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  else
    info "Virtualenv existant détecté dans ${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
}

install_python_dependencies() {
  if [[ -f "${PROJECT_ROOT}/requirements.txt" ]]; then
    info "Installation des dépendances depuis requirements.txt"
    python -m pip install --upgrade pip
    python -m pip install -vvv -r "${PROJECT_ROOT}/requirements.txt" || fail "Installation pip échouée."
    return
  fi

  if [[ -f "${PROJECT_ROOT}/pyproject.toml" ]]; then
    info "Installation du projet depuis pyproject.toml"
    python -m pip install --upgrade pip
    python -m pip install -vvv -e "${PROJECT_ROOT}" || fail "Installation pip échouée."
    return
  fi

  warn "Aucun requirements.txt ni pyproject.toml détecté, étape pip ignorée."
}

main() {
  require_python
  make_scripts_executable
  ensure_codex_available
  ensure_env_file
  create_or_reuse_venv
  install_python_dependencies
  info "Bootstrap terminé."
}

main "$@"
