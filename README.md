# Constructos Client Deployment

This repository contains the public deployment package for Constructos.

## Repository Layout
```text
.
├── install.sh
├── install.ps1
├── index.sh
├── scripts/
│   └── deploy.sh
├── compose/
│   ├── base/
│   │   └── app.yml
│   ├── platforms/
│   │   ├── macos-m4.yml
│   │   ├── ubuntu-gpu.yml
│   │   └── windows.yml
│   ├── ollama/
│   │   ├── disabled.yml
│   │   ├── gpu-dri.yml
│   │   ├── gpu-nvidia.yml
│   │   ├── host.yml
│   │   └── host-linux.yml
│   └── integrations/
│       └── jira-mcp.yml
├── .env.example
├── .env.jira-mcp.example
└── codex.config.toml
```

## Quick Start
Linux/macOS:
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main INSTALL_COS=true AUTO_DEPLOY=1 bash
```

Windows PowerShell (native):
```powershell
$env:ACTIVATION_CODE='ACT-XXXX-XXXX-XXXX-XXXX-XXXX'
$env:IMAGE_TAG='main'
$env:INSTALL_COS='true'
$env:AUTO_DEPLOY='1'
iwr -UseBasicParsing https://raw.githubusercontent.com/nirm3l/constructos/main/install.ps1 | iex
```

## Manual Install
Linux/macOS:
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

## Runtime Configuration
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

`INSTALL_OLLAMA`:
- `auto`: prompt when Ollama is missing, then continue with/without support.
- `true`: try to install Ollama on host (automated on macOS and Windows when package manager is available).
- `false`: skip Ollama installation.

`DEPLOY_OLLAMA_MODE`:
- `auto`: chooses in order `docker-gpu -> host -> docker` (on macOS profile: fixed to host unless `none`).
- `docker`: run Ollama as a Docker service (CPU mode).
- `docker-gpu`: prefer Docker GPU mode; if unavailable, deploy falls back to `host` then `docker`.
- `host`: use host Ollama at `http://host.docker.internal:11434`.
- `none`: skip Ollama service entirely.

Platform defaults:
- `macos-m4`: fixed to host Ollama (unless mode is `none`).
- `windows-desktop` and Linux targets (`base`/`ubuntu-gpu`): support both Docker and host Ollama modes.

## Default GHCR Images
- `ghcr.io/nirm3l/constructos-task-app:<tag>`
- `ghcr.io/nirm3l/constructos-mcp-tools:<tag>`

## Codex Host Files
- `task-app` mounts `CODEX_CONFIG_FILE` to `/home/app/.codex/config.toml`.
- `task-app` mounts `CODEX_AUTH_FILE` to `/home/app/.codex/auth.json`.
- Override either path with `CODEX_CONFIG_FILE` or `CODEX_AUTH_FILE` in `.env` or shell env before deploy.
- If `CODEX_AUTH_FILE` is missing, deploy can bootstrap auth with `codex login --device-auth` in a temporary container and persist the result on host.

## Optional Integration: Jira MCP
1. Create local env file:
```bash
cp .env.jira-mcp.example .env.jira-mcp
```
2. Set Jira credentials in `.env.jira-mcp`.
3. Start Jira MCP:
```bash
docker compose -p constructos-jira-mcp -f compose/integrations/jira-mcp.yml up -d
```

## COS CLI
`install.sh` installs `cos` by default as a best-effort step.

Disable automatic COS install:
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX INSTALL_COS=false bash
```

Skip Ollama installation:
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX INSTALL_OLLAMA=false bash
```

Force host Ollama mode:
```bash
IMAGE_TAG=main DEPLOY_OLLAMA_MODE=host bash ./scripts/deploy.sh
```

Force Docker Ollama with GPU:
```bash
IMAGE_TAG=main DEPLOY_OLLAMA_MODE=docker-gpu bash ./scripts/deploy.sh
```

Disable Ollama:
```bash
IMAGE_TAG=main DEPLOY_OLLAMA_MODE=none bash ./scripts/deploy.sh
```

Manual COS install:
```bash
COS_CLI_VERSION=0.1.2
pipx install --force "https://github.com/nirm3l/constructos/releases/download/cos-v${COS_CLI_VERSION}/constructos_cli-${COS_CLI_VERSION}-py3-none-any.whl"
cos --help
```
