param(
    [string]$PublicRelayHost = "",
    [int]$PublicRelayPort = 0,
    [string]$LanIp = "",
    [switch]$UseLocalForeignRelay
)

. (Join-Path $PSScriptRoot "_common.ps1")

if (-not $PublicRelayHost) { $PublicRelayHost = $DEFAULT_RELAY_HOST }
if (-not $PublicRelayPort -or $PublicRelayPort -eq 0) { $PublicRelayPort = $DEFAULT_RELAY_PORT }

Log-Step "Initialization"
$HostIP = Get-LanIp $LanIp

$portA = 14110; $rpcA = 18988
$portB = 14120; $rpcB = 18989
$portC = Get-FreeTcpPort 14130 14180
$rpcC = 18990 

$NodeADir = Join-Path (Get-Location).Path "node_a_dir"
$NodeBDir = Join-Path (Get-Location).Path "node_b_dir"
$NodeCDir = Join-Path (Get-Location).Path "node_c_dir"

function Run-Cleanup {
    Stop-EasyTierCluster
    Ensure-Dir $NodeADir; Ensure-Dir $NodeBDir; Ensure-Dir $NodeCDir
    Remove-Item peers.json -ErrorAction SilentlyContinue
}

function Assert-Transfer([int]$rpc, [string]$peerId, [string]$file, [bool]$expectSuccess) {
    Log-Info "Sending $file to $peerId..."
    $out = Invoke-FileSend $rpc $peerId $file
    Log-Info "CLI Output: $out"
    
    if ($expectSuccess) {
        if ($out -match "Transfer accepted" -or $out -match "100%" -or $out -match "Transfer started with ID") {
            Log-Success "Transfer accepted as expected."
        }
        else {
            throw "FAILED: Expected success but got error."
        }
    }
    else {
        if ($out -match "Transfer rejected" -or $out -match "disabled" -or $out -match "exceeds" -or $out -match "Error") {
            Log-Success "Transfer rejected as expected."
        }
        elseif ($out -match "Transfer started with ID") {
            throw "FAILED: Expected rejection but transfer started!"
        }
        else {
            throw "FAILED: Expected rejection but got unknown output."
        }
    }
}

Run-Cleanup

Log-Step "Setup Artifacts"
New-TestFile "relay_small.dat" 2048
New-TestFile "relay_mid.dat" 10240

# --- SCENARIO 1 ---
Log-Step "Scenario 1: Private Relay Limit Tests"

# Node C (Private Relay)
Start-ETNode -Name "node_c" -RpcPort $rpcC -TcpPort $portC -WorkDir $NodeCDir

Wait-PortListen $portC 10
Start-Sleep -Seconds 2

# Node A -> Node C
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -Peers @("tcp://${HostIP}:$portC") `
    -ExtraArgs @("--disable-p2p", "--enable-file-transfer", "--private-mode", "true") `
    -WorkDir $NodeADir

# Node B -> Node C
# Limits: Relay=5KB, Foreign=1KB. Private relay should ignore foreign limit.
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${HostIP}:$portC") `
    -ExtraArgs @(
    "--disable-p2p", "--enable-file-transfer", "--private-mode", "true",
    "--file-relay-limit", "5120", 
    "--file-foreign-limit", "1024"
) `
    -WorkDir $NodeBDir

$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "relay" 90 | Out-Null
$peerId = $targetPeerId

Log-Info "Test 1.1: Send 2KB via Private Relay (Limit 5KB, Foreign 1KB). Should PASS."
Assert-Transfer $rpcA $peerId "relay_small.dat" $true

Log-Info "Test 1.2: Send 10KB via Private Relay (Limit 5KB). Should FAIL."
Assert-Transfer $rpcA $peerId "relay_mid.dat" $false

Run-Cleanup

# --- SCENARIO 2 ---
Log-Step "Scenario 2: Foreign Relay Limit Tests"

$foreignRelayHost = $PublicRelayHost
$foreignRelayPort = $PublicRelayPort

if ($UseLocalForeignRelay) {
    Log-Info "Using Local Foreign Relay"
    $foreignRelayHost = $HostIP
    $foreignRelayPort = $portC
    Start-ETNode -Name "node_c" -RpcPort $rpcC -TcpPort $portC `
        -ExtraArgs @(
        "--network-name", "foreign_net",
        "--relay-all-peer-rpc", "true"
    ) `
        -WorkDir $NodeCDir
    Wait-PortListen $portC 10
}
else {
    Log-Info "Using Public Relay: ${PublicRelayHost}:${PublicRelayPort}"
}

# Node A -> Public Relay
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -Peers @("tcp://${foreignRelayHost}:${foreignRelayPort}") `
    -ExtraArgs @("--disable-p2p", "--enable-file-transfer", "--private-mode", "true") `
    -WorkDir $NodeADir

# Node B -> Public Relay
# Limits: Relay=20KB, Foreign=1KB. Foreign relay should enforce 1KB limit.
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${foreignRelayHost}:${foreignRelayPort}") `
    -ExtraArgs @(
    "--disable-p2p", "--enable-file-transfer", "--private-mode", "true",
    "--file-relay-limit", "20480", 
    "--file-foreign-limit", "1024"
) `
    -WorkDir $NodeBDir

$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "relay" 90 | Out-Null
$peerId = $targetPeerId

Log-Info "Test 2.1: Send 2KB via Foreign Relay (Limit 1KB). Should FAIL."
Assert-Transfer $rpcA $peerId "relay_small.dat" $false

Run-Cleanup
Log-Success "All Limit Tests Completed Successfully"
exit 0
