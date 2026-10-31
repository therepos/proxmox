@echo off
:: ============================================================
::  MyHub Auto-Complete - Edge extension setup
::  Install / update / uninstall. Double-click to run. No admin rights needed.
::  Downloads the latest release from GitHub into %LOCALAPPDATA%\myhub-ext,
::  the folder Edge loads the extension from (edge://extensions > Load unpacked).
::  After an update, click "Reload extension" in the MyHub popup.
:: ============================================================

set "PS_TEMP=%TEMP%\myhub-setup-%RANDOM%.ps1"

:: Use PowerShell to extract everything after ::__PS_BEGIN__ from this file
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$lines = [IO.File]::ReadAllLines('%~f0');" ^
  "$start = -1;" ^
  "for ($i=0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq '::__PS_BEGIN__') { $start = $i + 1; break } };" ^
  "if ($start -ge 0) { [IO.File]::WriteAllLines('%PS_TEMP%', $lines[$start..($lines.Count-1)]) }"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_TEMP%"
set "RC=%ERRORLEVEL%"

del /f /q "%PS_TEMP%" >nul 2>&1
exit /b %RC%

::__PS_BEGIN__
# =============================================================
# MyHub Auto-Complete - Edge extension setup (PowerShell)
# =============================================================

$ErrorActionPreference = 'Stop'

# ═════════════════════════════════════════════════════════════
# CONFIG
# ═════════════════════════════════════════════════════════════

$ExtName    = 'MyHub Auto-Complete'
$AssetFile  = 'ext-myhub.zip'
$GithubRepo = 'therepos/proxmox'
$TagPrefix  = 'myhub-v'
$DestDir    = Join-Path $env:LOCALAPPDATA 'myhub-ext'

# ═════════════════════════════════════════════════════════════

$Host.UI.RawUI.WindowTitle = "$ExtName Setup"
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# =============================================================
# FUNCTIONS
# =============================================================

function Get-InstalledVersion {
    $mf = Join-Path $DestDir 'manifest.json'
    if (-not (Test-Path $mf)) { return $null }
    try { return (Get-Content $mf -Raw | ConvertFrom-Json).version } catch { return '?' }
}

function Resolve-Release {
    # Latest release whose tag starts with our prefix, by version number, and the zip asset in it.
    Write-Host "  Finding latest $ExtName release..."

    $apiUrl = "https://api.github.com/repos/$GithubRepo/releases?per_page=50"
    try {
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'myhub-setup' } -ErrorAction Stop
    } catch {
        throw "Cannot reach GitHub API: $($_.Exception.Message)"
    }

    $matched = $releases |
        Where-Object { $_.tag_name -like "$TagPrefix*" } |
        Sort-Object {
            $v = $_.tag_name.Substring($TagPrefix.Length)
            try { [version]$v } catch { [version]'0.0' }
        } -Descending |
        Select-Object -First 1

    if (-not $matched) {
        throw "No release found with tag prefix '$TagPrefix'"
    }

    $asset = $matched.assets | Where-Object { $_.name -eq $AssetFile } | Select-Object -First 1
    if (-not $asset) {
        throw "$AssetFile not found in release $($matched.tag_name)"
    }

    Write-Host "  Found: $($matched.tag_name)" -ForegroundColor Green
    return @{ tag = $matched.tag_name; version = $matched.tag_name.Substring($TagPrefix.Length); url = $asset.browser_download_url }
}

function Install-Extension($rel) {
    # Download the zip, unpack it next to it, then replace the contents of $DestDir.
    # The folder itself is kept, Edge remembers it by path.
    $stamp  = [guid]::NewGuid().ToString('N')
    $tmpZip = Join-Path $env:TEMP "myhub-ext-$stamp.zip"
    $tmpDir = Join-Path $env:TEMP "myhub-ext-$stamp"

    Write-Host "  Downloading $AssetFile ..."
    try {
        Invoke-WebRequest -Uri $rel.url -OutFile $tmpZip -ErrorAction Stop
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        if (-not (Test-Path (Join-Path $tmpDir 'manifest.json'))) { throw 'manifest.json missing in the download' }

        if (Test-Path $DestDir) {
            Get-ChildItem -Path $DestDir -Force | Remove-Item -Recurse -Force
        } else {
            New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $tmpDir '*') -Destination $DestDir -Recurse -Force
        Write-Host "  Installed $($rel.tag) into $DestDir" -ForegroundColor Green
    } catch {
        Write-Host "  Install failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Check your internet connection." -ForegroundColor Yellow
        Read-Host "`n  Press Enter to exit"
        exit 1
    } finally {
        Remove-Item -Path $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-LoadSteps {
    try { Set-Clipboard -Value $DestDir } catch {}
    Write-Host ''
    Write-Host '  Load it in Edge (one time):' -ForegroundColor Cyan
    Write-Host '    1. Open edge://extensions and turn on Developer mode (bottom left).'
    Write-Host '    2. Click "Load unpacked" and paste the folder path (already copied to the clipboard):'
    Write-Host "       $DestDir"
    Write-Host '    3. Pin the extension, open MyHub, click its icon, press Start.'
    Write-Host ''
    Write-Host '  Later updates: run this file again, choose U, then click "Reload extension" in the popup.'
    try { Start-Process 'msedge.exe' 'edge://extensions' } catch {}
}

# =============================================================
# MAIN
# =============================================================

Write-Host ''
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host "    $ExtName - Edge extension setup" -ForegroundColor Cyan
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host ''

$installed = Get-InstalledVersion

if ($installed) {
    Write-Host "  $ExtName v$installed is installed at:"
    Write-Host "    $DestDir"
    Write-Host ''
    Write-Host '  [U] Update    - download latest version'
    Write-Host '  [R] Uninstall - remove the extension files'
    Write-Host '  [C] Cancel'
    Write-Host ''

    $ans = Read-Host '  Choose (U/R/C)'

    switch ($ans.Trim().ToUpper()) {
        'U' {
            try { $rel = Resolve-Release } catch {
                Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
                Read-Host "`n  Press Enter to exit"
                exit 1
            }
            if ($rel.version -eq $installed) {
                $again = Read-Host "  v$installed is already the latest. Reinstall anyway? (Y/N)"
                if ($again.Trim().ToUpper() -ne 'Y') { Write-Host '  Cancelled.'; Read-Host "`n  Press Enter to exit"; exit 0 }
            }
            Install-Extension $rel
            Write-Host ''
            Write-Host '  Updated. In Edge, open the MyHub popup and click "Reload extension"' -ForegroundColor Green
            Write-Host '  (or edge://extensions > Reload). No need to restart Edge.' -ForegroundColor Green
        }
        'R' {
            try {
                Remove-Item -Path $DestDir -Recurse -Force -ErrorAction Stop
                Write-Host "  Removed $DestDir." -ForegroundColor Green
                Write-Host "  In Edge, open edge://extensions and click Remove on $ExtName." -ForegroundColor Green
            } catch {
                Write-Host "  ERROR: Could not remove $DestDir." -ForegroundColor Red
            }
        }
        default {
            Write-Host '  Cancelled.'
        }
    }
} else {
    try { $rel = Resolve-Release } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "`n  Press Enter to exit"
        exit 1
    }
    Install-Extension $rel
    Show-LoadSteps
}

Write-Host ''
Read-Host '  Press Enter to exit'
