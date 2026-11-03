# Builds Ballast for Windows and gathers it, with the Swift runtime it needs,
# into build\Ballast so the folder runs on any Windows PC.
#   .\build.ps1        build into build\Ballast
#   .\build.ps1 -Run   build, then start the tray app
param([switch]$Run)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

swift build -c release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$out = "build\Ballast"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
Copy-Item ".build\release\Ballast.exe", ".build\release\BallastDiagnostic.exe" $out

# Windows does not ship the Swift runtime, so copy its DLLs next to the app.
$runtime = where.exe swiftCore.dll 2>$null | Select-Object -First 1
if ($runtime) {
    Copy-Item (Join-Path (Split-Path $runtime) "*.dll") $out
} else {
    Write-Warning "swiftCore.dll is not on PATH; build\Ballast will only run where Swift is installed"
}

Write-Host "built $out"
if ($Run) { Start-Process (Join-Path $out "Ballast.exe") }
