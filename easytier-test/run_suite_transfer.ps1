param(
    [string]$LanIp = "",
    [string]$RelayHost = "",
    [int]$RelayPort = 0,
    [string]$PublicRelayHost = "",
    [int]$PublicRelayPort = 0,
    [switch]$UseLocalForeignRelay
)

. (Join-Path $PSScriptRoot "_common.ps1")

Check-RelayConfig

# Use global defaults if parameters are not provided
if (-not $RelayHost) { $RelayHost = $DEFAULT_RELAY_HOST }
if (-not $RelayPort -or $RelayPort -eq 0) { $RelayPort = $DEFAULT_RELAY_PORT }
if (-not $PublicRelayHost) { $PublicRelayHost = $DEFAULT_RELAY_HOST }
if (-not $PublicRelayPort -or $PublicRelayPort -eq 0) { $PublicRelayPort = $DEFAULT_RELAY_PORT }

Log-Step "Starting Full Registry Suite"
$LanIp = Get-LanIp $LanIp

$FailedTests = @()

function Run-Step([string]$Name, [ScriptBlock]$Block) {
    Log-Step "Executing Suite: $Name"
    try {
        & $Block
        Log-Success "$Name SUITE PASSED"
    }
    catch {
        Log-Error "$Name SUITE FAILED: $_"
        $global:FailedTests += $Name
    }
}

Run-Step "P2P Basic" { & "$PSScriptRoot\\test_transfer_p2p_basic.ps1" -LanIp $LanIp }
Run-Step "P2P Large" { & "$PSScriptRoot\\test_transfer_p2p_large.ps1" -LanIp $LanIp }
Run-Step "Relay Policy" { & "$PSScriptRoot\\test_transfer_relay_policy.ps1" -RelayHost $RelayHost -RelayPort $RelayPort -LanIp $LanIp -UseLocalForeignRelay:$UseLocalForeignRelay }
Run-Step "Relay Limits" { & "$PSScriptRoot\\test_transfer_relay_limits.ps1" -PublicRelayHost $PublicRelayHost -PublicRelayPort $PublicRelayPort -LanIp $LanIp -UseLocalForeignRelay:$UseLocalForeignRelay }
Run-Step "Gates" { & "$PSScriptRoot\\test_transfer_security_gates.ps1" -LanIp $LanIp }
Run-Step "Resume" { & "$PSScriptRoot\\test_transfer_resumability.ps1" -LanIp $LanIp }

Write-Host "`n--------------------------------------------------"
if ($FailedTests.Count -eq 0) {
    Log-Success "ALL TESTS PASSED"
    exit 0
}
else {
    Log-Error "SOME TESTS FAILED: $($FailedTests -join ', ')"
    exit 1
}
