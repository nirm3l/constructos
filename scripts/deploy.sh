#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEPLOYED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
DEPLOY_OLLAMA_MODE="${DEPLOY_OLLAMA_MODE:-}"
DEPLOY_WITH_OLLAMA="${DEPLOY_WITH_OLLAMA:-}"
GHCR_OWNER="nirm3l"
GHCR_IMAGE_PREFIX="constructos"
CODEX_CONFIG_FILE="${CODEX_CONFIG_FILE:-}"
CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-}"
HOST_OS=""
TARGET_RESOLVED=""
REQUESTED_OLLAMA_MODE=""
RESOLVED_OLLAMA_MODE=""
OLLAMA_GPU_BACKEND=""

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

normalize_ollama_mode() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    auto | "")
      echo "auto"
      ;;
    docker)
      echo "docker"
      ;;
    docker-gpu)
      echo "docker-gpu"
      ;;
    host)
      echo "host"
      ;;
    none)
      echo "none"
      ;;
    1 | true | yes | on)
      echo "docker"
      ;;
    0 | false | no | off)
      echo "none"
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

host_ollama_reachable() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "http://localhost:11434/api/tags" >/dev/null 2>&1
    return $?
  fi

  if command -v ollama >/dev/null 2>&1; then
    ollama list >/dev/null 2>&1
    return $?
  fi

  return 1
}

detect_gpu_backend() {
  local host_os="$1"

  if [[ "$host_os" == "linux" ]] && [[ -e /dev/dri ]]; then
    echo "dri"
    return 0
  fi

  local runtimes
  runtimes="$(docker info --format '{{json .Runtimes}}' 2>/dev/null || true)"
  if echo "$runtimes" | grep -qi '"nvidia"'; then
    echo "nvidia"
    return 0
  fi

  echo ""
}

resolve_requested_ollama_mode() {
  if [[ -z "$DEPLOY_OLLAMA_MODE" ]]; then
    DEPLOY_OLLAMA_MODE="$(resolve_compose_env_value "DEPLOY_OLLAMA_MODE" || true)"
  fi

  if [[ -z "$DEPLOY_OLLAMA_MODE" ]]; then
    if [[ -z "$DEPLOY_WITH_OLLAMA" ]]; then
      DEPLOY_WITH_OLLAMA="$(resolve_compose_env_value "DEPLOY_WITH_OLLAMA" || true)"
    fi
    DEPLOY_OLLAMA_MODE="$DEPLOY_WITH_OLLAMA"
  fi

  if [[ -z "$DEPLOY_OLLAMA_MODE" ]]; then
    DEPLOY_OLLAMA_MODE="auto"
  fi

  REQUESTED_OLLAMA_MODE="$(normalize_ollama_mode "$DEPLOY_OLLAMA_MODE")"
  if [[ "$REQUESTED_OLLAMA_MODE" == "invalid" ]]; then
    log_error "Unsupported DEPLOY_OLLAMA_MODE=${DEPLOY_OLLAMA_MODE}."
    log_error "Allowed values: auto, docker, docker-gpu, host, none"
    exit 1
  fi
}

resolve_runtime_ollama_mode() {
  local requested_mode="$1"
  local target="$2"
  local host_os="$3"
  local gpu_backend=""

  OLLAMA_GPU_BACKEND=""

  if [[ "$target" == "macos-m4" ]]; then
    if [[ "$requested_mode" == "none" ]]; then
      RESOLVED_OLLAMA_MODE="none"
      return 0
    fi
    if [[ "$requested_mode" != "auto" && "$requested_mode" != "host" ]]; then
      log_warn "${requested_mode} is not used for macOS profile. Falling back to host Ollama."
    fi
    RESOLVED_OLLAMA_MODE="host"
    return 0
  fi

  case "$requested_mode" in
    auto)
      gpu_backend="$(detect_gpu_backend "$host_os")"
      if [[ -n "$gpu_backend" ]]; then
        RESOLVED_OLLAMA_MODE="docker-gpu"
        OLLAMA_GPU_BACKEND="$gpu_backend"
        return 0
      fi
      if host_ollama_reachable; then
        RESOLVED_OLLAMA_MODE="host"
        return 0
      fi
      RESOLVED_OLLAMA_MODE="docker"
      return 0
      ;;
    docker-gpu)
      gpu_backend="$(detect_gpu_backend "$host_os")"
      if [[ -n "$gpu_backend" ]]; then
        RESOLVED_OLLAMA_MODE="docker-gpu"
        OLLAMA_GPU_BACKEND="$gpu_backend"
        return 0
      fi
      log_warn "docker-gpu requested but no Docker GPU backend was detected."
      if host_ollama_reachable; then
        log_warn "Falling back to host Ollama."
        RESOLVED_OLLAMA_MODE="host"
      else
        log_warn "Falling back to Docker Ollama without GPU."
        RESOLVED_OLLAMA_MODE="docker"
      fi
      return 0
      ;;
    docker | host | none)
      RESOLVED_OLLAMA_MODE="$requested_mode"
      return 0
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
  log_error "IMAGE_TAG is required (for example: IMAGE_TAG=v0.1.230)."
  log_error "Set it in shell env or in .env."
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
  log_error "LICENSE_SERVER_TOKEN is required. Set it in .env or shell env."
  exit 1
fi

if [[ ! -f "$CODEX_CONFIG_FILE" ]]; then
  log_error "Missing Codex config file: $CODEX_CONFIG_FILE"
  log_error "Set CODEX_CONFIG_FILE to a valid file path before deploy."
  exit 1
fi
if [[ ! -f "$CODEX_AUTH_FILE" ]]; then
  log_error "Missing Codex auth file: $CODEX_AUTH_FILE"
  log_error "Run codex login on host or set CODEX_AUTH_FILE before deploy."
  exit 1
fi

if ! chmod a+r "$CODEX_CONFIG_FILE" 2>/dev/null; then
  log_warn "Unable to adjust read permissions for $CODEX_CONFIG_FILE"
fi
if ! chmod a+r "$CODEX_AUTH_FILE" 2>/dev/null; then
  log_warn "Unable to adjust read permissions for $CODEX_AUTH_FILE"
fi

TARGET_RESOLVED="$(resolve_deploy_target "$HOST_OS")"
resolve_requested_ollama_mode
resolve_runtime_ollama_mode "$REQUESTED_OLLAMA_MODE" "$TARGET_RESOLVED" "$HOST_OS"

COMPOSE_FILES=(docker-compose.yml)
case "$TARGET_RESOLVED" in
  base)
    ;;
  ubuntu-gpu)
    # Add this profile only when running Docker GPU with DRI passthrough.
    if [[ "$RESOLVED_OLLAMA_MODE" == "docker-gpu" && "$OLLAMA_GPU_BACKEND" == "dri" ]]; then
      COMPOSE_FILES+=(docker-compose.ubuntu-gpu.yml)
    fi
    ;;
  macos-m4)
    COMPOSE_FILES+=(docker-compose.macos-m4.yml)
    ;;
  windows-desktop)
    COMPOSE_FILES+=(docker-compose.windows.yml)
    ;;
  *)
    log_error "Unsupported DEPLOY_TARGET: $TARGET_RESOLVED"
    log_error "Supported values: auto, base, ubuntu-gpu, macos-m4, windows-desktop"
    exit 1
    ;;
esac

case "$RESOLVED_OLLAMA_MODE" in
  host)
    COMPOSE_FILES+=(docker-compose.ollama-host.yml)
    if [[ "$HOST_OS" == "linux" && "$TARGET_RESOLVED" != "macos-m4" ]]; then
      COMPOSE_FILES+=(docker-compose.ollama-host-linux.yml)
    fi
    ;;
  none)
    COMPOSE_FILES+=(docker-compose.ollama-disabled.yml)
    ;;
  docker)
    ;;
  docker-gpu)
    if [[ "$OLLAMA_GPU_BACKEND" == "nvidia" ]]; then
      COMPOSE_FILES+=(docker-compose.ollama-gpu-nvidia.yml)
    elif [[ "$OLLAMA_GPU_BACKEND" == "dri" && "$TARGET_RESOLVED" != "ubuntu-gpu" ]]; then
      COMPOSE_FILES+=(docker-compose.ollama-gpu-dri.yml)
    fi
    ;;
esac

COMPOSE_ARGS=()
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$compose_file")
done

APP_VERSION="$IMAGE_TAG"
APP_BUILD="ghcr-${IMAGE_TAG}-${GIT_SHA}"
TASK_APP_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-task-app:${IMAGE_TAG}"
MCP_TOOLS_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-mcp-tools:${IMAGE_TAG}"

DEPLOY_SERVICES=(task-app mcp-tools)
if [[ "$RESOLVED_OLLAMA_MODE" == "docker" || "$RESOLVED_OLLAMA_MODE" == "docker-gpu" ]]; then
  DEPLOY_SERVICES+=(ollama)
fi

cat > .deploy.env <<EOF_ENV
APP_VERSION=${APP_VERSION}
APP_BUILD=${APP_BUILD}
APP_DEPLOYED_AT_UTC=${DEPLOYED_AT_UTC}
TASK_APP_IMAGE=${TASK_APP_IMAGE}
MCP_TOOLS_IMAGE=${MCP_TOOLS_IMAGE}
LICENSE_SERVER_TOKEN=${LICENSE_SERVER_TOKEN_VALUE}
CODEX_CONFIG_FILE=${CODEX_CONFIG_FILE}
CODEX_AUTH_FILE=${CODEX_AUTH_FILE}
EOF_ENV

log_info "Deploy profile: client"
log_info "Version: ${APP_VERSION} (${APP_BUILD})"
log_info "Target: ${TARGET_RESOLVED}"
log_info "Source: ghcr"
log_info "Ollama mode requested: ${REQUESTED_OLLAMA_MODE}"
log_info "Ollama mode selected: ${RESOLVED_OLLAMA_MODE}"
if [[ "$RESOLVED_OLLAMA_MODE" == "docker-gpu" ]]; then
  log_info "Ollama GPU backend: ${OLLAMA_GPU_BACKEND}"
fi
if [[ "$RESOLVED_OLLAMA_MODE" == "none" ]]; then
  log_warn "Ollama is disabled. AI embedding and retrieval features will be limited."
fi
if [[ "$RESOLVED_OLLAMA_MODE" == "host" ]] && ! host_ollama_reachable; then
  log_warn "Host Ollama does not appear reachable on http://localhost:11434."
  log_warn "Start Ollama before using AI embedding features."
fi
log_info "Services: ${DEPLOY_SERVICES[*]}"

run_compose_step \
  "Pull images" \
  docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env pull --quiet "${DEPLOY_SERVICES[@]}"

run_compose_step \
  "Start services" \
  docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env up -d --no-build --quiet-pull "${DEPLOY_SERVICES[@]}"

log_info "Deployment completed. Active services:"
docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env ps
