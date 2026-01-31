param(
    [string]$LanIp = ""
)

. (Join-Path $PSScriptRoot "_common.ps1")

Log-Step "Initialization"
$HostIP = Get-LanIp $LanIp

$portA = 12110; $rpcA = 16988
$portB = 12120; $rpcB = 16989
$NodeADir = Join-Path (Get-Location).Path "node_a_dir_large"
$NodeBDir = Join-Path (Get-Location).Path "node_b_dir_large"
$LargeFile = "large_test.dat"
$FileSize = 20 * 1024 * 1024 # 20MB

function Run-Cleanup {
  Stop-EasyTierCluster
  Ensure-Dir $NodeADir; Ensure-Dir $NodeBDir
  Remove-Item *.log, *.download, *.meta, $LargeFile, peers.json -ErrorAction SilentlyContinue
}

Run-Cleanup

Log-Step "Setup Artifacts (20MB File)"
New-TestFile $LargeFile $FileSize

Log-Step "Starting Nodes"
# Node A
Start-ETNode -Name "node_a" -RpcPort $rpcA -TcpPort $portA `
  -ExtraArgs @("--enable-file-transfer", "--private-mode", "true") `
  -WorkDir $NodeADir

# Node B
Start-ETNode -Name "node_b" -RpcPort $rpcB -TcpPort $portB `
  -Peers @("tcp://${HostIP}:$portA") `
  -ExtraArgs @("--enable-file-transfer", "--private-mode", "true") `
  -WorkDir $NodeBDir

Log-Step "Waiting for P2P Connection"
$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "p2p" 60 | Out-Null
$peerId = $targetPeerId

Log-Step "Sending Large File"
$out = Invoke-FileSend $rpcA $peerId $LargeFile
Log-Info "CLI Output: $out"

Log-Step "Verification"
$recvPath = Join-Path $NodeBDir $LargeFile
if (-not (Wait-ForFile $recvPath $FileSize 120)) {
  throw "Large file not received or incomplete."
}
$len = (Get-Item $recvPath).Length
Log-Success "Received size: $len bytes"

Assert-FileHashMatch $LargeFile $recvPath

Run-Cleanup
Log-Success "Large P2P Test Verify Passed"
