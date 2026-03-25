#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/.venv"

log() {
  local level="$1"
  local message="$2"
  printf '[%s] %s\n' "${level}" "${message}"
}

info() {
  log "INFO" "$1"
}

fail() {
  log "FAIL" "$1" >&2
  exit 1
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
  [[ -f "${PROJECT_ROOT}/pyproject.toml" ]] || fail "pyproject.toml introuvable."
  info "Installation du projet en mode editable avec dépendances de développement"
  python -m pip install --upgrade pip
  (
    cd "${PROJECT_ROOT}"
    python -m pip install -e ".[dev]"
  )
}

main() {
  require_python
  create_or_reuse_venv
  install_python_dependencies
  info "Bootstrap Python terminé."
}

main "$@"
