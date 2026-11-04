# Builds Ballast for Windows and gathers it, with the Swift runtime it needs,
# into build\Ballast so the folder runs on any Windows PC.
#   .\build.ps1        build into build\Ballast
#   .\build.ps1 -Run   build, then start the tray app
param([switch]$Run)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

swift build -c release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Ask Swift for the actual binary output directory
$binPath = (swift build -c release --show-bin-path).Trim()
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$out = "build\Ballast"

if (Test-Path $out) {
    Remove-Item $out -Recurse -Force
}

New-Item -ItemType Directory -Path $out | Out-Null

# Copy application executables
Copy-Item (Join-Path $binPath "Ballast.exe") $out
Copy-Item (Join-Path $binPath "BallastDiagnostic.exe") $out

# Copy Swift runtime DLLs
$runtime = where.exe swiftCore.dll 2>$null | Select-Object -First 1

if ($runtime) {
    Copy-Item (Join-Path (Split-Path $runtime) "*.dll") $out
} else {
    Write-Warning "swiftCore.dll is not on PATH; build\Ballast may only run where Swift is installed"
}

Write-Host "Built successfully: $out"

if ($Run) {
    Start-Process (Join-Path $out "Ballast.exe")
}
