# Constructos Client Deployment

This repository contains the client-facing deployment package only.

## One-liner install
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main INSTALL_COS=true AUTO_DEPLOY=1 bash
```

## Manual install
```bash
git clone https://github.com/nirm3l/constructos.git
cd constructos
ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main bash ./install.sh
# or: set LICENSE_SERVER_TOKEN manually in .env, then deploy
IMAGE_TAG=main bash ./scripts/deploy.sh
```

## Runtime profiles
- `DEPLOY_TARGET=auto|base|ubuntu-gpu|macos-m4` (default: `auto`)
- `IMAGE_TAG=<tag>` (default: `main`)
- `ACTIVATION_CODE` (recommended)
- `LICENSE_SERVER_TOKEN` (manual fallback)
- `CODEX_CONFIG_FILE` (default: `./codex.config.toml`)
- `CODEX_AUTH_FILE` (default: `${HOME}/.codex/auth.json`)
- `INSTALL_COS=true|false` (default: `true`)
- `COS_INSTALL_METHOD=pipx|link` (default: `pipx`)
- `INSTALL_OLLAMA=auto|true|false` (default: `auto`)

`INSTALL_OLLAMA` behavior:
- `auto`: install Ollama only on macOS hosts.
- `true`: try to install Ollama on any host (currently automated only for macOS).
- `false`: skip Ollama installation.

Deploy behavior by target:
- `macos-m4`: app uses host Ollama at `http://host.docker.internal:11434`.
- `base` and `ubuntu-gpu`: Ollama runs as a Docker service (`ollama`).

## Default GHCR images
- `ghcr.io/nirm3l/constructos-task-app:<tag>`
- `ghcr.io/nirm3l/constructos-mcp-tools:<tag>`

## Codex host files
- `task-app` mounts a repository-scoped Codex config file (`./codex.config.toml` by default) to `/home/app/.codex/config.toml`.
- `task-app` mounts your Codex auth file (`${HOME}/.codex/auth.json` by default) to `/home/app/.codex/auth.json`.
- Override either path with `CODEX_CONFIG_FILE` or `CODEX_AUTH_FILE` in `.env` or shell env before deploy.

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

Manual install:
```bash
pipx install --force "git+https://github.com/nirm3l/constructos.git@main#subdirectory=tools/cos"
cos --help
```
