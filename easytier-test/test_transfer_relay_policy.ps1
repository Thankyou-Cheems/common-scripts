param(
    [string]$RelayHost = "",
    [int]$RelayPort = 0,
    [string]$LanIp = "",
    [switch]$UseLocalForeignRelay
)

. (Join-Path $PSScriptRoot "_common.ps1")

if (-not $RelayHost) { $RelayHost = $DEFAULT_RELAY_HOST }
if (-not $RelayPort -or $RelayPort -eq 0) { $RelayPort = $DEFAULT_RELAY_PORT }

Log-Step "Initialization"
$HostIP = Get-LanIp $LanIp

$portA = 13110; $rpcA = 17988
$portB = 13120; $rpcB = 17989
$portC = Get-FreeTcpPort 13130 13180
$rpcC = 17990

$NodeBDir = Join-Path (Get-Location).Path "node_b_dir"
$NodeCDir = Join-Path (Get-Location).Path "node_c_dir"

if ($UseLocalForeignRelay) {
    Log-Info "Mode: Using Local Foreign Relay"
    $RelayPeerHost = $HostIP
    $RelayPeerPort = $portC
}
else {
    Log-Info "Mode: Using Public/External Relay ($RelayHost)"
    $RelayPeerHost = $RelayHost
    $RelayPeerPort = $RelayPort
}

function Run-Cleanup {
    Stop-EasyTierCluster
    Remove-Item *.log, *.download, *.meta, relay_test.txt, peers.json -ErrorAction SilentlyContinue
    Ensure-Dir $NodeBDir
    if ($UseLocalForeignRelay) {
        Ensure-Dir $NodeCDir
    }
}

function Setup-RelayNode {
    if ($UseLocalForeignRelay) {
        # Local Foreign Relay (Node C)
        # Note: Foreign relays usually need manual setup of network names to simulate foreign-ness, 
        # but here we use a separate network name "foreign_net" and enable relay forwarding.
        Start-ETNode -Name "node_c" -RpcPort $rpcC -TcpPort $portC `
            -ExtraArgs @(
            "--network-name", "foreign_net",
            "--relay-all-peer-rpc", "true", 
            "--enable-file-relay", "true"
        ) `
            -WorkDir $NodeCDir
        Wait-PortListen $portC 10
    }
}

Run-Cleanup

Log-Step "Setup Artifacts"
New-TestFile "relay_test.txt" -SizeBytes 11
"Hello Relay" | Out-File -Encoding utf8 relay_test.txt

# --- TEST 1 ---
Log-Step "Test 1: Relay Allowed (Default)"

Setup-RelayNode

# Node A (Sender)
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -Peers @("tcp://${RelayPeerHost}:${RelayPeerPort}") `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true", "--disable-p2p")

# Node B (Receiver)
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${RelayPeerHost}:${RelayPeerPort}") `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true", "--disable-p2p") `
    -WorkDir $NodeBDir

$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "relay" 90 | Out-Null
$peerId = $targetPeerId

$out = Invoke-FileSend $rpcA $peerId "relay_test.txt"
Log-Info "CLI Output: $out"

$recvPath = Join-Path $NodeBDir "relay_test.txt"
if (-not (Wait-ForFile $recvPath 1 30)) {
    throw "Test 1 Failed: File not received"
}
Log-Success "Test 1 Passed: File received via relay."

Run-Cleanup

# --- TEST 2 ---
Log-Step "Test 2: Relay Disabled (Receiver Side)"

New-TestFile "relay_test.txt" -SizeBytes 11
"Hello Relay" | Out-File -Encoding utf8 relay_test.txt

Setup-RelayNode

Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -Peers @("tcp://${RelayPeerHost}:${RelayPeerPort}") `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true", "--disable-p2p")

# Node B (Receiver) WITH RELAY DISABLED
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${RelayPeerHost}:${RelayPeerPort}") `
    -ExtraArgs @(
    "--enable-file-transfer", 
    "--private-mode", "true", 
    "--disable-p2p",
    "--disable-file-transfer-relay"
) `
    -WorkDir $NodeBDir

$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "relay" 90 | Out-Null
$peerId = $targetPeerId

$out = Invoke-FileSend $rpcA $peerId "relay_test.txt"
Log-Info "CLI Output: $out"

if ($out -match "Transfer rejected" -or $out -match "disabled" -or $out -match "exceeds") {
    Log-Success "Test 2 Passed: Rejected as expected."
}
else {
    throw "Test 2 Failed: Did not reject transfer. Output: $out"
}

Start-Sleep -Seconds 2
Run-Cleanup
Log-Success "All Relay Tests Completed Successfully"
exit 0
