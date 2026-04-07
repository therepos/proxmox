@echo off
setlocal EnableDelayedExpansion
:: ============================================================
::  Office Add-in Remover (Clean Uninstall)
::  Double-click to run. No Python needed.
:: ============================================================

set "PS_TEMP=%TEMP%\addin-remove-%RANDOM%.ps1"

:: Extract everything after the __PS_BEGIN__ marker into a temp .ps1
set "FOUND="
(
    for /f "usebackq delims=" %%L in ("%~f0") do (
        if defined FOUND echo(%%L
        if "%%L"=="::__PS_BEGIN__" set "FOUND=1"
    )
) > "%PS_TEMP%"

:: Run it
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_TEMP%"
set "RC=%ERRORLEVEL%"

:: Clean up
del /f /q "%PS_TEMP%" >nul 2>&1
exit /b %RC%

::__PS_BEGIN__
# =============================================================
# Office Add-in Remover - PowerShell Core
# =============================================================

$ErrorActionPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'Office Add-in Remover'

# -- Config ---------------------------------------------------
$appdata = $env:APPDATA

$scanPaths = @(
    @{ Folder = "$appdata\Microsoft\AddIns";              Exts = @('.xlam','.xla','.ppam','.ppa') }
    @{ Folder = "$appdata\Microsoft\Word\STARTUP";        Exts = @('.dotm','.dot') }
    @{ Folder = "$appdata\Microsoft\PowerPoint\AddIns";   Exts = @('.ppam','.ppa') }
    @{ Folder = "$appdata\Microsoft\Excel\XLSTART";       Exts = @('.xlam','.xla','.xls','.xlsx') }
)

$appLabels = @{
    '.xlam'='Excel'; '.xla'='Excel'
    '.dotm'='Word';  '.dot'='Word'
    '.ppam'='PowerPoint'; '.ppa'='PowerPoint'
    '.xls'='Excel'; '.xlsx'='Excel'
}

$regKeys = @(
    @{ Path='HKCU:\Software\Microsoft\Office\Excel\Addins';            App='Excel';       Type='subkey' }
    @{ Path='HKCU:\Software\Microsoft\Office\Word\Addins';             App='Word';        Type='subkey' }
    @{ Path='HKCU:\Software\Microsoft\Office\PowerPoint\Addins';       App='PowerPoint';  Type='subkey' }
    @{ Path='HKCU:\Software\Microsoft\Office\16.0\Excel\Options';      App='Excel';       Type='open' }
    @{ Path='HKCU:\Software\Microsoft\Office\15.0\Excel\Options';      App='Excel';       Type='open' }
    @{ Path='HKCU:\Software\Microsoft\Office\14.0\Excel\Options';      App='Excel';       Type='open' }
    @{ Path='HKCU:\Software\Microsoft\Office\16.0\Word\Options';       App='Word';        Type='open' }
    @{ Path='HKCU:\Software\Microsoft\Office\15.0\Word\Options';       App='Word';        Type='open' }
    @{ Path='HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options'; App='PowerPoint';  Type='open' }
    @{ Path='HKCU:\Software\Microsoft\Office\15.0\PowerPoint\Options'; App='PowerPoint';  Type='open' }
)

# -- Scan files -----------------------------------------------
$allItems  = [System.Collections.ArrayList]::new()
$fileNames = [System.Collections.Generic.HashSet[string]]::new()

foreach ($sp in $scanPaths) {
    if (-not (Test-Path $sp.Folder)) { continue }
    foreach ($f in Get-ChildItem -Path $sp.Folder -File) {
        $ext = $f.Extension.ToLower()
        if ($sp.Exts -contains $ext) {
            $app = if ($appLabels[$ext]) { $appLabels[$ext] } else { 'Office' }
            [void]$allItems.Add(@{
                Name   = $f.Name
                Path   = $f.FullName
                App    = $app
                Source = 'file'
                Tag    = $app
            })
            [void]$fileNames.Add($f.Name.ToLower())
        }
    }
}

# -- Scan registry: COM subkeys & OPEN values -----------------
$regItems = [System.Collections.ArrayList]::new()

foreach ($rk in $regKeys) {
    if (-not (Test-Path $rk.Path)) { continue }

    if ($rk.Type -eq 'subkey') {
        $subs = Get-ChildItem -Path $rk.Path 2>$null
        foreach ($sub in $subs) {
            $manifest = ''
            try { $manifest = (Get-ItemProperty -Path $sub.PSPath -Name 'Manifest' -ErrorAction Stop).Manifest } catch {}
            if (-not $manifest) {
                try { $manifest = (Get-ItemProperty -Path $sub.PSPath -Name 'Path' -ErrorAction Stop).Path } catch {}
            }
            [void]$regItems.Add(@{
                Name     = $sub.PSChildName
                RegPath  = $rk.Path
                RegSub   = $sub.PSChildName
                Manifest = $manifest
                App      = $rk.App
                Source   = 'reg_subkey'
                Tag      = "$($rk.App) / registry"
            })
        }
    }

    if ($rk.Type -eq 'open') {
        $props = Get-ItemProperty -Path $rk.Path 2>$null
        if (-not $props) { continue }
        foreach ($pn in $props.PSObject.Properties.Name) {
            if ($pn -match '^OPEN\d*$') {
                $val = $props.$pn
                $display = $val -replace '^\s*/R\s*"?', '' -replace '"$', ''
                $leaf = Split-Path $display -Leaf -ErrorAction SilentlyContinue
                if (-not $leaf) { $leaf = $val }
                [void]$regItems.Add(@{
                    Name    = "$pn = $leaf"
                    RegPath = $rk.Path
                    RegVal  = $pn
                    RegData = $val
                    App     = $rk.App
                    Source  = 'reg_value'
                    Tag     = "$($rk.App) / registry"
                })
            }
        }
    }
}

# -- Merge (skip registry entries that match a listed file) ----
foreach ($ri in $regItems) {
    $dominated = $false
    foreach ($fn in $fileNames) {
        if ($ri.Source -eq 'reg_value' -and $ri.RegData -and $ri.RegData.ToLower().Contains($fn)) { $dominated = $true; break }
        if ($ri.Source -eq 'reg_subkey' -and $ri.Manifest -and $ri.Manifest.ToLower().Contains($fn)) { $dominated = $true; break }
        if ($ri.Name.ToLower() -eq $fn) { $dominated = $true; break }
    }
    if (-not $dominated) { [void]$allItems.Add($ri) }
}

# -- Display ---------------------------------------------------
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  Office Add-in Remover  (Clean Uninstall)' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

if ($allItems.Count -eq 0) {
    Write-Host "`nNo add-ins found (files or registry).`n" -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit
}

Write-Host "`nFound add-ins:`n"
for ($i = 0; $i -lt $allItems.Count; $i++) {
    $a = $allItems[$i]
    $num = ($i + 1).ToString().PadLeft(2)
    Write-Host "  [$num]  $($a.Name)  ($($a.Tag))"
}

Write-Host "`n  Total: $($allItems.Count)"
Write-Host ''
Write-Host '  Select items to remove:'
Write-Host '    Single:   3'
Write-Host '    Multiple: 1,3,5'
Write-Host '    Range:    1-4'
Write-Host '    Mixed:    1-3,5,7'
Write-Host '    All:      all'
Write-Host ''

$choice = Read-Host '  Your selection (or q to quit)'
if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq 'q') {
    Write-Host '  Cancelled.'
    Read-Host "`nPress Enter to exit"
    exit
}

# -- Parse selection -------------------------------------------
function Parse-Selection($text, $max) {
    $text = $text.Trim().ToLower()
    if ($text -in 'all','a','*') { return @(0..($max - 1)) }
    $indices = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($part in ($text -split ',')) {
        $p = $part.Trim()
        if ($p -match '^\d+\s*-\s*\d+$') {
            $bounds = $p -split '-'
            $lo = [int]$bounds[0]; $hi = [int]$bounds[1]
            if ($lo -gt $hi) { $lo, $hi = $hi, $lo }
            for ($v = $lo; $v -le $hi; $v++) { [void]$indices.Add($v) }
        } elseif ($p -match '^\d+$') {
            [void]$indices.Add([int]$p)
        } else { return $null }
    }
    $result = @()
    foreach ($v in $indices) {
        $idx = $v - 1
        if ($idx -lt 0 -or $idx -ge $max) { return $null }
        $result += $idx
    }
    return $result
}

$selIndices = Parse-Selection $choice $allItems.Count
if ($null -eq $selIndices) {
    Write-Host '  Invalid selection.' -ForegroundColor Red
    Read-Host "`nPress Enter to exit"
    exit
}

$selected = @(); foreach ($i in $selIndices) { $selected += $allItems[$i] }

Write-Host "`n  You selected $($selected.Count) add-in(s):`n"
foreach ($s in $selected) {
    $loc = if ($s.Path) { $s.Path } else { "$($s.RegPath)\$($s.RegSub)$($s.RegVal)" }
    Write-Host "    - $($s.Name)  =  $loc"
}

$confirm = Read-Host "`n  Delete these $($selected.Count) add-in(s)? (y/n)"
if ($confirm -ne 'y') {
    Write-Host '  Cancelled.'
    Read-Host "`nPress Enter to exit"
    exit
}

# -- Removal helpers -------------------------------------------
function Remove-RegSubkey($item) {
    try {
        Remove-Item -Path "$($item.RegPath)\$($item.RegSub)" -Recurse -Force -ErrorAction Stop
        Write-Host "  [OK]  Removed registry key: $($item.RegPath)\$($item.RegSub)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [ERR] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Remove-RegValue($item) {
    try {
        Remove-ItemProperty -Path $item.RegPath -Name $item.RegVal -Force -ErrorAction Stop
        Write-Host "  [OK]  Removed registry value: $($item.RegPath) -> $($item.RegVal)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [ERR] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# -- Execute removal -------------------------------------------
$okCount = 0; $errCount = 0
Write-Host ''

foreach ($s in $selected) {

    if ($s.Source -eq 'file') {
        try {
            Remove-Item -Path $s.Path -Force -ErrorAction Stop
            Write-Host "  [OK]  Deleted file: $($s.Path)" -ForegroundColor Green
            $okCount++
        } catch {
            Write-Host "  [ERR] $($_.Exception.Message)" -ForegroundColor Red
            $errCount++
        }
        # Auto-clean matching registry entries
        $fn = $s.Name.ToLower()
        foreach ($ri in $regItems) {
            $match = $false
            if ($ri.Source -eq 'reg_value' -and $ri.RegData -and $ri.RegData.ToLower().Contains($fn)) { $match = $true }
            if ($ri.Source -eq 'reg_subkey' -and $ri.Manifest -and $ri.Manifest.ToLower().Contains($fn)) { $match = $true }
            if ($ri.Name.ToLower() -eq $fn) { $match = $true }
            if ($match) {
                if ($ri.Source -eq 'reg_subkey') {
                    if (Remove-RegSubkey $ri) { $okCount++ } else { $errCount++ }
                } elseif ($ri.Source -eq 'reg_value') {
                    if (Remove-RegValue $ri) { $okCount++ } else { $errCount++ }
                }
            }
        }
    }

    if ($s.Source -eq 'reg_subkey') {
        if (Remove-RegSubkey $s) { $okCount++ } else { $errCount++ }
    }

    if ($s.Source -eq 'reg_value') {
        if (Remove-RegValue $s) { $okCount++ } else { $errCount++ }
    }
}

Write-Host ''
Write-Host "  Done: $okCount succeeded, $errCount failed." -ForegroundColor Cyan
if ($errCount -gt 0) {
    Write-Host "`n  Tip: Close all Office apps and retry if you got permission errors." -ForegroundColor Yellow
}
Write-Host ''
Read-Host 'Press Enter to exit'
