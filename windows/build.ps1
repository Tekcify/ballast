param(
    [switch]$NoInstall,
    [ValidateSet('x64', 'arm64')]
    [string]$Arch
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not $Arch) {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$rid = "win-$Arch"
$out = Join-Path $PSScriptRoot "..\build\windows\$rid"

dotnet publish src/Ballast/Ballast.csproj -c Release -r $rid -o $out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

if ($NoInstall) {
    Write-Host "built $out\Ballast.exe"
    return
}

$target = Join-Path $env:LOCALAPPDATA 'Programs\Ballast'
Get-Process Ballast -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process
Start-Sleep -Milliseconds 500

New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $out 'Ballast.exe') $target -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Ballast.lnk'))
$shortcut.TargetPath = Join-Path $target 'Ballast.exe'
$shortcut.Description = 'Memory and storage, sorted'
$shortcut.Save()

Write-Host "installed $target\Ballast.exe"
Start-Process (Join-Path $target 'Ballast.exe')
