# Constructos Client Deployment

This repository contains the client-facing deployment package only.

## One-liner install
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main INSTALL_COS=true AUTO_DEPLOY=1 bash
```

## One-liner install (Windows PowerShell, native)
```powershell
$env:ACTIVATION_CODE='ACT-XXXX-XXXX-XXXX-XXXX-XXXX'
$env:IMAGE_TAG='main'
$env:INSTALL_COS='true'
$env:AUTO_DEPLOY='1'
iwr -UseBasicParsing https://raw.githubusercontent.com/nirm3l/constructos/main/install.ps1 | iex
```

## Manual install
```bash
git clone https://github.com/nirm3l/constructos.git
cd constructos
ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main bash ./install.sh
# or: set LICENSE_SERVER_TOKEN manually in .env, then deploy
IMAGE_TAG=main bash ./scripts/deploy.sh
```

Windows PowerShell:
```powershell
git clone https://github.com/nirm3l/constructos.git
cd constructos
.\install.ps1 -ActivationCode 'ACT-XXXX-XXXX-XXXX-XXXX-XXXX' -ImageTag 'main' -AutoDeploy 'true'
```

## Runtime profiles
- `DEPLOY_TARGET=auto|base|ubuntu-gpu|macos-m4|windows-desktop` (default: `auto`)
- `IMAGE_TAG=<tag>` (default: `main`)
- `ACTIVATION_CODE` (recommended)
- `LICENSE_SERVER_TOKEN` (manual fallback)
- `CODEX_CONFIG_FILE` (default: `./codex.config.toml`)
- `CODEX_AUTH_FILE` (default: `${HOME}/.codex/auth.json`)
- `INSTALL_COS=true|false` (default: `true`)
- `COS_INSTALL_METHOD=pipx|link` (default: `pipx`)
- `INSTALL_OLLAMA=auto|true|false` (default: `auto`)
- `DEPLOY_OLLAMA_MODE=auto|docker|docker-gpu|host|none` (default: `auto`)

`INSTALL_OLLAMA` behavior:
- `auto`: prompt when Ollama is missing, then continue with/without support.
- `true`: try to install Ollama on host (automated on macOS and Windows when package manager is available).
- `false`: skip Ollama installation.

`DEPLOY_OLLAMA_MODE` behavior:
- `auto`: chooses in order `docker-gpu -> host -> docker` (on macOS profile: fixed to host unless `none`).
- `docker`: run Ollama as a Docker service (CPU mode).
- `docker-gpu`: prefer Docker GPU mode; if GPU backend is unavailable, deploy falls back to `host` then `docker`.
- `host`: use host Ollama at `http://host.docker.internal:11434`.
- `none`: skip Ollama service entirely.

Platform defaults:
- `macos-m4`: fixed to host Ollama (unless mode is `none`).
- `windows-desktop` and Linux targets (`base`/`ubuntu-gpu`): support both Docker and host Ollama modes.

## Default GHCR images
- `ghcr.io/nirm3l/constructos-task-app:<tag>`
- `ghcr.io/nirm3l/constructos-mcp-tools:<tag>`

## Codex host files
- `task-app` mounts a repository-scoped Codex config file (`./codex.config.toml` by default) to `/home/app/.codex/config.toml`.
- `task-app` mounts your Codex auth file (`${HOME}/.codex/auth.json` by default) to `/home/app/.codex/auth.json`.
- Override either path with `CODEX_CONFIG_FILE` or `CODEX_AUTH_FILE` in `.env` or shell env before deploy.
- If `CODEX_AUTH_FILE` is missing during deploy, installer/deploy now offers an interactive fallback: run `codex login --device-auth` inside a temporary container, then persist the generated auth JSON to `CODEX_AUTH_FILE`.

## Optional: Jira MCP (separate compose)
1. Create local env file:
```bash
cp .env.jira-mcp.example .env.jira-mcp
```
2. Set your Jira credentials in `.env.jira-mcp`.
3. Start Jira MCP:
```bash
docker compose -p constructos-jira-mcp -f docker-compose.jira-mcp.yml up -d
```

## COS CLI
`install.sh` now installs the `cos` CLI by default as a best-effort step.

If you do not want automatic installation:
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX INSTALL_COS=false bash
```

Skip Ollama installation explicitly:
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX INSTALL_OLLAMA=false bash
```

Force host Ollama mode:
```bash
IMAGE_TAG=main DEPLOY_OLLAMA_MODE=host bash ./scripts/deploy.sh
```

Force Docker Ollama with GPU (fallbacks automatically if unsupported):
```bash
IMAGE_TAG=main DEPLOY_OLLAMA_MODE=docker-gpu bash ./scripts/deploy.sh
```

Disable Ollama:
```bash
IMAGE_TAG=main DEPLOY_OLLAMA_MODE=none bash ./scripts/deploy.sh
```

Manual install:
```bash
COS_CLI_VERSION=0.1.1
pipx install --force "https://github.com/nirm3l/constructos/releases/download/cos-v${COS_CLI_VERSION}/constructos_cli-${COS_CLI_VERSION}-py3-none-any.whl"
cos --help
```
