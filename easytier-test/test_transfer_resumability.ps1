param(
    [string]$LanIp = ""
)

. (Join-Path $PSScriptRoot "_common.ps1")

Log-Step "Initialization"
$HostIP = Get-LanIp $LanIp

$portA = 16110; $rpcA = 20988
$portB = 16120; $rpcB = 20989
$NodeADir = Join-Path (Get-Location).Path "node_a_dir"
$NodeBDir = Join-Path (Get-Location).Path "node_b_dir"

$SourceFile = "resume_test.bin"
$FileSize = 1048576
$PartialSize = 262144

# Ensure info-level logs are emitted for resume detection
$env:RUST_LOG = "info"

function Run-Cleanup {
    Stop-EasyTierCluster
    Ensure-Dir $NodeADir; Ensure-Dir $NodeBDir
    Remove-Item *.log, *.download, *.meta, $SourceFile, peers.json -ErrorAction SilentlyContinue
}

function Write-Partial([string]$Src, [string]$Dst, [int]$Bytes) {
    if (-not (Test-Path $Src)) { throw "Write-Partial: Source $Src not found." }
    $srcStream = [System.IO.File]::OpenRead($Src)
    $dstStream = [System.IO.File]::Open($Dst, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] 8192
        $remaining = $Bytes
        while ($remaining -gt 0) {
            $toRead = [Math]::Min($buffer.Length, $remaining)
            $read = $srcStream.Read($buffer, 0, $toRead)
            if ($read -le 0) { break }
            $dstStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
    }
    finally {
        $srcStream.Close()
        $dstStream.Close()
    }
    Log-Info "Created partial download: $Dst ($Bytes bytes)"
}

Run-Cleanup

Log-Step "Setup Artifacts"
New-TestFile $SourceFile $FileSize
$hash = (Get-FileHash -Algorithm SHA256 $SourceFile).Hash.ToLowerInvariant()

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

Start-Sleep -Seconds 2

Log-Step "Simulating Interrupted Transfer (Partial Download)"
$partialPath = Join-Path $NodeBDir ([System.IO.Path]::ChangeExtension($SourceFile, "download"))
$metaPath = Join-Path $NodeBDir ([System.IO.Path]::ChangeExtension($SourceFile, "meta"))

Write-Partial $SourceFile $partialPath $PartialSize
# Fake metadata (needs to match source file hash)
"resume-test|$hash" | Out-File -Encoding ascii -NoNewline $metaPath

Log-Step "Waiting for P2P Connection"
$targetPeerId = Get-NodePeerId $rpcB
Wait-ForPeer $rpcA $targetPeerId "p2p" 60 | Out-Null
$peerId = $targetPeerId

Log-Step "Resuming Transfer"
$out = Invoke-FileSend $rpcA $peerId $SourceFile
Log-Info "CLI Output: $out"

Log-Step "Verification"
$recvPath = Join-Path $NodeBDir $SourceFile
if (-not (Wait-ForFile $recvPath $FileSize 60)) {
    throw "Transfer did not complete or time out."
}

Assert-FileHashMatch $SourceFile $recvPath

Log-Step "Verifying Resume Logic (Logs)"
$logFileOut = Join-Path $NodeBDir "node_b.log"
$logFileErr = Join-Path $NodeBDir "node_b_err.log"

$found = $false
if (Test-Path $logFileOut) {
    if ((Get-Content $logFileOut -Raw) -match "resuming from offset") { $found = $true }
}
if (-not $found -and (Test-Path $logFileErr)) {
    if ((Get-Content $logFileErr -Raw) -match "resuming from offset") { $found = $true }
}

if ($found) {
    Log-Success "Resume log entry found."
}
else {
    throw "Resume log entry NOT found. Did it verify the hash? (Checked stdout/stderr)"
}

if (Test-Path $partialPath) { throw "Partial .download file not cleaned up." }
if (Test-Path $metaPath) { throw ".meta file not cleaned up." }

Run-Cleanup
Log-Success "Resume Verify Passed"
