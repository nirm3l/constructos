#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEPLOYED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
DEPLOY_WITH_OLLAMA="${DEPLOY_WITH_OLLAMA:-auto}"
GHCR_OWNER="nirm3l"
GHCR_IMAGE_PREFIX="constructos"
CODEX_CONFIG_FILE="${CODEX_CONFIG_FILE:-}"
CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-}"

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

normalize_truthy() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on)
      echo "true"
      ;;
    0 | false | no | off)
      echo "false"
      ;;
    auto | "")
      echo "auto"
      ;;
    *)
      echo "invalid"
      ;;
  esac
}

detect_host_os() {
  local uname_value
  uname_value="$(uname -s 2>/dev/null || echo "unknown")"
  case "$uname_value" in
    Linux*)
      echo "linux"
      ;;
    Darwin*)
      echo "macos"
      ;;
    CYGWIN* | MINGW* | MSYS*)
      echo "windows"
      ;;
    *)
      if [[ "${OS:-}" == "Windows_NT" ]]; then
        echo "windows"
      else
        echo "unknown"
      fi
      ;;
  esac
}

docker_install_hint() {
  local host_os="$1"
  case "$host_os" in
    macos | windows)
      echo "Install Docker Desktop, then start it before deploy."
      ;;
    linux)
      echo "Install Docker Engine + Docker Compose plugin, then start the docker service."
      ;;
    *)
      echo "Install Docker with Compose support and ensure the daemon is running."
      ;;
  esac
}

require_docker() {
  local host_os="$1"

  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is required but was not found."
    log_error "$(docker_install_hint "$host_os")"
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin is required but unavailable."
    log_error "$(docker_install_hint "$host_os")"
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    log_error "Docker is installed but the daemon is not reachable."
    log_error "Start Docker and retry."
    exit 1
  fi
}

normalize_host_path() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z]:\\ ]]; then
    local drive_letter
    drive_letter="$(echo "${value:0:1}" | tr '[:upper:]' '[:lower:]')"
    local path_suffix="${value:2}"
    path_suffix="${path_suffix//\\//}"
    printf '/%s%s' "$drive_letter" "$path_suffix"
    return 0
  fi

  if [[ "$value" =~ ^[A-Za-z]:/ ]]; then
    local drive_letter
    drive_letter="$(echo "${value:0:1}" | tr '[:upper:]' '[:lower:]')"
    local path_suffix="${value:2}"
    printf '/%s%s' "$drive_letter" "$path_suffix"
    return 0
  fi

  printf '%s' "$value"
}

resolve_compose_env_value() {
  local var_name="$1"
  local current_value="${!var_name:-}"
  if [[ -n "$current_value" ]]; then
    printf '%s' "$current_value"
    return 0
  fi
  if [[ ! -f .env ]]; then
    return 1
  fi

  local line
  line="$(grep -E "^[[:space:]]*${var_name}=" .env | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi

  line="${line#*=}"
  line="${line%$'\r'}"
  printf '%s' "$line"
}

resolve_deploy_target() {
  if [[ "$DEPLOY_TARGET" != "auto" ]]; then
    echo "$DEPLOY_TARGET"
    return
  fi

  local host_os="$1"
  case "$host_os" in
    macos)
      echo "macos-m4"
      ;;
    windows)
      echo "windows-desktop"
      ;;
    linux)
      if [[ -e /dev/dri ]]; then
        echo "ubuntu-gpu"
      else
        echo "base"
      fi
      ;;
    *)
      echo "base"
      ;;
  esac
}

resolve_ollama_service_enabled() {
  local target="$1"
  local requested_mode="$2"
  local normalized_mode

  normalized_mode="$(normalize_truthy "$requested_mode")"
  if [[ "$normalized_mode" == "invalid" ]]; then
    log_warn "Unsupported DEPLOY_WITH_OLLAMA=${requested_mode}. Allowed: auto, true, false. Falling back to auto."
    normalized_mode="auto"
  fi

  if [[ "$target" == "macos-m4" || "$target" == "windows-desktop" ]]; then
    if [[ "$normalized_mode" == "true" ]]; then
      log_warn "DEPLOY_WITH_OLLAMA=true is not used for ${target}; this profile expects host Ollama."
    fi
    echo "false"
    return 0
  fi

  case "$normalized_mode" in
    true)
      echo "true"
      ;;
    false)
      echo "false"
      ;;
    auto)
      echo "true"
      ;;
  esac
}

run_compose_step() {
  local step_title="$1"
  shift

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/constructos-deploy.XXXXXX.log")"
  if "$@" >"$output_file" 2>&1; then
    rm -f "$output_file"
    log_info "${step_title}: done."
    return 0
  fi

  log_error "${step_title}: failed."
  cat "$output_file" >&2
  rm -f "$output_file"
  exit 1
}

if [[ -z "$DEPLOY_TARGET" ]]; then
  DEPLOY_TARGET="$(resolve_compose_env_value "DEPLOY_TARGET" || true)"
fi
DEPLOY_TARGET="${DEPLOY_TARGET:-auto}"
HOST_OS="$(detect_host_os)"
require_docker "$HOST_OS"

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="$(resolve_compose_env_value "IMAGE_TAG" || true)"
fi
if [[ -z "$IMAGE_TAG" ]]; then
  echo "IMAGE_TAG is required (for example: IMAGE_TAG=v0.1.230)."
  echo "You can set it in shell env or in .env."
  exit 1
fi

if [[ -z "$CODEX_CONFIG_FILE" ]]; then
  CODEX_CONFIG_FILE="$(resolve_compose_env_value "CODEX_CONFIG_FILE" || true)"
fi
if [[ -z "$CODEX_CONFIG_FILE" ]]; then
  CODEX_CONFIG_FILE="./codex.config.toml"
fi
CODEX_CONFIG_FILE="$(normalize_host_path "$CODEX_CONFIG_FILE")"
if [[ "$CODEX_CONFIG_FILE" != /* ]]; then
  CODEX_CONFIG_FILE="${ROOT_DIR}/${CODEX_CONFIG_FILE#./}"
fi

if [[ -z "$CODEX_AUTH_FILE" ]]; then
  CODEX_AUTH_FILE="$(resolve_compose_env_value "CODEX_AUTH_FILE" || true)"
fi
if [[ -z "$CODEX_AUTH_FILE" ]]; then
  CODEX_AUTH_FILE="${HOME}/.codex/auth.json"
fi
CODEX_AUTH_FILE="$(normalize_host_path "$CODEX_AUTH_FILE")"
if [[ "$CODEX_AUTH_FILE" != /* ]]; then
  CODEX_AUTH_FILE="${ROOT_DIR}/${CODEX_AUTH_FILE#./}"
fi

LICENSE_SERVER_TOKEN_VALUE="$(resolve_compose_env_value "LICENSE_SERVER_TOKEN" || true)"
if [[ -z "$LICENSE_SERVER_TOKEN_VALUE" ]]; then
  echo "LICENSE_SERVER_TOKEN is required. Set it in .env."
  exit 1
fi

if [[ ! -f "$CODEX_CONFIG_FILE" ]]; then
  echo "Missing Codex config file: $CODEX_CONFIG_FILE"
  echo "Set CODEX_CONFIG_FILE to a valid file path before deploy."
  exit 1
fi
if [[ ! -f "$CODEX_AUTH_FILE" ]]; then
  echo "Missing Codex auth file: $CODEX_AUTH_FILE"
  echo "Run codex login on host or set CODEX_AUTH_FILE before deploy."
  exit 1
fi

if ! chmod a+r "$CODEX_CONFIG_FILE" 2>/dev/null; then
  log_warn "Unable to adjust read permissions for $CODEX_CONFIG_FILE"
fi
if ! chmod a+r "$CODEX_AUTH_FILE" 2>/dev/null; then
  log_warn "Unable to adjust read permissions for $CODEX_AUTH_FILE"
fi

TARGET_RESOLVED="$(resolve_deploy_target "$HOST_OS")"
COMPOSE_ARGS=(-f docker-compose.yml)

case "$TARGET_RESOLVED" in
  base)
    ;;
  ubuntu-gpu)
    COMPOSE_ARGS+=(-f docker-compose.ubuntu-gpu.yml)
    ;;
  macos-m4)
    COMPOSE_ARGS+=(-f docker-compose.macos-m4.yml)
    ;;
  windows-desktop)
    COMPOSE_ARGS+=(-f docker-compose.windows.yml)
    ;;
  *)
    echo "Unsupported DEPLOY_TARGET: $TARGET_RESOLVED"
    echo "Supported values: auto, base, ubuntu-gpu, macos-m4, windows-desktop"
    exit 1
    ;;
esac

OLLAMA_SERVICE_ENABLED="$(resolve_ollama_service_enabled "$TARGET_RESOLVED" "$DEPLOY_WITH_OLLAMA")"

APP_VERSION="$IMAGE_TAG"
APP_BUILD="ghcr-${IMAGE_TAG}-${GIT_SHA}"
TASK_APP_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-task-app:${IMAGE_TAG}"
MCP_TOOLS_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-mcp-tools:${IMAGE_TAG}"

DEPLOY_SERVICES=(task-app mcp-tools)
if [[ "$OLLAMA_SERVICE_ENABLED" == "true" ]]; then
  DEPLOY_SERVICES+=(ollama)
fi

cat > .deploy.env <<EOF
APP_VERSION=${APP_VERSION}
APP_BUILD=${APP_BUILD}
APP_DEPLOYED_AT_UTC=${DEPLOYED_AT_UTC}
TASK_APP_IMAGE=${TASK_APP_IMAGE}
MCP_TOOLS_IMAGE=${MCP_TOOLS_IMAGE}
LICENSE_SERVER_TOKEN=${LICENSE_SERVER_TOKEN_VALUE}
CODEX_CONFIG_FILE=${CODEX_CONFIG_FILE}
CODEX_AUTH_FILE=${CODEX_AUTH_FILE}
EOF

log_info "Deploy profile: client"
log_info "Version: ${APP_VERSION} (${APP_BUILD})"
log_info "Target: ${TARGET_RESOLVED}"
log_info "Source: ghcr"
log_info "Services: ${DEPLOY_SERVICES[*]}"
if [[ "$OLLAMA_SERVICE_ENABLED" == "false" ]]; then
  log_warn "Ollama container is not included in this deploy. AI embedding features require reachable Ollama at OLLAMA_BASE_URL."
fi

run_compose_step \
  "Pull images" \
  docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env pull --quiet "${DEPLOY_SERVICES[@]}"

run_compose_step \
  "Start services" \
  docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env up -d --no-build --quiet-pull "${DEPLOY_SERVICES[@]}"

log_info "Deployment completed. Active services:"
docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env ps
