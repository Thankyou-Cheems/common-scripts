[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("windows", "wsl")]
    [string]$Mode,

    [switch]$RestartApp
)

$ErrorActionPreference = "Stop"

$UserProfile = [Environment]::GetFolderPath("UserProfile")
$ConfigPath = Join-Path $UserProfile ".codex\config.toml"

$WindowsCodexCli = Join-Path $UserProfile "AppData\Local\Programs\OpenAI\Codex\bin\codex.exe"
$WslCodexShim = Join-Path $UserProfile "AppData\Local\pnpm\bin\codex"

function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)][string]$WindowsPath
    )

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch "^([A-Za-z]):\\(.*)$") {
        throw "Cannot convert non-drive path to WSL path: $WindowsPath"
    }

    $drive = $matches[1].ToLowerInvariant()
    $path = $matches[2] -replace "\\", "/"
    return "/mnt/$drive/$path"
}

function Get-LatestNodeRepl {
    $runtimeRoot = Join-Path $UserProfile "AppData\Local\OpenAI\Codex\runtimes\cua_node"
    if (-not (Test-Path -LiteralPath $runtimeRoot)) {
        throw "Missing Codex node runtime directory: $runtimeRoot"
    }

    $candidate = Get-ChildItem -LiteralPath $runtimeRoot -Filter node_repl.exe -Recurse -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $candidate) {
        throw "Missing node_repl.exe under: $runtimeRoot"
    }

    return $candidate.FullName
}

$WindowsNodeRepl = Get-LatestNodeRepl
$WslNodeRepl = ConvertTo-WslPath -WindowsPath $WindowsNodeRepl

function Set-FirstTomlLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $regex.IsMatch($Text)) {
        throw "Could not find config line matching: $Pattern"
    }
    return $regex.Replace($Text, $Replacement, 1)
}

function Set-EnvTomlLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $line = "$Key = '$Value'"
    $pattern = "(?m)^$([regex]::Escape($Key))\s*=.*$"
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, $line)
    }

    $envHeader = "[mcp_servers.node_repl.env]"
    $index = $Text.IndexOf($envHeader, [StringComparison]::Ordinal)
    if ($index -lt 0) {
        throw "Could not find $envHeader in $ConfigPath"
    }

    $lineStart = $Text.IndexOf("`n", $index)
    if ($lineStart -lt 0) {
        return "$Text`n$line`n"
    }

    return $Text.Insert($lineStart + 1, "$line`n")
}

function Remove-TomlLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Key))\s*=.*\r?\n?", "")
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Missing config: $ConfigPath"
}

if ($Mode -eq "windows") {
    if (-not (Test-Path -LiteralPath $WindowsCodexCli)) {
        throw "Missing Windows Codex CLI: $WindowsCodexCli"
    }
    if (-not (Test-Path -LiteralPath $WindowsNodeRepl)) {
        throw "Missing Windows node_repl: $WindowsNodeRepl"
    }

    $RunInWsl = "false"
    $NodeReplCommand = $WindowsNodeRepl
    $ConfigCodexCli = $WindowsCodexCli
    $UserCodexCli = $WindowsCodexCli
    $UserWslEnv = $null
} else {
    if (-not (Test-Path -LiteralPath $WslCodexShim)) {
        throw "Missing WSL Codex shim: $WslCodexShim"
    }
    $wslCheck = & wsl.exe sh -lc "command -v codex >/dev/null && codex --version >/dev/null"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL codex is not available. Run: wsl.exe sh -lc 'npm i -g @openai/codex'"
    }

    $RunInWsl = "true"
    $NodeReplCommand = $WslNodeRepl
    $ConfigCodexCli = $WslCodexShim
    $UserCodexCli = $WslCodexShim
    $UserWslEnv = "WT_SESSION:WT_PROFILE_ID:CODEX_CLI_PATH/w"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$ConfigPath.bak-runtime-$timestamp"
Copy-Item -LiteralPath $ConfigPath -Destination $backupPath

$content = Get-Content -LiteralPath $ConfigPath -Raw
$content = Set-FirstTomlLine -Text $content -Pattern "^runCodexInWindowsSubsystemForLinux\s*=.*$" -Replacement "runCodexInWindowsSubsystemForLinux = $RunInWsl"
$content = Set-FirstTomlLine -Text $content -Pattern "^command\s*=.*$" -Replacement "command = '$NodeReplCommand'"
$content = Set-EnvTomlLine -Text $content -Key "CODEX_CLI_PATH" -Value $ConfigCodexCli

if ($Mode -eq "wsl") {
    $content = Set-EnvTomlLine -Text $content -Key "WSLENV" -Value $UserWslEnv
} else {
    $content = Remove-TomlLine -Text $content -Key "WSLENV"
}

Set-Content -LiteralPath $ConfigPath -Value $content -NoNewline

& reg.exe add "HKCU\Environment" /v "CODEX_CLI_PATH" /t REG_SZ /d $UserCodexCli /f | Out-Null
$env:CODEX_CLI_PATH = $UserCodexCli

if ($UserWslEnv) {
    & reg.exe add "HKCU\Environment" /v "WSLENV" /t REG_SZ /d $UserWslEnv /f | Out-Null
    $env:WSLENV = $UserWslEnv
} else {
    & reg.exe delete "HKCU\Environment" /v "WSLENV" /f 2>$null | Out-Null
    $env:WSLENV = ""
}

Write-Host "Switched Codex runtime to $Mode."
Write-Host "Config backup: $backupPath"
Write-Host "CODEX_CLI_PATH: $UserCodexCli"

if ($RestartApp) {
    $desktopProcesses = Get-Process | Where-Object {
        $_.ProcessName -ceq "Codex" -and $_.Path -like "*WindowsApps*OpenAI.Codex*"
    }
    foreach ($process in $desktopProcesses) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Start-Sleep -Seconds 3
    Start-Process explorer.exe "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
    Write-Host "Restarted Explorer and Codex."
} else {
    Write-Host "Close Codex completely, restart Explorer or sign out/in, then launch Codex."
}
