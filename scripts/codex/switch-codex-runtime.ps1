[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("windows", "wsl")]
    [string]$Mode,

    [switch]$RestartApp,

    [switch]$ConfigureNetworkGuards,

    [switch]$AllowIpv6
)

$ErrorActionPreference = "Stop"

$UserProfile = [Environment]::GetFolderPath("UserProfile")
$ConfigPath = Join-Path $UserProfile ".codex\config.toml"

$WindowsCodexCli = Join-Path $UserProfile "AppData\Local\Programs\OpenAI\Codex\bin\codex.exe"
$WslCodexShim = Join-Path $UserProfile "AppData\Local\pnpm\bin\codex"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

function Get-WindowsIpv6PrefixPolicy {
    $lines = & netsh.exe interface ipv6 show prefixpolicies 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @(
        foreach ($line in $lines) {
            if ($line -match "^\s*(\d+)\s+(\d+)\s+(.+?)\s*$") {
                [pscustomobject]@{
                    Precedence = [int]$matches[1]
                    Label      = [int]$matches[2]
                    Prefix     = $matches[3].Trim()
                }
            }
        }
    )
}

function Test-WindowsHasIpv6DefaultRoute {
    $route = Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne "Unreachable" } |
        Select-Object -First 1

    return $null -ne $route
}

function Test-WindowsPreferIpv4 {
    $policies = Get-WindowsIpv6PrefixPolicy
    $ipv4Mapped = $policies | Where-Object { $_.Prefix -eq "::ffff:0:0/96" } | Select-Object -First 1
    $ipv6Default = $policies | Where-Object { $_.Prefix -eq "::/0" } | Select-Object -First 1

    if (-not $ipv4Mapped -or -not $ipv6Default) {
        return $false
    }

    return $ipv4Mapped.Precedence -gt $ipv6Default.Precedence
}

function Set-WindowsPreferIpv4 {
    if (Test-IsAdministrator) {
        & netsh.exe interface ipv6 set prefixpolicy prefix="::ffff:0:0/96" precedence=100 label=4 store=persistent | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set Windows IPv4-mapped prefix policy."
        }

        & netsh.exe interface ipv6 set prefixpolicy prefix="::/0" precedence=40 label=1 store=persistent | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set Windows IPv6 default prefix policy."
        }

        return
    }

    $script = @'
$ErrorActionPreference = "Stop"
netsh interface ipv6 set prefixpolicy prefix=::ffff:0:0/96 precedence=100 label=4 store=persistent
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
netsh interface ipv6 set prefixpolicy prefix=::/0 precedence=40 label=1 store=persistent
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
'@

    Write-Host "Requesting elevation to set Windows IPv4 preference prefix policy..."
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $process = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        $encoded
    )

    if ($process.ExitCode -ne 0) {
        throw "Failed to set Windows IPv4 preference prefix policy. Elevated process exited with $($process.ExitCode)."
    }
}

function Set-Wsl2Key {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Text -notmatch "(?m)^\[wsl2\]\s*$") {
        $Text = "[wsl2]`r`n`r`n$Text"
    }

    $sectionPattern = "(?ms)(^\[wsl2\]\s*)(.*?)(?=^\[|\z)"
    $match = [regex]::Match($Text, $sectionPattern)
    if (-not $match.Success) {
        throw "Could not find or create [wsl2] section."
    }

    $header = $match.Groups[1].Value
    $body = $match.Groups[2].Value
    $line = "$Key=$Value"
    $keyPattern = "(?m)^$([regex]::Escape($Key))\s*=.*$"

    if ([regex]::IsMatch($body, $keyPattern)) {
        $body = [regex]::Replace($body, $keyPattern, $line)
    } else {
        if ($body.Length -gt 0 -and -not $body.EndsWith("`n")) {
            $body += "`r`n"
        }
        $body += "$line`r`n"
    }

    return $Text.Remove($match.Index, $match.Length).Insert($match.Index, "$header$body")
}

function Invoke-WslShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [switch]$Root
    )

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $command = "printf '%s' '$encoded' | base64 -d | sh"
    $arguments = @()
    if ($Root) {
        $arguments += @("-u", "root")
    }
    $arguments += @("sh", "-lc", $command)

    $output = & wsl.exe @arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output)
    }
}

function Set-WslIpv4Only {
    $wslConfig = Join-Path $UserProfile ".wslconfig"

    if (Test-Path -LiteralPath $wslConfig) {
        $content = Get-Content -LiteralPath $wslConfig -Raw
    } else {
        $content = "[wsl2]`r`n`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n"
    }

    foreach ($setting in @(
        @{ Key = "networkingMode"; Value = "mirrored" },
        @{ Key = "dnsTunneling"; Value = "true" },
        @{ Key = "autoProxy"; Value = "false" },
        @{ Key = "ipv6"; Value = "false" }
    )) {
        $content = Set-Wsl2Key -Text $content -Key $setting.Key -Value $setting.Value
    }

    Set-Content -LiteralPath $wslConfig -Value $content -Encoding utf8 -NoNewline

    $linuxScript = @'
set -eu
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-codex-ipv4-only.conf <<'EOF'
# Keep WSL IPv4-only for Codex when the active proxy/VPS has no IPv6 egress.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

if [ -f /etc/gai.conf ]; then
  if ! grep -qE '^\s*precedence\s+::ffff:0:0/96\s+100\b' /etc/gai.conf; then
    cp -a /etc/gai.conf "/etc/gai.conf.bak-codex-ipv4-$(date +%Y%m%d-%H%M%S)"
    cat >> /etc/gai.conf <<'EOF'

# Prefer IPv4-mapped addresses in WSL/Codex when IPv6 egress is unavailable.
precedence ::ffff:0:0/96  100
EOF
  fi
else
  cat > /etc/gai.conf <<'EOF'
# Prefer IPv4-mapped addresses in WSL/Codex when IPv6 egress is unavailable.
precedence ::ffff:0:0/96  100
EOF
fi

sysctl -q -p /etc/sysctl.d/99-codex-ipv4-only.conf || true
'@

    $result = Invoke-WslShellScript -Script $linuxScript -Root
    if ($result.ExitCode -ne 0) {
        throw "Failed to configure WSL IPv4-only guard. Ensure WSL is installed and this distro allows root access."
    }

    Write-Host "Configured WSL IPv4-only guard. Shutting down WSL so .wslconfig takes effect..."
    & wsl.exe --shutdown
}

function Test-WslIpv4Only {
    $script = @'
all="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
default="$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || echo 0)"
routes="$(ip -6 route show default 2>/dev/null || true)"
gai="$(grep -Ec '^\s*precedence\s+::ffff:0:0/96\s+100\b' /etc/gai.conf 2>/dev/null || true)"
if [ "$all" = "1" ] && [ "$default" = "1" ] && [ -z "$routes" ] && [ "$gai" -gt 0 ]; then
  echo OK
else
  echo "all=$all default=$default default_routes=${routes:-none} gai_ipv4_precedence=$gai"
fi
'@

    $result = Invoke-WslShellScript -Script $script
    return ($result.ExitCode -eq 0 -and ($result.Output | Select-Object -Last 1) -eq "OK")
}

function Assert-NetworkGuards {
    if ($AllowIpv6) {
        Write-Warning "Skipping IPv4-only network guards because -AllowIpv6 was supplied."
        return
    }

    if ($ConfigureNetworkGuards) {
        Set-WindowsPreferIpv4
        if ($Mode -eq "wsl") {
            Set-WslIpv4Only
        }
    }

    if ((Test-WindowsHasIpv6DefaultRoute) -and -not (Test-WindowsPreferIpv4)) {
        throw @"
Windows has an IPv6 default route but does not prefer IPv4-mapped addresses.
In the known Clash/Mihomo + VPS setup, the VPS has no IPv6 egress, so Codex websocket connections can try IPv6 and reconnect repeatedly.
Run this once, then retry:
  .\scripts\codex\switch-codex-runtime.ps1 $Mode -ConfigureNetworkGuards
Use -AllowIpv6 only when the active proxy/VPS is known to have working IPv6 egress.
"@
    }

    if ($Mode -eq "wsl" -and -not (Test-WslIpv4Only)) {
        throw @"
WSL is not in the expected IPv4-only state for Codex.
This switch is intentionally blocked because WSL IPv6 can be routed into Clash TUN while the active VPS has no IPv6 egress.
Run this once, then retry:
  .\scripts\codex\switch-codex-runtime.ps1 wsl -ConfigureNetworkGuards
Use -AllowIpv6 only when the active proxy/VPS is known to have working IPv6 egress.
"@
    }
}

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

Assert-NetworkGuards

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

[Environment]::SetEnvironmentVariable("CODEX_CLI_PATH", $UserCodexCli, "User")
$env:CODEX_CLI_PATH = $UserCodexCli

if ($UserWslEnv) {
    [Environment]::SetEnvironmentVariable("WSLENV", $UserWslEnv, "User")
    $env:WSLENV = $UserWslEnv
} else {
    [Environment]::SetEnvironmentVariable("WSLENV", $null, "User")
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
