
# EasyTier P2P File Transfer Demo (Interactive)
# Style: TDD / Structured Engineering
# Author: EasyTier Assistant

# --- Helper Functions (TDD Style) ---

function Log-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Log-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Log-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Log-Error([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

param(
    [string]$LanIp = ""
)

function Get-LanIp([string]$Preferred = "") {
    if ($Preferred) { return $Preferred }
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.InterfaceAlias -notmatch "Loopback|Pseudo|vEthernet" -and
            $_.IPAddress -notmatch "^169\.254" -and
            $_.IPAddress -notmatch "^127\."
        } | Select-Object -First 1).IPAddress

    if (-not $ip) {
        throw "Unable to determine LAN IP. Provide -LanIp explicitly."
    }
    return $ip
}

function Get-FreeTcpPort([int]$StartPort, [int]$EndPort) {
    for ($p = $StartPort; $p -le $EndPort; $p++) {
        $inUse = Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue
        if (-not $inUse) { return $p }
    }
    throw "No free TCP port found in range ${StartPort}-${EndPort}"
}

function Wait-ForNode([System.Diagnostics.Process]$Proc, [string]$CliBin, [int]$RpcPort, [int]$TimeoutSec = 10) {
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        if ($Proc.HasExited) { throw "Node process exited unexpectedly! Code: $($Proc.ExitCode)" }
        try {
            # Query node info via JSON
            $Json = & $CliBin -p "127.0.0.1:$RpcPort" -o json node 2>$null | Out-String
            if ($Json) {
                # Handle potential error prefix in CLI output
                if ($Json.TrimStart().StartsWith("Error:")) { continue }
                
                $Info = $Json | ConvertFrom-Json
                if ($Info.peer_id) { return $Info.peer_id }
            }
        }
        catch {}
        Start-Sleep -Seconds 1
    }
    throw "Timeout waiting for node on RPC $RpcPort"
}

function Wait-ForPeerConnection([string]$CliBin, [int]$RpcPort, [string]$TargetPeerId, [int]$TimeoutSec = 30) {
    Log-Info "Waiting for P2P connection to peer $TargetPeerId..."
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        try {
            $Json = & $CliBin -p "127.0.0.1:$RpcPort" -o json peer 2>$null | Out-String
            if ($Json) {
                if ($Json.TrimStart().StartsWith("Error:")) { continue }
                
                $Peers = $Json | ConvertFrom-Json
                if ($Peers | Where-Object { $_.id -eq $TargetPeerId }) {
                    Log-Success "Connected to peer $TargetPeerId"
                    return $true
                }
            }
        }
        catch {}
        Write-Host "." -NoNewline -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
    Log-Warn "Timeout waiting for peer connection."
    return $false
}

# --- Main Execution ---

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Log-Info "Script Directory: $ScriptDir"

# Binary Discovery
$PossiblePaths = @(
    "$ScriptDir/../target/release",
    "$ScriptDir/target/release",
    "$PSScriptRoot/../target/release",
    "$PSScriptRoot/target/release",
    "$ScriptDir/../target/debug",
    "./target/release"
)

$BinDir = $null
foreach ($Path in $PossiblePaths) {
    if (Test-Path "$Path/easytier-core.exe") { 
        $BinDir = Resolve-Path $Path
        break 
    }
}

if (-not $BinDir) {
    Log-Error "Could not find easytier-core.exe. Please run 'cargo build --release' first."
    exit 1
}

$CoreBin = "$BinDir/easytier-core.exe"
$CliBin = "$BinDir/easytier-cli.exe"

# Configuration
$RpcNodeA = Get-FreeTcpPort 15888 15950
$RpcNodeB = Get-FreeTcpPort 15951 16010
$ListenA = Get-FreeTcpPort 11010 11080
$ListenB = Get-FreeTcpPort 11081 11150
$LanIp = Get-LanIp $LanIp

Log-Info "Using LAN IP: $LanIp"
Log-Info "Binaries from: $BinDir"

# Cleanup
Stop-Process -Name "easytier-core" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$ProcA = $null
$ProcB = $null

try {
    # 1. Start Node A
    Log-Info "Starting Node A (Sender)..."
    $ProcA = Start-Process -FilePath $CoreBin -ArgumentList "-i 10.144.144.10 --rpc-portal 127.0.0.1:$RpcNodeA --listeners tcp://$LanIp`:$ListenA --no-tun true --enable-file-transfer --private-mode true" -PassThru -NoNewWindow
    if (-not $ProcA) { throw "Failed to start Node A" }

    # 2. Start Node B
    Log-Info "Starting Node B (Receiver)..."
    $ProcB = Start-Process -FilePath $CoreBin -ArgumentList "-i 10.144.144.20 --rpc-portal 127.0.0.1:$RpcNodeB --listeners tcp://$LanIp`:$ListenB --peers tcp://$LanIp`:$ListenA --no-tun true --enable-file-transfer --private-mode true" -PassThru -NoNewWindow
    if (-not $ProcB) { throw "Failed to start Node B" }

    # 3. Validation
    Log-Info "Waiting for nodes to initialize..."
    $NodeAPeerId = Wait-ForNode $ProcA $CliBin $RpcNodeA
    $NodeBPeerId = Wait-ForNode $ProcB $CliBin $RpcNodeB
    Log-Success "Node A ID: $NodeAPeerId (RPC=$RpcNodeA)"
    Log-Success "Node B ID: $NodeBPeerId (RPC=$RpcNodeB)"

    # 4. Wait for P2P Config
    Wait-ForPeerConnection $CliBin $RpcNodeA $NodeBPeerId | Out-Null

    # 5. Interactive Demo
    Write-Host "`n=== READY FOR TRANSFER ===" -ForegroundColor Cyan
    Write-Host "Node A (Sender):   RPC 127.0.0.1:$RpcNodeA"
    Write-Host "Node B (Receiver): RPC 127.0.0.1:$RpcNodeB"
    Write-Host ""
    Write-Host "Transfer Command (Run this in a new terminal):" -ForegroundColor Cyan
    Write-Host "  $CliBin -p 127.0.0.1:$RpcNodeA file send $NodeBPeerId <YOUR_FILE_PATH>" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press ENTER to stop nodes and exit..." -ForegroundColor Gray
    Read-Host

}
catch {
    Log-Error $_.Exception.Message
}
finally {
    Log-Info "Stopping nodes..."
    if ($ProcA) { Stop-Process -Id $ProcA.Id -ErrorAction SilentlyContinue }
    if ($ProcB) { Stop-Process -Id $ProcB.Id -ErrorAction SilentlyContinue }
    Log-Info "Done."
}
