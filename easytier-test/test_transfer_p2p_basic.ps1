param(
    [string]$LanIp = ""
)

. (Join-Path $PSScriptRoot "_common.ps1")

Log-Step "Initialization"
$HostIP = Get-LanIp $LanIp

Log-Step "Cleanup"
Stop-EasyTierCluster
Remove-Item *.log, *.download, *.meta, test_p2p.txt, peers.json -ErrorAction SilentlyContinue
$NodeBDir = Join-Path (Get-Location).Path "node_b_dir"

Log-Step "Setup Artifacts"
New-TestFile "test_p2p.txt" -SizeBytes 64
"P2P Transfer Test Content" | Out-File -NoNewline -Encoding utf8 test_p2p.txt

Log-Step "Starting Nodes"
# Node A (Sender): 11010, RPC 15888
Start-ETNode -Name "node_a" -RpcPort 15888 -TcpPort 11010 `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true")

# Node B (Receiver): 11020, RPC 15889
Start-ETNode -Name "node_b" -RpcPort 15889 -TcpPort 11020 `
    -Peers @("tcp://${HostIP}:11010") `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true") `
    -WorkDir $NodeBDir

Log-Step "Waiting for P2P Connection"
$targetPeerId = Get-NodePeerId 15889
$peer = Wait-ForPeer 15888 $targetPeerId "p2p" 60
$PEER_ID = $peer.id

Start-Sleep -Seconds 2

Log-Step "Executing Transfer"
$out = Invoke-FileSend 15888 $PEER_ID "test_p2p.txt"
Log-Info "CLI Output: $out"

Log-Step "Verification"
$recvPath = Join-Path $NodeBDir "test_p2p.txt"
if (-not (Wait-ForFile $recvPath 1 30)) {
    Get-Content (Join-Path $NodeBDir "node_b.log") -Tail 10
    throw "Transfer failed: File not received or empty."
}

Assert-FileHashMatch "test_p2p.txt" $recvPath

Log-Step "Teardown"
Stop-EasyTierCluster
Log-Success "Test PASSED: P2P File Transfer"
