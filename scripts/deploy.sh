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
APP_OPEN_WAIT_TIMEOUT_SECONDS="${APP_OPEN_WAIT_TIMEOUT_SECONDS:-90}"
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

resolve_app_host() {
  local app_host="${APP_HOST:-}"
  if [[ -z "$app_host" ]]; then
    app_host="$(resolve_compose_env_value "APP_HOST" || true)"
  fi
  if [[ -z "$app_host" ]]; then
    app_host="localhost"
  fi
  printf '%s' "$app_host"
}

resolve_app_port() {
  local app_port="${APP_PORT:-}"
  if [[ -z "$app_port" ]]; then
    app_port="$(resolve_compose_env_value "APP_PORT" || true)"
  fi
  if [[ -z "$app_port" ]]; then
    app_port="8080"
  fi
  printf '%s' "$app_port"
}

build_app_url() {
  local app_host="$1"
  local app_port="$2"
  case "$app_host" in
    "" | "0.0.0.0" | "::" | "[::]")
      app_host="localhost"
      ;;
  esac
  printf 'http://%s:%s' "$app_host" "$app_port"
}

can_auto_open_browser() {
  local host_os="$1"

  if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
    return 1
  fi

  case "$host_os" in
    macos)
      command -v open >/dev/null 2>&1
      return $?
      ;;
    linux)
      command -v xdg-open >/dev/null 2>&1
      return $?
      ;;
    windows)
      if command -v cmd.exe >/dev/null 2>&1; then
        return 0
      fi
      if command -v powershell.exe >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
  esac

  return 1
}

wait_for_app_ready() {
  local app_url="$1"
  local timeout_seconds="$2"
  local elapsed_seconds=0
  local interval_seconds=2
  local http_status=""

  if ! command -v curl >/dev/null 2>&1; then
    return 2
  fi

  while (( elapsed_seconds < timeout_seconds )); do
    http_status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 "$app_url" || true)"
    if [[ "$http_status" =~ ^[1-5][0-9][0-9]$ ]] && [[ "$http_status" != "000" ]]; then
      return 0
    fi
    sleep "$interval_seconds"
    elapsed_seconds=$((elapsed_seconds + interval_seconds))
  done

  return 1
}

open_app_url() {
  local app_url="$1"
  local host_os="$2"

  case "$host_os" in
    macos)
      if command -v open >/dev/null 2>&1; then
        open "$app_url" >/dev/null 2>&1 && return 0
      fi
      ;;
    linux)
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$app_url" >/dev/null 2>&1 && return 0
      fi
      ;;
    windows)
      if command -v cmd.exe >/dev/null 2>&1; then
        cmd.exe /C start "" "$app_url" >/dev/null 2>&1 && return 0
      fi
      if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Start-Process '$app_url'" >/dev/null 2>&1 && return 0
      fi
      ;;
  esac

  return 1
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

host_ollama_installed() {
  command -v ollama >/dev/null 2>&1
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
      if host_ollama_reachable; then
        RESOLVED_OLLAMA_MODE="host"
        return 0
      fi
      if host_ollama_installed; then
        RESOLVED_OLLAMA_MODE="host"
        return 0
      fi
      gpu_backend="$(detect_gpu_backend "$host_os")"
      if [[ -n "$gpu_backend" ]]; then
        RESOLVED_OLLAMA_MODE="docker-gpu"
        OLLAMA_GPU_BACKEND="$gpu_backend"
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
  local step_status=0
  local step_pid=0
  local frame=0
  local shimmer_width=20
  local shimmer_position=0
  local shimmer_bar=""
  local index=0
  output_file="$(mktemp "${TMPDIR:-/tmp}/constructos-deploy.XXXXXX.log")"

  if [[ -t 1 ]]; then
    "$@" >"$output_file" 2>&1 &
    step_pid=$!
    while kill -0 "$step_pid" 2>/dev/null; do
      shimmer_position=$((frame % shimmer_width))
      shimmer_bar=""
      for ((index = 0; index < shimmer_width; index++)); do
        if ((index == shimmer_position)); then
          shimmer_bar="${shimmer_bar}>"
        else
          shimmer_bar="${shimmer_bar}."
        fi
      done
      if [[ -n "$LOG_COLOR_INFO" ]]; then
        printf '\r%b%s%b' "$LOG_COLOR_INFO" "[INFO] ${step_title}: running [${shimmer_bar}]" "$LOG_COLOR_RESET"
      else
        printf '\r%s' "[INFO] ${step_title}: running [${shimmer_bar}]"
      fi
      frame=$((frame + 1))
      sleep 0.12
    done

    if wait "$step_pid"; then
      step_status=0
    else
      step_status=$?
    fi
    printf '\r\033[2K'
  else
    if "$@" >"$output_file" 2>&1; then
      step_status=0
    else
      step_status=$?
    fi
  fi

  if [[ "$step_status" -eq 0 ]]; then
    rm -f "$output_file"
    log_info "${step_title}: done."
    return 0
  fi

  log_error "${step_title}: failed."
  cat "$output_file" >&2
  rm -f "$output_file"
  exit 1
}

can_prompt_user() {
  local tty_fd=""
  if [[ -t 0 ]]; then
    return 0
  fi
  if [[ -t 1 ]] && exec {tty_fd}<>/dev/tty 2>/dev/null; then
    exec {tty_fd}>&-
    return 0
  fi
  return 1
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_yes_no() {
  local message="$1"
  local default_choice="${2:-y}"
  local response=""
  local tty_fd=""

  if [[ -t 0 ]]; then
    read -r -p "$message" response
  elif [[ -t 1 ]] && exec {tty_fd}<>/dev/tty 2>/dev/null; then
    printf '%s' "$message" >&"$tty_fd"
    if ! read -r response <&"$tty_fd"; then
      exec {tty_fd}>&-
      return 1
    fi
    exec {tty_fd}>&-
  else
    return 1
  fi

  response="$(trim_whitespace "$response")"
  response="$(echo "$response" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$response" ]]; then
    response="$default_choice"
  fi

  case "$response" in
    y | yes)
      return 0
      ;;
    n | no)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_codex_auth_via_container() {
  local bootstrap_image="$1"
  local codex_config_file="$2"
  local codex_auth_file="$3"
  local auth_dir=""
  local bootstrap_volume=""
  local login_rc=0
  local auth_payload=""

  auth_dir="$(dirname "$codex_auth_file")"
  mkdir -p "$auth_dir"

  bootstrap_volume="constructos-codex-auth-bootstrap-$(date +%s)-$RANDOM"

  if ! docker volume create "$bootstrap_volume" >/dev/null; then
    log_error "Failed to create temporary Docker volume for Codex auth bootstrap."
    return 1
  fi

  log_info "Starting Codex device authentication inside a temporary container."
  log_info "Complete login in this terminal when Codex prints the device-auth URL and code."

  set +e
  if [[ -t 0 ]]; then
    docker run --rm -it \
      -e HOME=/home/app/codex-home/auth-bootstrap \
      -v "${bootstrap_volume}:/home/app/codex-home" \
      -v "${codex_config_file}:/home/app/.codex/config.toml:ro" \
      --entrypoint bash \
      "$bootstrap_image" \
      -lc 'set -euo pipefail; mkdir -p "$HOME/.codex"; codex login --device-auth; test -s "$HOME/.codex/auth.json"'
    login_rc=$?
  else
    docker run --rm -it \
      -e HOME=/home/app/codex-home/auth-bootstrap \
      -v "${bootstrap_volume}:/home/app/codex-home" \
      -v "${codex_config_file}:/home/app/.codex/config.toml:ro" \
      --entrypoint bash \
      "$bootstrap_image" \
      -lc 'set -euo pipefail; mkdir -p "$HOME/.codex"; codex login --device-auth; test -s "$HOME/.codex/auth.json"' </dev/tty >/dev/tty 2>/dev/tty
    login_rc=$?
  fi
  set -e

  if [[ "$login_rc" -ne 0 ]]; then
    docker volume rm -f "$bootstrap_volume" >/dev/null 2>&1 || true
    log_error "Codex device authentication failed inside container."
    return 1
  fi

  if ! auth_payload="$(docker run --rm \
    -v "${bootstrap_volume}:/home/app/codex-home" \
    --entrypoint sh \
    "$bootstrap_image" \
    -lc 'cat /home/app/codex-home/auth-bootstrap/.codex/auth.json' 2>/dev/null)"; then
    docker volume rm -f "$bootstrap_volume" >/dev/null 2>&1 || true
    log_error "Unable to export generated Codex auth file from bootstrap container."
    return 1
  fi

  if [[ -z "$auth_payload" ]]; then
    docker volume rm -f "$bootstrap_volume" >/dev/null 2>&1 || true
    log_error "Bootstrap container did not produce a Codex auth payload."
    return 1
  fi

  printf '%s\n' "$auth_payload" >"$codex_auth_file"
  if ! chmod a+r "$codex_auth_file" 2>/dev/null; then
    log_warn "Unable to adjust read permissions for $codex_auth_file"
  fi

  docker volume rm -f "$bootstrap_volume" >/dev/null 2>&1 || true
  log_info "Saved container-generated Codex auth to: $codex_auth_file"
  return 0
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
CODEX_BOOTSTRAP_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-task-app:${IMAGE_TAG}"

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

if ! chmod a+r "$CODEX_CONFIG_FILE" 2>/dev/null; then
  log_warn "Unable to adjust read permissions for $CODEX_CONFIG_FILE"
fi

TARGET_RESOLVED="$(resolve_deploy_target "$HOST_OS")"
resolve_requested_ollama_mode
resolve_runtime_ollama_mode "$REQUESTED_OLLAMA_MODE" "$TARGET_RESOLVED" "$HOST_OS"

COMPOSE_FILES=(compose/base/app.yml)
case "$TARGET_RESOLVED" in
  base)
    ;;
  ubuntu-gpu)
    # Add this profile only when running Docker GPU with DRI passthrough.
    if [[ "$RESOLVED_OLLAMA_MODE" == "docker-gpu" && "$OLLAMA_GPU_BACKEND" == "dri" ]]; then
      COMPOSE_FILES+=(compose/platforms/ubuntu-gpu.yml)
    fi
    ;;
  macos-m4)
    COMPOSE_FILES+=(compose/platforms/macos-m4.yml)
    ;;
  windows-desktop)
    COMPOSE_FILES+=(compose/platforms/windows.yml)
    ;;
  *)
    log_error "Unsupported DEPLOY_TARGET: $TARGET_RESOLVED"
    log_error "Supported values: auto, base, ubuntu-gpu, macos-m4, windows-desktop"
    exit 1
    ;;
esac

case "$RESOLVED_OLLAMA_MODE" in
  host)
    COMPOSE_FILES+=(compose/ollama/host.yml)
    if [[ "$HOST_OS" == "linux" && "$TARGET_RESOLVED" != "macos-m4" ]]; then
      COMPOSE_FILES+=(compose/ollama/host-linux.yml)
    fi
    ;;
  none)
    COMPOSE_FILES+=(compose/ollama/disabled.yml)
    ;;
  docker)
    ;;
  docker-gpu)
    if [[ "$OLLAMA_GPU_BACKEND" == "nvidia" ]]; then
      COMPOSE_FILES+=(compose/ollama/gpu-nvidia.yml)
    elif [[ "$OLLAMA_GPU_BACKEND" == "dri" && "$TARGET_RESOLVED" != "ubuntu-gpu" ]]; then
      COMPOSE_FILES+=(compose/ollama/gpu-dri.yml)
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

if [[ ! -f "$CODEX_AUTH_FILE" ]]; then
  log_warn "Codex authentication file was not found on host: $CODEX_AUTH_FILE"
  log_info "Falling back to in-container device authentication (codex login --device-auth)."
  if ! can_prompt_user; then
    log_error "Interactive terminal is required to bootstrap Codex auth in container."
    log_error "Run codex login on host, set CODEX_AUTH_FILE, or re-run deploy interactively."
    exit 1
  fi

  if prompt_yes_no "Run 'codex login --device-auth' in a temporary container now? [Y/n] " "y"; then
    if ! bootstrap_codex_auth_via_container "$CODEX_BOOTSTRAP_IMAGE" "$CODEX_CONFIG_FILE" "$CODEX_AUTH_FILE"; then
      log_error "Could not bootstrap Codex auth via container."
      exit 1
    fi
  else
    log_error "Deployment requires Codex auth."
    log_error "Run codex login on host or set CODEX_AUTH_FILE before deploy."
    exit 1
  fi
fi

if ! chmod a+r "$CODEX_AUTH_FILE" 2>/dev/null; then
  log_warn "Unable to adjust read permissions for $CODEX_AUTH_FILE"
fi

run_compose_step \
  "Start services" \
  docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env up -d --no-build --quiet-pull "${DEPLOY_SERVICES[@]}"

log_info "Deployment completed. Active services:"
docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env ps

APP_HOST_VALUE="$(resolve_app_host)"
APP_PORT_VALUE="$(resolve_app_port)"
APP_URL="$(build_app_url "$APP_HOST_VALUE" "$APP_PORT_VALUE")"

echo ""
log_info "Open Constructos at: ${APP_URL}"
if can_auto_open_browser "$HOST_OS"; then
  log_info "Waiting for Constructos to become available (up to ${APP_OPEN_WAIT_TIMEOUT_SECONDS}s)..."
  if wait_for_app_ready "$APP_URL" "$APP_OPEN_WAIT_TIMEOUT_SECONDS"; then
    if open_app_url "$APP_URL" "$HOST_OS"; then
      log_info "Opened Constructos in your default browser."
    else
      log_info "If browser did not open automatically, open this URL manually."
    fi
  else
    log_warn "Constructos is not reachable yet at ${APP_URL}."
    log_info "Open it manually once startup finishes."
  fi
else
  log_info "Browser auto-open is unavailable in this environment."
  log_info "Open this URL manually."
fi

echo ""
echo "Optional integrations:"
echo "- GitHub MCP: set GITHUB_PAT in .env, then set [mcp_servers.github].enabled = true in codex.config.toml and redeploy."
echo "- Jira MCP: cp .env.jira-mcp.example .env.jira-mcp, add credentials, then run:"
echo "  docker compose -p constructos-jira-mcp -f compose/integrations/jira-mcp.yml up -d"
