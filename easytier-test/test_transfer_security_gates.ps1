param(
    [string]$LanIp = ""
)

. (Join-Path $PSScriptRoot "_common.ps1")

Log-Step "Initialization"
$HostIP = Get-LanIp $LanIp

$portA = 15110; $rpcA = 19988
$portB = 15120; $rpcB = 19989
$NodeADir = Join-Path (Get-Location).Path "node_a_dir"
$NodeBDir = Join-Path (Get-Location).Path "node_b_dir"

function Run-Cleanup {
    Stop-EasyTierCluster
    Ensure-Dir $NodeADir; Ensure-Dir $NodeBDir
    Remove-Item *.log, *.download, *.meta, gate_test.txt, peers.json -ErrorAction SilentlyContinue
}

function Assert-Rejection([int]$rpc, [string]$peerId, [string]$file, [string]$expectedReasonPattern) {
    Log-Info "Sending $file to $peerId (Expected Fail: $expectedReasonPattern)..."
    $out = Invoke-FileSend $rpc $peerId $file
    Log-Info "CLI Output: $out"
    
    if ($out -match "Transfer started with ID" -or $out -match "Transfer accepted" -or $out -match "100%") {
        throw "Test Failed: Transfer unexpectedly started."
    }
    
    if ($out -match $expectedReasonPattern -or $out -match "Transfer rejected") {
        Log-Success "Transfer rejected as expected (Reason: $expectedReasonPattern)."
    }
    else {
        throw "Test Failed: Expected rejection for '$expectedReasonPattern' but got: $out"
    }

    if (Wait-ForFile (Join-Path $NodeBDir $file) 1 5) {
        throw "Test Failed: File unexpectedly appeared on receiver disk."
    }
}

Run-Cleanup

Log-Step "Setup Artifacts"
New-TestFile "gate_test.txt" 64
"Gate Test Content" | Out-File -NoNewline -Encoding utf8 gate_test.txt

# --- TEST 1 ---
Log-Step "Test 1: Receiver --enable-file-transfer false"

# Node A: Enabled
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -ExtraArgs @("--enable-file-transfer", "true", "--private-mode", "true") `
    -WorkDir $NodeADir

# Node B: DISABLED
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${HostIP}:$portA") `
    -ExtraArgs @("--enable-file-transfer", "false", "--private-mode", "true") `
    -WorkDir $NodeBDir

$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "p2p" 60 | Out-Null
$peerId = $targetPeerId

Assert-Rejection $rpcA $peerId "gate_test.txt" "disabled"

Run-Cleanup

# --- TEST 2 ---
Log-Step "Test 2: Receiver --private-mode false"

New-TestFile "gate_test.txt" 64
"Gate Test Content" | Out-File -NoNewline -Encoding utf8 gate_test.txt

# Node A: Enabled, Private
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -ExtraArgs @("--enable-file-transfer", "true", "--private-mode", "true") `
    -WorkDir $NodeADir

# Node B: Enabled, BUT PUBLIC MODE
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${HostIP}:$portA") `
    -ExtraArgs @("--enable-file-transfer", "true", "--private-mode", "false") `
    -WorkDir $NodeBDir

$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "p2p" 60 | Out-Null
$peerId = $targetPeerId

Assert-Rejection $rpcA $peerId "gate_test.txt" "private mode"

Run-Cleanup
Log-Success "All Gate Tests Verified!"
