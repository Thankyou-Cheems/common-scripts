$ErrorActionPreference = "Stop"

# --- Global Configuration (Macros) ---
# [USER ACTION REQUIRED] Please update these values to your own relay server details.
$DEFAULT_RELAY_HOST = "YOUR_RELAY_IP_HERE"
$DEFAULT_RELAY_PORT = 11199

function Check-RelayConfig {
    if ($DEFAULT_RELAY_HOST -eq "YOUR_RELAY_IP_HERE") {
        Write-Host "`n[!WARNING] PRESET RELAY HOST NOT CONFIGURED" -ForegroundColor Red
        Write-Host "Please edit 'easytier-test/_common.ps1' and set `$DEFAULT_RELAY_HOST to your server's IP." -ForegroundColor Yellow
        Write-Host "Currently using placeholder: $DEFAULT_RELAY_HOST`n" -ForegroundColor Gray
    }
}

# --- Logging Helpers ---
function Log-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Log-Warn([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Log-Error([string]$Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Log-Step([string]$Name) {
    Write-Host "`n=== STEP: $Name ===" -ForegroundColor Magenta
}

function Log-Success([string]$Message) {
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

# --- Assertions ---
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "Assertion Failed: $Message"
    }
}

function Assert-FileExists([string]$Path, [string]$Context = "") {
    if (-not (Test-Path $Path)) {
        throw "File not found: $Path ($Context)"
    }
}

function Assert-FileHashMatch([string]$PathA, [string]$PathB) {
    $hashA = (Get-FileHash $PathA).Hash
    $hashB = (Get-FileHash $PathB).Hash
    if ($hashA -ne $hashB) {
        throw "Hash mismatch between $PathA and $PathB`n$hashA != $hashB"
    }
    Log-Success "File integrity verified: Hashes match."
}

# --- Core Utilities ---
function Stop-EasyTierCluster {
    Log-Info "Stopping all EasyTierCore processes..."
    Stop-Process -Name easytier-core -Force -ErrorAction SilentlyContinue
    
    # Wait for processes to actually exit
    $waited = 0
    while (Get-Process -Name easytier-core -ErrorAction SilentlyContinue) {
        Start-Sleep -Milliseconds 500
        $waited += 500
        if ($waited -gt 5000) {
            Log-Warn "Force killing stubborn EasyTierCore processes..."
            Stop-Process -Name easytier-core -Force -ErrorAction SilentlyContinue
            break
        }
    }
    Start-Sleep -Milliseconds 500 # Grace period for ports
}

function Ensure-Dir([string]$Path) {
    if (Test-Path $Path) {
        Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force $Path | Out-Null
}

function Get-LanIp([string]$Preferred = "") {
    if ($Preferred) {
        if ($Preferred -eq "127.0.0.1" -or $Preferred -eq "localhost") {
            Log-Warn "Explicitly using Loopback IP ($Preferred). This is discouraged for peer connectivity tests on Windows."
        }
        return $Preferred
    }
    
    $ip = $null
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress
    }
    catch {}

    if (-not $ip) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress
    }

    if (-not $ip) {
        throw "Unable to determine LAN IP. Please provide -LanIp explicitly."
    }
    
    if ($ip -eq "127.0.0.1") {
        throw "Critical Error: Resolved LAN IP is 127.0.0.1. Peer-to-peer tests will likely fail on Windows due to 'AddrNotAvailable'."
    }
    
    Log-Info "Resolved LAN IP: $ip"
    return $ip
}

function Get-FreeTcpPort([int]$StartPort, [int]$EndPort) {
    for ($p = $StartPort; $p -le $EndPort; $p++) {
        $inUse = Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue
        if (-not $inUse) {
            return $p
        }
    }
    throw "No free TCP port found in range ${StartPort}-${EndPort}"
}

function Wait-PortListen([int]$Port, [int]$TimeoutSec = 10) {
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($listening) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    throw "Port $Port is not listening after ${TimeoutSec}s"
}

function New-TestFile([string]$Path, [int64]$SizeBytes) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.SetLength($SizeBytes)
    }
    finally {
        $fs.Close()
    }
    Log-Info "Created test file: $Path ($SizeBytes bytes)"
}

# --- Node Management ---
function Start-ETNode {
    param(
        [string]$Name,
        [int]$RpcPort,
        [int]$TcpPort,
        [string[]]$Peers = @(),
        [string[]]$ExtraArgs = @(),
        [string]$WorkDir = ""
    )
    
    $argsList = @(
        "--instance-name", $Name,
        "--no-tun",
        "--rpc-portal", "127.0.0.1:$RpcPort",
        "--listeners", "tcp://0.0.0.0:$TcpPort", "udp://0.0.0.0:$TcpPort",
        "--network-name", "test_net",
        "--network-secret", "test_pwd"
    )

    if ($Peers.Count -gt 0) {
        foreach ($p in $Peers) {
            # SANITY CHECK for 127.0.0.1 peer URIs
            if ($p -match "127\.0\.0\.1" -or $p -match "localhost") {
                Log-Warn "Node '$Name' is peering to loopback address '$p'. This may fail on Windows."
            }
            $argsList += "--peers"
            $argsList += $p
        }
    }

    $argsList += $ExtraArgs

    $logOut = "$Name.log"
    $logErr = "${Name}_err.log"
    
    if ($WorkDir) {
        Ensure-Dir $WorkDir
        $logOut = Join-Path $WorkDir $logOut
        $logErr = Join-Path $WorkDir $logErr
        
        Log-Info "Starting Node '$Name' (RPC=$RpcPort, TCP=$TcpPort) in $WorkDir..."
        Start-Process -FilePath "./target/release/easytier-core.exe" `
            -ArgumentList $argsList `
            -WorkingDirectory $WorkDir `
            -RedirectStandardOutput $logOut `
            -RedirectStandardError $logErr
    }
    else {
        Log-Info "Starting Node '$Name' (RPC=$RpcPort, TCP=$TcpPort) in Root..."
        Start-Process -FilePath "./target/release/easytier-core.exe" `
            -ArgumentList $argsList `
            -RedirectStandardOutput $logOut `
            -RedirectStandardError $logErr
    }
}

function Get-NodePeerId([int]$Rpc, [int]$TimeoutSec = 30) {
    Log-Info "Getting PeerID from RPC $Rpc (Timeout: ${TimeoutSec}s)..."
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        try {
            # Log debug every 5 seconds to show we are still alive
            if ($i % 5 -eq 0) { Log-Info "  Attempt $($i+1)/$TimeoutSec..." }
            
            $json = & ./target/release/easytier-cli.exe -p "127.0.0.1:$Rpc" -o json node 2>$null
            
            if ($lastExitCode -ne 0) {
                # CLI failed (e.g. conn refused), expected during startup
                Start-Sleep -Seconds 1
                continue
            }
        }
        catch {
            Start-Sleep -Seconds 1
            continue
        }
        if ($json) {
            try {
                if ($json -is [string] -and $json.TrimStart().StartsWith("Error:")) {
                    Start-Sleep -Seconds 1
                    continue
                }
                $info = $json | ConvertFrom-Json
                $peerId = $info.peer_id
                if (-not $peerId) {
                    $peerId = $info.peerId
                }
                if ($peerId) {
                    Log-Success "Got PeerID: $peerId"
                    return $peerId.ToString()
                }
            }
            catch {}
        }
        Start-Sleep -Seconds 1
    }
    throw "Unable to read peer_id from node info on RPC $Rpc after ${TimeoutSec}s"
}

function Wait-ForPeer([int]$Rpc, [string]$TargetPeerId, [string]$Mode = "any", [int]$TimeoutSec = 60) {
    $start = Get-Date
    Log-Info "Waiting for peer $TargetPeerId on RPC $Rpc (Mode=$Mode)..."
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        Start-Sleep -Seconds 1
        try {
            $json = & ./target/release/easytier-cli.exe -p "127.0.0.1:$Rpc" -o json peer 2>$null
        }
        catch {
            continue
        }
        if (-not $json) {
            continue
        }
        try {
            if ($json -is [string] -and $json.TrimStart().StartsWith("Error:")) {
                continue
            }
            $peers = $json | ConvertFrom-Json
            $peer = $peers | Where-Object { $_.id -eq $TargetPeerId } | Select-Object -First 1
            if ($peer) {
                $cost = $peer.cost
                if ($Mode -eq "p2p" -and $cost -ne "p2p") {
                    continue
                }
                if ($Mode -eq "relay" -and $cost -notlike "relay*") {
                    continue
                }
                Log-Success "Connected: $($peer.id) via $($peer.cost)"
                return $peer
            }
        }
        catch {}
    }
    $elapsed = (Get-Date) - $start
    throw "Timeout waiting for peer $TargetPeerId on RPC $Rpc after $($elapsed.TotalSeconds)s"
}

function Wait-ForFile([string]$Path, [int64]$MinSize = 0, [int]$TimeoutSec = 60) {
    Log-Info "Waiting for file: $Path (MinSize=$MinSize)..."
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        if (Test-Path $Path) {
            $len = (Get-Item $Path).Length
            if ($len -ge $MinSize) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-FileSend([int]$Rpc, [string]$PeerId, [string]$FilePath) {
    Log-Info "Invoking file send to $PeerId (RPC=$Rpc)..."
    try {
        $out = & ./target/release/easytier-cli.exe -p "127.0.0.1:$Rpc" file send $PeerId $FilePath 2>&1
        return $out
    }
    catch {
        return $_.ToString()
    }
}

function Ensure-Dir([string]$Path) {
    if (Test-Path $Path) {
        Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force $Path | Out-Null
}

function Get-LanIp([string]$Preferred = "") {
    if ($Preferred) {
        return $Preferred
    }
    $ip = $null
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress
    }
    catch {}
    if (-not $ip) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress
    }
    if (-not $ip) {
        throw "Unable to determine LAN IP. Provide -LanIp explicitly."
    }
    return $ip
}

function Get-FreeTcpPort([int]$StartPort, [int]$EndPort) {
    for ($p = $StartPort; $p -le $EndPort; $p++) {
        $inUse = Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue
        if (-not $inUse) {
            return $p
        }
    }
    throw "No free TCP port found in range ${StartPort}-${EndPort}"
}

function Wait-PortListen([int]$Port, [int]$TimeoutSec = 10) {
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($listening) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    throw "Port $Port is not listening after ${TimeoutSec}s"
}

function New-TestFile([string]$Path, [int64]$SizeBytes) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.SetLength($SizeBytes)
    }
    finally {
        $fs.Close()
    }
}

function Get-NodePeerId([int]$Rpc, [int]$TimeoutSec = 30) {
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        try {
            $json = & ./target/release/easytier-cli.exe -p "127.0.0.1:$Rpc" -o json node 2>$null
        }
        catch {
            Start-Sleep -Seconds 1
            continue
        }
        if ($json) {
            try {
                if ($json -is [string] -and $json.TrimStart().StartsWith("Error:")) {
                    Start-Sleep -Seconds 1
                    continue
                }
                $info = $json | ConvertFrom-Json
                $peerId = $info.peer_id
                if (-not $peerId) {
                    $peerId = $info.peerId
                }
                if ($peerId) {
                    return $peerId.ToString()
                }
            }
            catch {}
        }
        Start-Sleep -Seconds 1
    }
    throw "Unable to read peer_id from node info on RPC $Rpc after ${TimeoutSec}s"
}

function Wait-ForPeer([int]$Rpc, [string]$TargetPeerId, [string]$Mode = "any", [int]$TimeoutSec = 60) {
    $start = Get-Date
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        Start-Sleep -Seconds 1
        try {
            $json = & ./target/release/easytier-cli.exe -p "127.0.0.1:$Rpc" -o json peer 2>$null
        }
        catch {
            continue
        }
        if (-not $json) {
            continue
        }
        try {
            if ($json -is [string] -and $json.TrimStart().StartsWith("Error:")) {
                continue
            }
            $peers = $json | ConvertFrom-Json
            $peer = $peers | Where-Object { $_.id -eq $TargetPeerId } | Select-Object -First 1
            if ($peer) {
                $cost = $peer.cost
                if ($Mode -eq "p2p" -and $cost -ne "p2p") {
                    continue
                }
                if ($Mode -eq "relay" -and $cost -notlike "relay*") {
                    continue
                }
                Write-Host "Connected: $($peer.id) via $($peer.cost)"
                return $peer
            }
        }
        catch {}
    }
    $elapsed = (Get-Date) - $start
    throw "Timeout waiting for peer $TargetPeerId on RPC $Rpc after $($elapsed.TotalSeconds)s"
}

function Wait-ForFile([string]$Path, [int64]$MinSize = 0, [int]$TimeoutSec = 60) {
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        if (Test-Path $Path) {
            $len = (Get-Item $Path).Length
            if ($len -ge $MinSize) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-FileSend([int]$Rpc, [string]$PeerId, [string]$FilePath) {
    try {
        return & ./target/release/easytier-cli.exe -p "127.0.0.1:$Rpc" file send $PeerId $FilePath 2>&1
    }
    catch {
        return $_.ToString()
    }
}
