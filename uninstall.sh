#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${0:-}" && "${0}" != "bash" && "${0}" != "-" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi
INSTALL_DIR="${INSTALL_DIR:-${SCRIPT_DIR}}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
REMOVE_APP_DATA="${REMOVE_APP_DATA:-false}"
REMOVE_IMAGES="${REMOVE_IMAGES:-false}"
REMOVE_INSTALL_DIR="${REMOVE_INSTALL_DIR:-true}"
UNINSTALL_COS="${UNINSTALL_COS:-true}"

LOG_COLOR_RESET=""
LOG_COLOR_INFO=""
LOG_COLOR_WARN=""
LOG_COLOR_ERROR=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  LOG_COLOR_RESET=$'\033[0m'
  LOG_COLOR_INFO=$'\033[1;32m'
fi

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  LOG_COLOR_WARN=$'\033[1;33m'
  LOG_COLOR_ERROR=$'\033[1;31m'
fi

log_info() {
  printf '%b%s%b\n' "$LOG_COLOR_INFO" "[INFO] $*" "$LOG_COLOR_RESET"
}

log_warn() {
  printf '%b%s%b\n' "$LOG_COLOR_WARN" "[WARN] $*" "$LOG_COLOR_RESET" >&2
}

log_error() {
  printf '%b%s%b\n' "$LOG_COLOR_ERROR" "[ERROR] $*" "$LOG_COLOR_RESET" >&2
}

is_truthy() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_install_dir() {
  local raw="${INSTALL_DIR}"
  if [[ "$raw" == "~/"* ]]; then
    raw="${HOME}/${raw#~/}"
  fi
  if [[ "$raw" == /* ]]; then
    printf '%s' "$raw"
  else
    printf '%s/%s' "$(pwd)" "${raw#./}"
  fi
}

resolve_compose_project_name() {
  if [[ -n "${COMPOSE_PROJECT_NAME}" ]]; then
    printf '%s' "${COMPOSE_PROJECT_NAME}"
    return 0
  fi
  local detected_project=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    detected_project="$(
      docker ps -a --format '{{.Label "com.docker.compose.project"}} {{.Image}}' \
        | awk '$1 != "" && $2 ~ /^ghcr\.io\/nirm3l\/constructos-(task-app|mcp-tools):/ {print $1}' \
        | sort -u \
        | head -n 1
    )"
  fi
  if [[ -n "${detected_project}" ]]; then
    printf '%s' "${detected_project}"
    return 0
  fi
  local install_path="$1"
  basename "$install_path"
}

remove_labeled_resources() {
  local project_name="$1"
  local remove_volumes="$2"

  local containers
  containers="$(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" || true)"
  if [[ -n "${containers}" ]]; then
    log_info "Removing containers for project ${project_name}..."
    docker rm -f ${containers} >/dev/null
  else
    log_info "No containers found for project ${project_name}."
  fi

  local networks
  networks="$(docker network ls -q --filter "label=com.docker.compose.project=${project_name}" || true)"
  if [[ -n "${networks}" ]]; then
    log_info "Removing networks for project ${project_name}..."
    docker network rm ${networks} >/dev/null || true
  fi

  if [[ "${remove_volumes}" == "true" ]]; then
    local volumes
    volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}" || true)"
    if [[ -n "${volumes}" ]]; then
      log_info "Removing named volumes for project ${project_name}..."
      docker volume rm ${volumes} >/dev/null || true
    fi
  fi
}

remove_constructos_images() {
  local image_refs=()
  while IFS= read -r image_ref; do
    if [[ -n "${image_ref}" ]]; then
      image_refs+=("${image_ref}")
    fi
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^ghcr\.io/nirm3l/constructos-(task-app|mcp-tools):' || true)

  if [[ "${#image_refs[@]}" -eq 0 ]]; then
    log_info "No Constructos images found to remove."
    return 0
  fi

  log_info "Removing Constructos images..."
  docker image rm "${image_refs[@]}" >/dev/null || true
}

uninstall_cos_cli() {
  if ! is_truthy "${UNINSTALL_COS}"; then
    return 0
  fi
  if ! command -v pipx >/dev/null 2>&1; then
    log_warn "pipx is not available; skipping COS CLI uninstall."
    return 0
  fi
  if ! pipx list --short 2>/dev/null | grep -qx 'constructos-cli'; then
    log_info "COS CLI is not installed through pipx."
    return 0
  fi
  log_info "Uninstalling COS CLI..."
  pipx uninstall constructos-cli >/dev/null
}

INSTALL_PATH="$(resolve_install_dir)"
PROJECT_NAME="$(resolve_compose_project_name "${INSTALL_PATH}")"

if ! command -v docker >/dev/null 2>&1; then
  log_warn "Docker is not installed or not in PATH; skipping container cleanup."
else
  if docker info >/dev/null 2>&1; then
    remove_labeled_resources "${PROJECT_NAME}" "$(is_truthy "${REMOVE_APP_DATA}" && echo true || echo false)"
  else
    log_warn "Docker daemon is not reachable; skipping container cleanup."
  fi
fi

if is_truthy "${REMOVE_IMAGES}"; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    remove_constructos_images
  else
    log_warn "Docker is unavailable; skipping image removal."
  fi
fi

uninstall_cos_cli

if [[ -f "${INSTALL_PATH}/.deploy.env" ]]; then
  rm -f "${INSTALL_PATH}/.deploy.env"
fi

if is_truthy "${REMOVE_INSTALL_DIR}"; then
  if [[ -d "${INSTALL_PATH}" ]]; then
    log_info "Removing install directory ${INSTALL_PATH}..."
    parent_dir="$(dirname "${INSTALL_PATH}")"
    if [[ "$(pwd)" == "${INSTALL_PATH}" || "$(pwd)" == "${INSTALL_PATH}/"* ]]; then
      cd "${parent_dir}"
    fi
    rm -rf "${INSTALL_PATH}"
  else
    log_info "Install directory not found: ${INSTALL_PATH}"
  fi
else
  log_info "Preserving install directory: ${INSTALL_PATH}"
fi

echo ""
log_info "Constructos uninstall completed."
log_info "Project name: ${PROJECT_NAME}"
if ! is_truthy "${REMOVE_APP_DATA}"; then
  log_info "Named volumes were preserved. Set REMOVE_APP_DATA=true to remove them."
fi
if ! is_truthy "${REMOVE_IMAGES}"; then
  log_info "Images were preserved. Set REMOVE_IMAGES=true to remove them."
fi
