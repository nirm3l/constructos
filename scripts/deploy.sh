#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEPLOYED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
GHCR_OWNER="nirm3l"
GHCR_IMAGE_PREFIX="constructos"
CODEX_CONFIG_FILE="${CODEX_CONFIG_FILE:-}"
CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-}"

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

  local host_os
  host_os="$(uname -s)"
  case "$host_os" in
    Darwin)
      echo "macos-m4"
      ;;
    Linux)
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

if [[ -z "$DEPLOY_TARGET" ]]; then
  DEPLOY_TARGET="$(resolve_compose_env_value "DEPLOY_TARGET" || true)"
fi
DEPLOY_TARGET="${DEPLOY_TARGET:-auto}"

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
if [[ "$CODEX_CONFIG_FILE" != /* ]]; then
  CODEX_CONFIG_FILE="${ROOT_DIR}/${CODEX_CONFIG_FILE#./}"
fi

if [[ -z "$CODEX_AUTH_FILE" ]]; then
  CODEX_AUTH_FILE="$(resolve_compose_env_value "CODEX_AUTH_FILE" || true)"
fi
if [[ -z "$CODEX_AUTH_FILE" ]]; then
  CODEX_AUTH_FILE="${HOME}/.codex/auth.json"
fi
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
  echo "Warning: unable to adjust read permissions for $CODEX_CONFIG_FILE"
fi
if ! chmod a+r "$CODEX_AUTH_FILE" 2>/dev/null; then
  echo "Warning: unable to adjust read permissions for $CODEX_AUTH_FILE"
fi

TARGET_RESOLVED="$(resolve_deploy_target)"
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
  *)
    echo "Unsupported DEPLOY_TARGET: $TARGET_RESOLVED"
    echo "Supported values: auto, base, ubuntu-gpu, macos-m4"
    exit 1
    ;;
esac

APP_VERSION="$IMAGE_TAG"
APP_BUILD="ghcr-${IMAGE_TAG}-${GIT_SHA}"
TASK_APP_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-task-app:${IMAGE_TAG}"
MCP_TOOLS_IMAGE="ghcr.io/${GHCR_OWNER}/${GHCR_IMAGE_PREFIX}-mcp-tools:${IMAGE_TAG}"

DEPLOY_SERVICES=(task-app mcp-tools)
if [[ "$TARGET_RESOLVED" != "macos-m4" ]]; then
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

echo "Deploy profile: client"
echo "Deploying version ${APP_VERSION} (${APP_BUILD}) at ${DEPLOYED_AT_UTC}"
echo "Resolved deploy target: ${TARGET_RESOLVED}"
echo "Deploy source: ghcr (fixed)"
echo "task-app image: ${TASK_APP_IMAGE}"
echo "mcp-tools image: ${MCP_TOOLS_IMAGE}"
echo "codex config file: ${CODEX_CONFIG_FILE}"
echo "codex auth file: ${CODEX_AUTH_FILE}"
echo "Compose files: ${COMPOSE_ARGS[*]}"
echo "Deploy services: ${DEPLOY_SERVICES[*]}"

echo "Pulling images..."
docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env pull "${DEPLOY_SERVICES[@]}"
docker compose "${COMPOSE_ARGS[@]}" --env-file .deploy.env up -d --no-build "${DEPLOY_SERVICES[@]}"
