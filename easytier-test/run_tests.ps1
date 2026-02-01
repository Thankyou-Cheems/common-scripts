# Portable EasyTier Test Suite Runner
# This version auto-detects binary location and handles errors properly

param(
    [string]$BinDir = "",
    [string]$LanIp = "",
    [string]$PublicRelayHost = "",
    [int]$PublicRelayPort = 0
)

$ErrorActionPreference = "Stop"

# Auto-detect binary directory
if (-not $BinDir) {
    $possiblePaths = @(
        "target\release",
        "..\target\release",
        "..\..\target\release"
    )
    
    foreach ($path in $possiblePaths) {
        $testBin = Join-Path $path "easytier-core.exe"
        if (Test-Path $testBin) {
            $BinDir = $path
            break
        }
    }
    
    if (-not $BinDir) {
        Write-Host "[ERROR] Cannot find easytier binaries. Please build the project first or specify -BinDir" -ForegroundColor Red
        Write-Host "Run: cargo build --release" -ForegroundColor Yellow
        exit 1
    }
}

$CoreBin = Join-Path $BinDir "easytier-core.exe"
$CliBin = Join-Path $BinDir "easytier-cli.exe"

if (-not (Test-Path $CoreBin) -or -not (Test-Path $CliBin)) {
    Write-Host "[ERROR] Binaries not found in: $BinDir" -ForegroundColor Red
    exit 1
}

Write-Host "`n[INFO] Using binaries from: $BinDir" -ForegroundColor Cyan
Write-Host "[INFO] easytier-core: $(Split-Path -Leaf $CoreBin)" -ForegroundColor Gray
Write-Host "[INFO] easytier-cli: $(Split-Path -Leaf $CliBin)" -ForegroundColor Gray

# Set environment variable for test scripts to use
$env:EASYTIER_BIN_DIR = (Resolve-Path $BinDir).Path

# Locate test scripts directory
$ScriptDir = $PSScriptRoot
$TestScriptDir = ""

# Try to find easytier-test directory
$possibleTestDirs = @(
    "D:\GameDev\Common-Scripts\easytier-test",
    (Join-Path $ScriptDir "..\Common-Scripts\easytier-test"),
    (Join-Path $ScriptDir "easytier-test")
)

foreach ($dir in $possibleTestDirs) {
    if (Test-Path (Join-Path $dir "_common.ps1")) {
        $TestScriptDir = $dir
        break
    }
}

if (-not $TestScriptDir) {
    Write-Host "[ERROR] Cannot locate easytier-test directory" -ForegroundColor Red
    Write-Host "Expected locations:" -ForegroundColor Yellow
    $possibleTestDirs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    exit 1
}

Write-Host "[INFO] Using test scripts from: $TestScriptDir`n" -ForegroundColor Cyan

# Load common functions
. (Join-Path $TestScriptDir "_common.ps1")

# Override binary paths in _common.ps1 functions
$script:CORE_BIN = $CoreBin
$script:CLI_BIN = $CliBin

# Get LAN IP
if (-not $LanIp) {
    try {
        $LanIp = Get-LanIp
    }
    catch {
        Write-Host "[ERROR] Failed to auto-detect LAN IP: $_" -ForegroundColor Red
        Write-Host "Please specify -LanIp explicitly" -ForegroundColor Yellow
        exit 1
    }
}

# Setup relay config
if (-not $PublicRelayHost) { $PublicRelayHost = "YOUR_RELAY_IP_HERE" }
if ($PublicRelayPort -eq 0) { $PublicRelayPort = 11199 }

Write-Host "=== Configuration ===" -ForegroundColor Magenta
Write-Host "LAN IP: $LanIp" -ForegroundColor White
Write-Host "Public Relay: ${PublicRelayHost}:${PublicRelayPort}" -ForegroundColor White
Write-Host ""

# Test execution with proper error handling
$FailedTests = [System.Collections.ArrayList]::new()

function Run-TestSuite([string]$Name, [string]$ScriptPath, [hashtable]$Params = @{}) {
    Write-Host "`n=== Running: $Name ===" -ForegroundColor Cyan
    
    $allParams = @{} + $Params
    $allParams['LanIp'] = $LanIp
    
    try {
        $script = Join-Path $TestScriptDir $ScriptPath
        if (-not (Test-Path $script)) {
            throw "Script not found: $script"
        }
        
        & $script @allParams
        
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            throw "$Name exited with code $LASTEXITCODE"
        }
        
        Write-Host "[SUCCESS] $Name PASSED" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[FAILED] $Name : $_" -ForegroundColor Red
        $FailedTests.Add($Name) | Out-Null
        return $false
    }
}

# Run test suites
Write-Host "`n===============================================================" -ForegroundColor Cyan
Write-Host "    EasyTier File Transfer Test Suite" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan

Run-TestSuite "P2P Basic" "test_transfer_p2p_basic.ps1"
Run-TestSuite "P2P Large" "test_transfer_p2p_large.ps1"
Run-TestSuite "Security Gates" "test_transfer_security_gates.ps1"
Run-TestSuite "Resumability" "test_transfer_resumability.ps1"

# Tests requiring relay configuration
if ($PublicRelayHost -ne "YOUR_RELAY_IP_HERE") {
    Run-TestSuite "Relay Policy" "test_transfer_relay_policy.ps1" @{
        RelayHost            = $PublicRelayHost
        RelayPort            = $PublicRelayPort
        UseLocalForeignRelay = $false
    }
    
    Run-TestSuite "Relay Limits" "test_transfer_relay_limits.ps1" @{
        PublicRelayHost      = $PublicRelayHost
        PublicRelayPort      = $PublicRelayPort
        UseLocalForeignRelay = $false
    }
}
else {
    Write-Host "`n[SKIP] Relay tests skipped - no relay server configured" -ForegroundColor Yellow
    Write-Host "       Set -PublicRelayHost and -PublicRelayPort to run relay tests" -ForegroundColor Gray
}

# Summary
Write-Host "`n===============================================================" -ForegroundColor Cyan
Write-Host "    Test Results" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan

if ($FailedTests.Count -eq 0) {
    Write-Host "`n[SUCCESS] ALL TESTS PASSED!" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n[FAILED] Some tests failed:" -ForegroundColor Red
    $FailedTests | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
