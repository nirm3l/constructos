param(
    [string]$InstallDir = "",
    [string]$ComposeProjectName = "",
    [string]$RemoveAppData = "false",
    [string]$RemoveImages = "false",
    [string]$RemoveInstallDir = "true",
    [string]$UninstallCos = "true"
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-WarnMessage {
    param([string]$Message)
    Write-Warning $Message
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Test-IsTruthy {
    param([object]$Value)

    switch (("$Value").Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        default { return $false }
    }
}

function Resolve-InstallDir {
    param([string]$RawValue)

    $candidate = ([string]$RawValue).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $scriptPath = $MyInvocation.ScriptName
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            return (Get-Location).Path
        }
        return (Split-Path -Parent $scriptPath)
    }

    if ($candidate.StartsWith("~/") -or $candidate.StartsWith("~\")) {
        $candidate = Join-Path $HOME $candidate.Substring(2)
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-ComposeProjectName {
    param(
        [string]$Requested,
        [string]$ResolvedInstallDir
    )

    $explicit = ([string]$Requested).Trim()
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return $explicit
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        try {
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) {
                $lines = & docker ps -a --format '{{.Label "com.docker.compose.project"}} {{.Image}}' 2>$null
                foreach ($line in ($lines | Sort-Object -Unique)) {
                    if ($line -match '^(?<project>\S+)\s+ghcr\.io/nirm3l/constructos-(task-app|mcp-tools):') {
                        return $Matches["project"]
                    }
                }
            }
        }
        catch {
        }
    }

    return (Split-Path -Leaf $ResolvedInstallDir)
}

function Remove-LabeledResources {
    param(
        [string]$ProjectName,
        [bool]$WithVolumes
    )

    $containers = @(& docker ps -aq --filter "label=com.docker.compose.project=$ProjectName" 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($containers.Count -gt 0) {
        Write-Info "Removing containers for project $ProjectName..."
        & docker rm -f @containers *> $null
    }
    else {
        Write-Info "No containers found for project $ProjectName."
    }

    $networks = @(& docker network ls -q --filter "label=com.docker.compose.project=$ProjectName" 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($networks.Count -gt 0) {
        Write-Info "Removing networks for project $ProjectName..."
        & docker network rm @networks *> $null
    }

    if ($WithVolumes) {
        $volumes = @(& docker volume ls -q --filter "label=com.docker.compose.project=$ProjectName" 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($volumes.Count -gt 0) {
            Write-Info "Removing named volumes for project $ProjectName..."
            & docker volume rm @volumes *> $null
        }
    }
}

function Remove-ConstructosImages {
    $images = @(& docker images --format '{{.Repository}}:{{.Tag}}' 2>$null | Where-Object {
        $_ -match '^ghcr\.io/nirm3l/constructos-(task-app|mcp-tools):'
    })

    if ($images.Count -eq 0) {
        Write-Info "No Constructos images found to remove."
        return
    }

    Write-Info "Removing Constructos images..."
    & docker image rm @images *> $null
}

function Uninstall-CosCli {
    if (-not (Test-IsTruthy $UninstallCos)) {
        return
    }
    if (-not (Get-Command pipx -ErrorAction SilentlyContinue)) {
        Write-WarnMessage "pipx is not available; skipping COS CLI uninstall."
        return
    }

    try {
        $pipxList = & pipx list --short 2>$null
    }
    catch {
        $pipxList = @()
    }

    if (-not ($pipxList | Where-Object { $_.Trim() -eq "constructos-cli" })) {
        Write-Info "COS CLI is not installed through pipx."
        return
    }

    Write-Info "Uninstalling COS CLI..."
    & pipx uninstall constructos-cli *> $null
}

$resolvedInstallDir = Resolve-InstallDir -RawValue $InstallDir
$projectName = Resolve-ComposeProjectName -Requested $ComposeProjectName -ResolvedInstallDir $resolvedInstallDir

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-WarnMessage "Docker is not installed or not in PATH; skipping container cleanup."
}
else {
    try {
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            Remove-LabeledResources -ProjectName $projectName -WithVolumes:(Test-IsTruthy $RemoveAppData)
        }
        else {
            Write-WarnMessage "Docker daemon is not reachable; skipping container cleanup."
        }
    }
    catch {
        Write-WarnMessage "Docker daemon is not reachable; skipping container cleanup."
    }
}

if (Test-IsTruthy $RemoveImages) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        try {
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) {
                Remove-ConstructosImages
            }
            else {
                Write-WarnMessage "Docker is unavailable; skipping image removal."
            }
        }
        catch {
            Write-WarnMessage "Docker is unavailable; skipping image removal."
        }
    }
    else {
        Write-WarnMessage "Docker is unavailable; skipping image removal."
    }
}

Uninstall-CosCli

$deployEnvPath = Join-Path $resolvedInstallDir ".deploy.env"
if (Test-Path -LiteralPath $deployEnvPath) {
    Remove-Item -LiteralPath $deployEnvPath -Force -ErrorAction SilentlyContinue
}

if (Test-IsTruthy $RemoveInstallDir) {
    if (Test-Path -LiteralPath $resolvedInstallDir) {
        Write-Info "Removing install directory $resolvedInstallDir..."
        $parentDir = Split-Path -Parent $resolvedInstallDir
        $currentDir = (Get-Location).Path
        if ($currentDir -eq $resolvedInstallDir -or $currentDir.StartsWith("$resolvedInstallDir\")) {
            Set-Location $parentDir
        }
        Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force
    }
    else {
        Write-Info "Install directory not found: $resolvedInstallDir"
    }
}
else {
    Write-Info "Preserving install directory: $resolvedInstallDir"
}

Write-Host ""
Write-Info "Constructos uninstall completed."
Write-Info "Project name: $projectName"
if (-not (Test-IsTruthy $RemoveAppData)) {
    Write-Info "Named volumes were preserved. Set REMOVE_APP_DATA=true to remove them."
}
if (-not (Test-IsTruthy $RemoveImages)) {
    Write-Info "Images were preserved. Set REMOVE_IMAGES=true to remove them."
}
