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
$portA = Get-FreeTcpPort 11010 11080
$portB = Get-FreeTcpPort 11081 11150
$rpcA = Get-FreeTcpPort 15888 15950
$rpcB = Get-FreeTcpPort 15951 16010

# Node A (Sender)
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true")

# Node B (Receiver)
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
    -Peers @("tcp://${HostIP}:$portA") `
    -ExtraArgs @("--enable-file-transfer", "--private-mode", "true") `
    -WorkDir $NodeBDir

Log-Step "Waiting for P2P Connection"
$targetPeerId = Get-NodePeerId $rpcB
$peer = Wait-ForPeer $rpcA $targetPeerId "p2p" 60
$PEER_ID = $peer.id

Start-Sleep -Seconds 2

Log-Step "Executing Transfer"
$out = Invoke-FileSend $rpcA $PEER_ID "test_p2p.txt"
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
exit 0
