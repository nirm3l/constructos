param(
    [string]$RepoOwner = "",
    [string]$RepoName = "",
    [string]$RepoRef = "",
    [string]$InstallDir = "",
    [string]$ImageTag = "",
    [string]$LicenseInstallationId = "",
    [string]$LicenseServerToken = "",
    [string]$ActivationCode = "",
    [string]$LicenseServerUrl = "",
    [string]$AutoDeploy = "",
    [string]$InstallCos = "",
    [string]$CosInstallMethod = "",
    [string]$CosCliVersion = "",
    [string]$CosCliWheelUrl = "",
    [string]$InstallOllama = "",
    [string]$DeployOllamaMode = "",
    [string]$DeployWithOllama = "",
    [string]$CodexConfigFile = "",
    [string]$CodexAuthFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SettingValue {
    param(
        [string]$Current,
        [string]$EnvName,
        [string]$DefaultValue
    )
    $currentText = [string]$Current
    if (-not [string]::IsNullOrWhiteSpace($currentText)) {
        return $currentText.Trim()
    }
    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace([string]$envValue)) {
        return ([string]$envValue).Trim()
    }
    return $DefaultValue
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-WarnMessage {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Resolve-InstallationStateFile {
    return Join-Path $HOME ".constructos/license-installation-id"
}

function Read-PersistedInstallationId {
    $stateFile = Resolve-InstallationStateFile
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return ""
    }
    return ([string](Get-Content -LiteralPath $stateFile -Raw)).Trim()
}

function Persist-InstallationId {
    param([string]$InstallationId)

    $stateFile = Resolve-InstallationStateFile
    $stateDir = Split-Path -Parent $stateFile
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    Set-Content -LiteralPath $stateFile -Value $InstallationId -Encoding UTF8
}

function Resolve-HostMachineId {
    $hostOs = Resolve-HostOperatingSystem

    switch ($hostOs) {
        "windows" {
            try {
                return ([string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid).Trim()
            }
            catch {
                return ""
            }
        }
        "linux" {
            foreach ($candidate in @("/etc/machine-id", "/var/lib/dbus/machine-id")) {
                if (Test-Path -LiteralPath $candidate) {
                    return ([string](Get-Content -LiteralPath $candidate -Raw)).Trim()
                }
            }
            return ""
        }
        "macos" {
            $ioregCommand = Get-Command -Name "ioreg" -ErrorAction SilentlyContinue
            if ($null -eq $ioregCommand) {
                return ""
            }
            try {
                $output = & $ioregCommand.Path -rd1 -c IOPlatformExpertDevice 2>$null
                foreach ($line in $output) {
                    if ([string]$line -match '"IOPlatformUUID"\s*=\s*"([^"]+)"') {
                        return ([string]$Matches[1]).Trim()
                    }
                }
            }
            catch {
                return ""
            }
            return ""
        }
        default {
            return ""
        }
    }
}

function Derive-InstallationIdFromMachineId {
    param([string]$MachineId)

    $normalizedMachineId = ([string]$MachineId).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedMachineId)) {
        return ""
    }

    $payload = [System.Text.Encoding]::UTF8.GetBytes("constructos:$normalizedMachineId")
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digestBytes = $sha256.ComputeHash($payload)
    }
    finally {
        $sha256.Dispose()
    }
    $digest = -join ($digestBytes | ForEach-Object { $_.ToString("x2") })
    return "inst-$($digest.Substring(0, 32))"
}

function Ensure-LicenseInstallationId {
    param([string]$ConfiguredValue)

    $explicitId = ([string]$ConfiguredValue).Trim()
    if (-not [string]::IsNullOrWhiteSpace($explicitId)) {
        Persist-InstallationId -InstallationId $explicitId
        return $explicitId
    }

    $machineId = Resolve-HostMachineId
    $derivedId = Derive-InstallationIdFromMachineId -MachineId $machineId
    if (-not [string]::IsNullOrWhiteSpace($derivedId)) {
        Persist-InstallationId -InstallationId $derivedId
        Write-Info "Resolved stable license installation id from host machine id."
        return $derivedId
    }

    $persistedId = Read-PersistedInstallationId
    if (-not [string]::IsNullOrWhiteSpace($persistedId)) {
        Write-Info "Reusing persisted license installation id from $(Resolve-InstallationStateFile)."
        return $persistedId
    }

    $fallbackId = "inst-$([Guid]::NewGuid().ToString().ToLowerInvariant())"
    Persist-InstallationId -InstallationId $fallbackId
    Write-WarnMessage "Host machine id was unavailable; generated and persisted a fallback license installation id."
    return $fallbackId
}

function Test-CommandAvailable {
    param([string]$Name)
    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Normalize-TruthValue {
    param([string]$Value)
    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    switch ($normalized) {
        "1" { return "true" }
        "true" { return "true" }
        "yes" { return "true" }
        "on" { return "true" }
        "0" { return "false" }
        "false" { return "false" }
        "no" { return "false" }
        "off" { return "false" }
        "" { return "auto" }
        "auto" { return "auto" }
        default { return "invalid" }
    }
}

function Test-IsTruthy {
    param([string]$Value)
    return (Normalize-TruthValue -Value $Value) -eq "true"
}

function Normalize-OllamaMode {
    param([string]$Value)
    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    switch ($normalized) {
        "" { return "auto" }
        "auto" { return "auto" }
        "docker" { return "docker" }
        "docker-gpu" { return "docker-gpu" }
        "host" { return "host" }
        "none" { return "none" }
        "1" { return "docker" }
        "true" { return "docker" }
        "yes" { return "docker" }
        "on" { return "docker" }
        "0" { return "none" }
        "false" { return "none" }
        "no" { return "none" }
        "off" { return "none" }
        default { return "invalid" }
    }
}

function Resolve-HostOperatingSystem {
    if ($IsWindows) {
        return "windows"
    }
    if ($IsMacOS) {
        return "macos"
    }
    if ($IsLinux) {
        return "linux"
    }
    return "unknown"
}

function Resolve-AbsolutePath {
    param(
        [string]$PathValue,
        [string]$BasePath
    )

    $raw = ([string]$PathValue).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($raw)) {
        return [System.IO.Path]::GetFullPath($raw)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $raw))
}

function Normalize-ComposePath {
    param([string]$PathValue)
    return ([string]$PathValue).Replace("\\", "/")
}

function Upsert-EnvValue {
    param(
        [string]$FilePath,
        [string]$Key,
        [string]$Value
    )

    $existing = @()
    if (Test-Path -LiteralPath $FilePath) {
        $existing = Get-Content -LiteralPath $FilePath
    }

    $pattern = "^\s*" + [regex]::Escape($Key) + "="
    $updated = New-Object System.Collections.Generic.List[string]
    $found = $false

    foreach ($line in $existing) {
        if ($line -match $pattern) {
            $updated.Add("$Key=$Value")
            $found = $true
        }
        else {
            $updated.Add($line)
        }
    }

    if (-not $found) {
        $updated.Add("$Key=$Value")
    }

    Set-Content -LiteralPath $FilePath -Value $updated -Encoding UTF8
}

function Prepare-EnvFile {
    param([string]$InstallPath)

    $envPath = Join-Path $InstallPath ".env"
    $examplePath = Join-Path $InstallPath ".env.example"

    if (Test-Path -LiteralPath $envPath) {
        return $envPath
    }

    if (Test-Path -LiteralPath $examplePath) {
        Copy-Item -LiteralPath $examplePath -Destination $envPath -Force
    }
    else {
        New-Item -Path $envPath -ItemType File -Force | Out-Null
    }

    return $envPath
}

function Get-DockerInstallHint {
    return "Install Docker Desktop and start it before deploy."
}

function Ensure-DockerAvailable {
    param([bool]$Required)

    if (-not (Test-CommandAvailable -Name "docker")) {
        if ($Required) {
            throw "Docker is required for deployment but was not found. $(Get-DockerInstallHint)"
        }
        Write-WarnMessage "Docker is not installed. You must install Docker before running deploy."
        Write-WarnMessage (Get-DockerInstallHint)
        return $false
    }

    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($Required) {
            throw "Docker Compose plugin is required but unavailable. $(Get-DockerInstallHint)"
        }
        Write-WarnMessage "Docker Compose plugin is missing. Deploy will fail until it is installed."
        return $false
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($Required) {
            throw "Docker is installed but the daemon is not reachable. Start Docker and retry."
        }
        Write-WarnMessage "Docker daemon is not reachable right now. Start Docker before running deploy."
        return $false
    }

    return $true
}

function Test-InteractiveSession {
    try {
        if (-not [Environment]::UserInteractive) {
            return $false
        }
        $null = $Host.UI.RawUI
        return $true
    }
    catch {
        return $false
    }
}

function Test-HostOllamaReachable {
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 2 -UseBasicParsing
        return $true
    }
    catch {
        if ($_.Exception -and $_.Exception.Response) {
            return $true
        }
        return $false
    }
}

function Ensure-HostOllamaReachable {
    param(
        [int]$TimeoutSeconds = 20
    )

    if (Test-HostOllamaReachable) {
        return $true
    }

    if (Test-CommandAvailable -Name "ollama") {
        try {
            Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            # Best-effort start only.
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-HostOllamaReachable) {
            return $true
        }
        Start-Sleep -Seconds 1
    }

    return $false
}

function Resolve-RequestedOllamaMode {
    param(
        [string]$DeployOllamaMode,
        [string]$DeployWithOllama
    )

    $requested = [string]$DeployOllamaMode
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = [string]$DeployWithOllama
    }
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = "auto"
    }

    $normalized = Normalize-OllamaMode -Value $requested
    if ($normalized -eq "invalid") {
        Write-WarnMessage "Unsupported DEPLOY_OLLAMA_MODE value. Falling back to auto."
        return "auto"
    }
    return $normalized
}

function Prompt-ForOllamaPreference {
    param(
        [string]$RequestedMode,
        [ref]$InstallOllama
    )

    if ($RequestedMode -ne "auto") {
        return $RequestedMode
    }

    if (Test-CommandAvailable -Name "ollama") {
        return $RequestedMode
    }

    $normalizedInstall = Normalize-TruthValue -Value $InstallOllama.Value
    if ($normalizedInstall -eq "invalid") {
        Write-WarnMessage "Unsupported INSTALL_OLLAMA value. Falling back to auto."
        $InstallOllama.Value = "auto"
        $normalizedInstall = "auto"
    }

    if ($normalizedInstall -ne "auto") {
        return $RequestedMode
    }

    Write-WarnMessage "Ollama is not currently installed on this host."
    Write-Host "Ollama powers local embeddings and AI retrieval/context features in Constructos."

    if (-not (Test-InteractiveSession)) {
        Write-WarnMessage "Non-interactive shell detected; keeping DEPLOY_OLLAMA_MODE=auto."
        return $RequestedMode
    }

    while ($true) {
        Write-Host "Choose how to continue:"
        Write-Host "1) Continue with Ollama support (host Ollama, recommended)"
        Write-Host "2) Continue without Ollama (AI embedding features will be limited)"
        $choice = Read-Host "Select [1/2]"
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1") {
            $InstallOllama.Value = "true"
            return "host"
        }
        if ($choice -eq "2") {
            $InstallOllama.Value = "false"
            Write-WarnMessage "Continuing without Ollama support."
            return "none"
        }
        Write-Host "Please enter 1 or 2."
    }
}

function Should-InstallOllama {
    param(
        [string]$ResolvedMode,
        [string]$InstallOllama
    )

    if ($ResolvedMode -in @("none", "docker", "docker-gpu")) {
        return $false
    }

    if ($ResolvedMode -eq "host" -and (Normalize-TruthValue -Value $InstallOllama) -eq "auto") {
        return $true
    }

    return (Normalize-TruthValue -Value $InstallOllama) -eq "true"
}

function Resolve-RuntimeOllamaMode {
    param([string]$RequestedMode)

    switch ($RequestedMode) {
        "none" { return "none" }
        "docker" { return "docker" }
        "docker-gpu" {
            Write-WarnMessage "docker-gpu is not currently auto-configured on Windows. Falling back to docker mode."
            return "docker"
        }
        "host" {
            if (Ensure-HostOllamaReachable -TimeoutSeconds 20) {
                return "host"
            }
            Write-WarnMessage "Host Ollama is not reachable on http://localhost:11434 right now."
            Write-WarnMessage "Keeping host mode (docker Ollama image will not be pulled). Start Ollama and retry if embeddings are unavailable."
            return "host"
        }
        default {
            if (Ensure-HostOllamaReachable -TimeoutSeconds 12) {
                return "host"
            }
            if (Test-CommandAvailable -Name "ollama") {
                Write-WarnMessage "Host Ollama is installed but not reachable yet on http://localhost:11434."
                Write-WarnMessage "Keeping host mode (docker Ollama image will not be pulled). Start Ollama and retry if embeddings are unavailable."
                return "host"
            }
            return "docker"
        }
    }
}

function Install-OllamaIfNeeded {
    param(
        [string]$ResolvedMode,
        [string]$InstallOllama
    )

    if (-not (Should-InstallOllama -ResolvedMode $ResolvedMode -InstallOllama $InstallOllama)) {
        Write-Info "Skipping Ollama installation (INSTALL_OLLAMA=$InstallOllama)."
        return
    }

    if (Test-CommandAvailable -Name "ollama") {
        Write-Info "Ollama is already installed."
        return
    }

    $wingetCommand = Get-Command -Name "winget", "winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $wingetCommand) {
        Write-WarnMessage "winget was not found; cannot auto-install Ollama on Windows."
        Write-Info "Install manually from https://ollama.com/download"
        return
    }

    Write-Info "Installing Ollama on Windows via winget..."
    & $wingetCommand.Path install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-WarnMessage "Ollama installation failed; continuing without blocking deployment."
        Write-Info "Install manually from https://ollama.com/download"
        return
    }

    Write-Info "Ollama installation completed."
}

function Install-CosCliIfNeeded {
    param(
        [string]$InstallPath,
        [string]$InstallCos,
        [string]$Method,
        [string]$CosCliVersion,
        [string]$CosCliWheelUrl
    )

    if (-not (Test-IsTruthy -Value $InstallCos)) {
        Write-Info "Skipping COS CLI installation (INSTALL_COS=$InstallCos)."
        return
    }

    if ([string]::IsNullOrWhiteSpace($CosCliWheelUrl)) {
        Write-WarnMessage "COS_CLI_WHEEL_URL is empty; skipping COS CLI installation."
        return
    }

    if (-not (Test-CommandAvailable -Name "python") -and -not (Test-CommandAvailable -Name "python3")) {
        Write-WarnMessage "Python is not installed; skipping automatic COS CLI installation."
        Write-Info "Install Python 3 first, then run: pipx install --force `"$CosCliWheelUrl`""
        return
    }

    $effectiveMethod = ([string]$Method).Trim().ToLowerInvariant()
    if ($effectiveMethod -ne "pipx") {
        Write-WarnMessage "COS_INSTALL_METHOD=$Method is not supported for artifact installs. Falling back to pipx."
        $effectiveMethod = "pipx"
    }

    if (-not (Test-CommandAvailable -Name "pipx")) {
        Write-WarnMessage "pipx not found; skipping automatic COS CLI installation."
        Write-Info "Install pipx, then run: pipx install --force `"$CosCliWheelUrl`""
        return
    }

    $resolvedVersion = if ([string]::IsNullOrWhiteSpace($CosCliVersion)) { "latest" } else { $CosCliVersion }
    Write-Info "Installing COS CLI (constructos-cli $resolvedVersion) from artifact..."
    & pipx install --force $CosCliWheelUrl
    if ($LASTEXITCODE -ne 0) {
        Write-WarnMessage "COS CLI installation failed from $CosCliWheelUrl; continuing without blocking deployment."
        return
    }
    Write-Info "COS CLI installation completed."
    Write-Info "If 'cos' is not recognized, run 'pipx ensurepath' and open a new terminal."
}

function Wait-AppReady {
    param(
        [string]$AppUrl,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-WebRequest -Uri $AppUrl -Method Get -TimeoutSec 4 -UseBasicParsing
            return $true
        }
        catch {
            if ($_.Exception -and $_.Exception.Response) {
                return $true
            }
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

function Invoke-ConstructosDeploy {
    param(
        [string]$InstallPath,
        [string]$ImageTag,
        [string]$LicenseServerToken,
        [string]$CodexConfigFile,
        [string]$CodexAuthFile,
        [string]$RequestedOllamaMode
    )

    Ensure-DockerAvailable -Required $true | Out-Null

    $resolvedOllamaMode = Resolve-RuntimeOllamaMode -RequestedMode $RequestedOllamaMode

    $composeFiles = @("compose/base/app.yml", "compose/platforms/windows.yml")
    if (Test-Path -LiteralPath $CodexAuthFile -PathType Leaf) {
        $composeFiles += "compose/codex/auth-file.yml"
    }
    switch ($resolvedOllamaMode) {
        "host" { $composeFiles += "compose/ollama/host.yml" }
        "none" { $composeFiles += "compose/ollama/disabled.yml" }
    }

    $services = New-Object System.Collections.Generic.List[string]
    $services.Add("task-app")
    $services.Add("mcp-tools")
    if ($resolvedOllamaMode -in @("docker", "docker-gpu")) {
        $services.Add("ollama")
    }

    $dependencyServices = @("postgres", "kurrentdb", "neo4j")
    $pullServices = New-Object System.Collections.Generic.List[string]
    foreach ($serviceName in $services + $dependencyServices) {
        if (-not $pullServices.Contains($serviceName)) {
            $pullServices.Add($serviceName)
        }
    }

    $composeArgs = New-Object System.Collections.Generic.List[string]
    foreach ($file in $composeFiles) {
        $composeArgs.Add("-f")
        $composeArgs.Add($file)
    }

    $deployedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $appVersion = $ImageTag
    $appBuild = "ghcr-$ImageTag-powershell"
    $taskImage = "ghcr.io/nirm3l/constructos-task-app:$ImageTag"
    $mcpImage = "ghcr.io/nirm3l/constructos-mcp-tools:$ImageTag"

    $deployEnv = @"
APP_VERSION=$appVersion
APP_BUILD=$appBuild
APP_DEPLOYED_AT_UTC=$deployedAtUtc
TASK_APP_IMAGE=$taskImage
MCP_TOOLS_IMAGE=$mcpImage
LICENSE_SERVER_TOKEN=$LicenseServerToken
CODEX_CONFIG_FILE=$CodexConfigFile
CODEX_AUTH_FILE=$CodexAuthFile
"@

    $deployEnvPath = Join-Path $InstallPath ".deploy.env"
    Set-Content -LiteralPath $deployEnvPath -Value $deployEnv -Encoding UTF8

    Write-Info "Deploy profile: client"
    Write-Info "Version: $appVersion ($appBuild)"
    Write-Info "Target: windows-desktop"
    Write-Info "Ollama mode selected: $resolvedOllamaMode"
    Write-Info "Services: $($services -join ' ')"
    Write-Info "Pull set: $($pullServices -join ' ')"

    Push-Location $InstallPath
    try {
        Write-Info "Pulling images (first run may take several minutes)..."
        $pullArgs = @("compose") + $composeArgs + @("--env-file", ".deploy.env", "pull") + $pullServices
        & docker @pullArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Pull images failed."
        }

        if (Test-Path -LiteralPath $CodexAuthFile -PathType Leaf) {
            Write-Info "Using Codex auth file from host: $CodexAuthFile"
        }
        else {
            Write-WarnMessage "Codex authentication file was not found on host: $CodexAuthFile"
            Write-Info "Deploy will continue without mounting Codex auth. Authenticate later through the app UI if needed."
        }

        Write-Info "Starting services..."
        $upArgs = @("compose") + $composeArgs + @("--env-file", ".deploy.env", "up", "-d", "--no-build") + $services
        & docker @upArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Start services failed."
        }

        Write-Info "Deployment completed. Active services:"
        $psArgs = @("compose") + $composeArgs + @("--env-file", ".deploy.env", "ps")
        & docker @psArgs
        if ($LASTEXITCODE -ne 0) {
            Write-WarnMessage "Unable to print docker compose status."
        }
    }
    finally {
        Pop-Location
    }

    $appHost = ([string](Get-SettingValue -Current "" -EnvName "APP_HOST" -DefaultValue "localhost")).Trim()
    if ([string]::IsNullOrWhiteSpace($appHost) -or $appHost -eq "0.0.0.0" -or $appHost -eq "::") {
        $appHost = "localhost"
    }
    $appPort = ([string](Get-SettingValue -Current "" -EnvName "APP_PORT" -DefaultValue "1102")).Trim()
    $appUrl = "http://$appHost`:$appPort"

    Write-Info "Open Constructos at: $appUrl"
    Write-Info "Default admin credentials: username 'admin', password 'admin'. Change the password after first login."
    Write-Info "Waiting for Constructos to become available (up to 90s)..."
    if (Wait-AppReady -AppUrl $appUrl -TimeoutSeconds 90) {
        try {
            Start-Process $appUrl | Out-Null
            Write-Info "Opened Constructos in your default browser."
        }
        catch {
            Write-Info "If browser did not open automatically, open this URL manually."
        }
    }
    else {
        Write-WarnMessage "Constructos is not reachable yet at $appUrl."
        Write-Info "Open it manually once startup finishes."
    }

    Write-Host ""
    Write-Host "Optional integrations:"
    Write-Host "- GitHub MCP: set GITHUB_PAT in .env, then set [mcp_servers.github].enabled = true in codex.config.toml and redeploy."
    Write-Host "- Jira MCP: copy .env.jira-mcp.example to .env.jira-mcp, add credentials, then run:"
    Write-Host "  docker compose -p constructos-jira-mcp -f compose/integrations/jira-mcp.yml up -d"
}

$RepoOwner = Get-SettingValue -Current $RepoOwner -EnvName "REPO_OWNER" -DefaultValue "nirm3l"
$RepoName = Get-SettingValue -Current $RepoName -EnvName "REPO_NAME" -DefaultValue "constructos"
$RepoRef = Get-SettingValue -Current $RepoRef -EnvName "REPO_REF" -DefaultValue "main"
$InstallDir = Get-SettingValue -Current $InstallDir -EnvName "INSTALL_DIR" -DefaultValue "./constructos-client"
$ImageTag = Get-SettingValue -Current $ImageTag -EnvName "IMAGE_TAG" -DefaultValue ""
$LicenseInstallationId = Get-SettingValue -Current $LicenseInstallationId -EnvName "LICENSE_INSTALLATION_ID" -DefaultValue ""
$LicenseServerToken = Get-SettingValue -Current $LicenseServerToken -EnvName "LICENSE_SERVER_TOKEN" -DefaultValue ""
$ActivationCode = Get-SettingValue -Current $ActivationCode -EnvName "ACTIVATION_CODE" -DefaultValue ""
$LicenseServerUrl = Get-SettingValue -Current $LicenseServerUrl -EnvName "LICENSE_SERVER_URL" -DefaultValue "https://licence.constructos.dev"
$AutoDeploy = Get-SettingValue -Current $AutoDeploy -EnvName "AUTO_DEPLOY" -DefaultValue "false"
$InstallCos = Get-SettingValue -Current $InstallCos -EnvName "INSTALL_COS" -DefaultValue "true"
$CosInstallMethod = Get-SettingValue -Current $CosInstallMethod -EnvName "COS_INSTALL_METHOD" -DefaultValue "pipx"
$CosCliVersion = Get-SettingValue -Current $CosCliVersion -EnvName "COS_CLI_VERSION" -DefaultValue "0.1.4"
$defaultCosCliWheelUrl = "https://github.com/nirm3l/constructos/releases/download/cos-v{0}/constructos_cli-{0}-py3-none-any.whl" -f $CosCliVersion
$CosCliWheelUrl = Get-SettingValue -Current $CosCliWheelUrl -EnvName "COS_CLI_WHEEL_URL" -DefaultValue $defaultCosCliWheelUrl
$InstallOllama = Get-SettingValue -Current $InstallOllama -EnvName "INSTALL_OLLAMA" -DefaultValue "auto"
$DeployOllamaMode = Get-SettingValue -Current $DeployOllamaMode -EnvName "DEPLOY_OLLAMA_MODE" -DefaultValue ""
$DeployWithOllama = Get-SettingValue -Current $DeployWithOllama -EnvName "DEPLOY_WITH_OLLAMA" -DefaultValue ""
$CodexConfigFile = Get-SettingValue -Current $CodexConfigFile -EnvName "CODEX_CONFIG_FILE" -DefaultValue ""
$CodexAuthFile = Get-SettingValue -Current $CodexAuthFile -EnvName "CODEX_AUTH_FILE" -DefaultValue ""
$LicenseInstallationId = Ensure-LicenseInstallationId -ConfiguredValue $LicenseInstallationId

$requestedOllamaMode = Resolve-RequestedOllamaMode -DeployOllamaMode $DeployOllamaMode -DeployWithOllama $DeployWithOllama
$requestedOllamaMode = Prompt-ForOllamaPreference -RequestedMode $requestedOllamaMode -InstallOllama ([ref]$InstallOllama)

$null = Ensure-DockerAvailable -Required $false

$archiveUrl = "https://codeload.github.com/$RepoOwner/$RepoName/tar.gz/$RepoRef"
$tmpArchive = Join-Path ([System.IO.Path]::GetTempPath()) ("constructos-client-{0}.tar.gz" -f [Guid]::NewGuid().ToString("N"))

try {
    if ([System.IO.Path]::IsPathRooted($InstallDir)) {
        $installPath = [System.IO.Path]::GetFullPath($InstallDir)
    }
    else {
        $installPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $InstallDir))
    }

    New-Item -ItemType Directory -Path $installPath -Force | Out-Null

    Write-Info "Downloading $RepoOwner/$RepoName@$RepoRef..."
    Invoke-WebRequest -Uri $archiveUrl -OutFile $tmpArchive -UseBasicParsing

    if (-not (Test-CommandAvailable -Name "tar")) {
        throw "tar command is required but not found. Install bsdtar/tar (Git for Windows includes tar)."
    }

    & tar -xzf $tmpArchive -C $installPath --strip-components=1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract downloaded archive."
    }

    $exchangedImageTag = ""
    if ([string]::IsNullOrWhiteSpace($LicenseServerToken) -and -not [string]::IsNullOrWhiteSpace($ActivationCode)) {
        $endpoint = "{0}/v1/install/exchange" -f $LicenseServerUrl.TrimEnd("/")
        $payload = @{
            activation_code = $ActivationCode
            operating_system = (Resolve-HostOperatingSystem)
        } | ConvertTo-Json -Compress
        try {
            $response = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType "application/json" -Body $payload
        }
        catch {
            throw "Activation code exchange failed. $($_.Exception.Message)"
        }

        $token = [string]$response.license_server_token
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Activation code exchange response did not include license_server_token."
        }
        $LicenseServerToken = $token.Trim()
        $exchangedImageTag = ([string]$response.image_tag).Trim()
        Write-Info "Exchanged activation code for LICENSE_SERVER_TOKEN via $endpoint."
    }

    if ([string]::IsNullOrWhiteSpace($ImageTag)) {
        if (-not [string]::IsNullOrWhiteSpace($exchangedImageTag)) {
            $ImageTag = $exchangedImageTag
        }
        else {
            $ImageTag = "main"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LicenseServerToken)) {
        if ([string]::IsNullOrWhiteSpace($CodexConfigFile)) {
            $CodexConfigFile = "./codex.config.toml"
        }
        if ([string]::IsNullOrWhiteSpace($CodexAuthFile)) {
            $CodexAuthFile = "$HOME/.codex/auth.json"
        }

        $resolvedConfig = Resolve-AbsolutePath -PathValue $CodexConfigFile -BasePath $installPath
        $resolvedAuth = Resolve-AbsolutePath -PathValue $CodexAuthFile -BasePath $installPath
        $CodexConfigFile = $resolvedConfig
        $CodexAuthFile = $resolvedAuth
    }

    $envPath = Prepare-EnvFile -InstallPath $installPath
    Upsert-EnvValue -FilePath $envPath -Key "IMAGE_TAG" -Value $ImageTag
    Upsert-EnvValue -FilePath $envPath -Key "LICENSE_INSTALLATION_ID" -Value $LicenseInstallationId
    Upsert-EnvValue -FilePath $envPath -Key "HOST_OPERATING_SYSTEM" -Value (Resolve-HostOperatingSystem)
    Upsert-EnvValue -FilePath $envPath -Key "DEPLOY_OLLAMA_MODE" -Value $requestedOllamaMode
    Upsert-EnvValue -FilePath $envPath -Key "DEPLOY_TARGET" -Value "windows-desktop"
    if (-not [string]::IsNullOrWhiteSpace($LicenseServerToken)) {
        Upsert-EnvValue -FilePath $envPath -Key "LICENSE_SERVER_TOKEN" -Value $LicenseServerToken
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexConfigFile)) {
        Upsert-EnvValue -FilePath $envPath -Key "CODEX_CONFIG_FILE" -Value (Normalize-ComposePath -PathValue $CodexConfigFile)
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexAuthFile)) {
        Upsert-EnvValue -FilePath $envPath -Key "CODEX_AUTH_FILE" -Value (Normalize-ComposePath -PathValue $CodexAuthFile)
    }
    Write-Info "Prepared $envPath with deploy settings."

    Install-OllamaIfNeeded -ResolvedMode $requestedOllamaMode -InstallOllama $InstallOllama
    Install-CosCliIfNeeded -InstallPath $installPath -InstallCos $InstallCos -Method $CosInstallMethod -CosCliVersion $CosCliVersion -CosCliWheelUrl $CosCliWheelUrl
    Write-Info "Selected Ollama deploy mode: $requestedOllamaMode"

    if (Test-IsTruthy -Value $AutoDeploy) {
        if ([string]::IsNullOrWhiteSpace($LicenseServerToken)) {
            throw "AUTO_DEPLOY requires LICENSE_SERVER_TOKEN or ACTIVATION_CODE."
        }

        if ([string]::IsNullOrWhiteSpace($CodexConfigFile)) {
            $CodexConfigFile = Resolve-AbsolutePath -PathValue "./codex.config.toml" -BasePath $installPath
        }
        if ([string]::IsNullOrWhiteSpace($CodexAuthFile)) {
            $CodexAuthFile = Resolve-AbsolutePath -PathValue "$HOME/.codex/auth.json" -BasePath $installPath
        }

        Invoke-ConstructosDeploy -InstallPath $installPath -ImageTag $ImageTag -LicenseServerToken $LicenseServerToken -CodexConfigFile (Normalize-ComposePath -PathValue $CodexConfigFile) -CodexAuthFile (Normalize-ComposePath -PathValue $CodexAuthFile) -RequestedOllamaMode $requestedOllamaMode
        exit 0
    }

    Write-Host ""
    Write-Info "Constructos client files installed to: $installPath"
    Write-Info "Source: $archiveUrl"
    Write-Info "After deploy, open Constructos at: http://localhost:1102"
    Write-Info "Default admin credentials: username 'admin', password 'admin'. Change the password after first login."
    Write-Host ""
    Write-Host "Optional integrations:"
    Write-Host "- GitHub MCP: set GITHUB_PAT in .env, then set [mcp_servers.github].enabled = true in codex.config.toml and redeploy."
    Write-Host "- Jira MCP: copy .env.jira-mcp.example to .env.jira-mcp, add credentials, then run:"
    Write-Host "  docker compose -p constructos-jira-mcp -f compose/integrations/jira-mcp.yml up -d"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "1) Set-Location `"$installPath`""
    if (-not [string]::IsNullOrWhiteSpace($LicenseServerToken)) {
        Write-Host "2) .env is already prepared with IMAGE_TAG and LICENSE_SERVER_TOKEN"
        Write-Host "3) .\\scripts\\deploy.sh (optional if you have bash) or rerun install.ps1 with AUTO_DEPLOY=1"
        Write-Host "4) Run 'cos --help' (if COS CLI was installed)"
    }
    else {
        Write-Host "2) .env is already prepared with IMAGE_TAG and LICENSE_INSTALLATION_ID"
        Write-Host "3) Set LICENSE_SERVER_TOKEN in .env"
        Write-Host "4) Rerun install.ps1 with AUTO_DEPLOY=1"
        Write-Host "5) Run 'cos --help' (if COS CLI was installed)"
    }
}
finally {
    if (Test-Path -LiteralPath $tmpArchive) {
        Remove-Item -LiteralPath $tmpArchive -Force -ErrorAction SilentlyContinue
    }
}
