@echo off
:: ============================================================
::  Office Add-in Remover (Clean Uninstall)
::  Double-click to run. No Python needed.
::  Writes a temp .ps1 and executes it via PowerShell.
:: ============================================================

set "PS_TEMP=%TEMP%\addin-remove-%RANDOM%.ps1"

:: Write the PowerShell script to a temp file
> "%PS_TEMP%" (
echo # ═══════════════════════════════════════════════════════════════
echo # Office Add-in Remover — PowerShell core
echo # ═══════════════════════════════════════════════════════════════
echo.
echo $ErrorActionPreference = 'SilentlyContinue'
echo.
echo # ── Scan paths ──────────────────────────────────────────────
echo $appdata = $env:APPDATA
echo $scanPaths = @(
echo     @{ Folder = "$appdata\Microsoft\AddIns";              Exts = @('.xlam','.xla','.ppam','.ppa'^) }
echo     @{ Folder = "$appdata\Microsoft\Word\STARTUP";        Exts = @('.dotm','.dot'^) }
echo     @{ Folder = "$appdata\Microsoft\PowerPoint\AddIns";   Exts = @('.ppam','.ppa'^) }
echo     @{ Folder = "$appdata\Microsoft\Excel\XLSTART";       Exts = @('.xlam','.xla','.xls','.xlsx'^) }
echo ^)
echo.
echo $appLabels = @{
echo     '.xlam'='Excel'; '.xla'='Excel'
echo     '.dotm'='Word';  '.dot'='Word'
echo     '.ppam'='PowerPoint'; '.ppa'='PowerPoint'
echo     '.xls'='Excel'; '.xlsx'='Excel'
echo }
echo.
echo $regKeys = @(
echo     @{ Path='HKCU:\Software\Microsoft\Office\Excel\Addins';           App='Excel';      Type='subkey' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\Word\Addins';            App='Word';        Type='subkey' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\PowerPoint\Addins';      App='PowerPoint';  Type='subkey' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\16.0\Excel\Options';     App='Excel';       Type='open' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\15.0\Excel\Options';     App='Excel';       Type='open' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\14.0\Excel\Options';     App='Excel';       Type='open' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\16.0\Word\Options';      App='Word';        Type='open' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\15.0\Word\Options';      App='Word';        Type='open' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options';App='PowerPoint';  Type='open' }
echo     @{ Path='HKCU:\Software\Microsoft\Office\15.0\PowerPoint\Options';App='PowerPoint';  Type='open' }
echo ^)
echo.
echo # ── Scan files ──────────────────────────────────────────────
echo $allItems = [System.Collections.ArrayList]::new(^)
echo $fileNames = [System.Collections.Generic.HashSet[string]]::new(^)
echo.
echo foreach ($sp in $scanPaths^) {
echo     if (-not (Test-Path $sp.Folder^)^) { continue }
echo     foreach ($f in Get-ChildItem -Path $sp.Folder -File^) {
echo         $ext = $f.Extension.ToLower(^)
echo         if ($sp.Exts -contains $ext^) {
echo             $app = if ($appLabels[$ext]^) { $appLabels[$ext] } else { 'Office' }
echo             [void]$allItems.Add(@{
echo                 Name   = $f.Name
echo                 Path   = $f.FullName
echo                 App    = $app
echo                 Source = 'file'
echo                 Tag    = $app
echo             }^)
echo             [void]$fileNames.Add($f.Name.ToLower(^)^)
echo         }
echo     }
echo }
echo.
echo # ── Scan registry: COM subkeys ─────────────────────────────
echo $regItems = [System.Collections.ArrayList]::new(^)
echo.
echo foreach ($rk in $regKeys^) {
echo     if (-not (Test-Path $rk.Path^)^) { continue }
echo.
echo     if ($rk.Type -eq 'subkey'^) {
echo         $subs = Get-ChildItem -Path $rk.Path 2^>$null
echo         foreach ($sub in $subs^) {
echo             $manifest = ''
echo             try { $manifest = (Get-ItemProperty -Path $sub.PSPath -Name 'Manifest' -EA Stop^).Manifest } catch {}
echo             if (-not $manifest^) {
echo                 try { $manifest = (Get-ItemProperty -Path $sub.PSPath -Name 'Path' -EA Stop^).Path } catch {}
echo             }
echo             [void]$regItems.Add(@{
echo                 Name      = $sub.PSChildName
echo                 RegPath   = $rk.Path
echo                 RegSub    = $sub.PSChildName
echo                 Manifest  = $manifest
echo                 App       = $rk.App
echo                 Source    = 'reg_subkey'
echo                 Tag       = "$($rk.App) / registry"
echo             }^)
echo         }
echo     }
echo.
echo     if ($rk.Type -eq 'open'^) {
echo         $props = Get-ItemProperty -Path $rk.Path 2^>$null
echo         if (-not $props^) { continue }
echo         foreach ($pn in $props.PSObject.Properties.Name^) {
echo             if ($pn -match '^OPEN\d*$'^) {
echo                 $val = $props.$pn
echo                 $display = $val -replace '^\s*/R\s*"?', '' -replace '"$', ''
echo                 $leaf = Split-Path $display -Leaf -EA SilentlyContinue
echo                 if (-not $leaf^) { $leaf = $val }
echo                 [void]$regItems.Add(@{
echo                     Name      = "$pn = $leaf"
echo                     RegPath   = $rk.Path
echo                     RegVal    = $pn
echo                     RegData   = $val
echo                     App       = $rk.App
echo                     Source    = 'reg_value'
echo                     Tag       = "$($rk.App) / registry"
echo                 }^)
echo             }
echo         }
echo     }
echo }
echo.
echo # ── Merge (skip registry dups that match a file) ───────────
echo foreach ($ri in $regItems^) {
echo     $dominated = $false
echo     foreach ($fn in $fileNames^) {
echo         if ($ri.Source -eq 'reg_value' -and $ri.RegData -and $ri.RegData.ToLower(^).Contains($fn^)^) { $dominated = $true; break }
echo         if ($ri.Source -eq 'reg_subkey' -and $ri.Manifest -and $ri.Manifest.ToLower(^).Contains($fn^)^) { $dominated = $true; break }
echo         if ($ri.Name.ToLower(^) -eq $fn^) { $dominated = $true; break }
echo     }
echo     if (-not $dominated^) { [void]$allItems.Add($ri^) }
echo }
echo.
echo # ── Display ─────────────────────────────────────────────────
echo Write-Host ''
echo Write-Host '====================================================' -ForegroundColor Cyan
echo Write-Host '  Office Add-in Remover  (Clean Uninstall^)' -ForegroundColor Cyan
echo Write-Host '====================================================' -ForegroundColor Cyan
echo.
echo if ($allItems.Count -eq 0^) {
echo     Write-Host "`nNo add-ins found (files or registry^).`n" -ForegroundColor Yellow
echo     Read-Host 'Press Enter to exit'
echo     exit
echo }
echo.
echo Write-Host "`nFound add-ins:`n"
echo for ($i = 0; $i -lt $allItems.Count; $i++^) {
echo     $a = $allItems[$i]
echo     $num = ($i + 1^).ToString(^).PadLeft(2^)
echo     Write-Host "  [$num]  $($a.Name)  ($($a.Tag^)^)"
echo }
echo.
echo Write-Host "`n  Total: $($allItems.Count^)"
echo Write-Host ''
echo Write-Host '  Select items to remove:'
echo Write-Host '    Single:   3'
echo Write-Host '    Multiple: 1,3,5'
echo Write-Host '    Range:    1-4'
echo Write-Host '    Mixed:    1-3,5,7'
echo Write-Host '    All:      all'
echo Write-Host ''
echo.
echo $choice = Read-Host '  Your selection (or q to quit^)'
echo if ($choice -match '^\s*$' -or $choice -eq 'q'^) {
echo     Write-Host '  Cancelled.'
echo     Read-Host "`nPress Enter to exit"
echo     exit
echo }
echo.
echo # ── Parse selection ─────────────────────────────────────────
echo function Parse-Selection($text, $max^) {
echo     $text = $text.Trim(^).ToLower(^)
echo     if ($text -in 'all','a','*'^) { return 0..($max - 1^) }
echo     $indices = [System.Collections.Generic.SortedSet[int]]::new(^)
echo     foreach ($part in $text -split ','  ^) {
echo         $p = $part.Trim(^)
echo         if ($p -match '^\d+\s*-\s*\d+$'^) {
echo             $bounds = $p -split '-'
echo             $lo = [int]$bounds[0]; $hi = [int]$bounds[1]
echo             if ($lo -gt $hi^) { $lo, $hi = $hi, $lo }
echo             for ($v = $lo; $v -le $hi; $v++^) { [void]$indices.Add($v^) }
echo         } elseif ($p -match '^\d+$'^) {
echo             [void]$indices.Add([int]$p^)
echo         } else { return $null }
echo     }
echo     $result = @(^)
echo     foreach ($v in $indices^) {
echo         $idx = $v - 1
echo         if ($idx -lt 0 -or $idx -ge $max^) { return $null }
echo         $result += $idx
echo     }
echo     return $result
echo }
echo.
echo $selIndices = Parse-Selection $choice $allItems.Count
echo if ($null -eq $selIndices^) {
echo     Write-Host '  Invalid selection.' -ForegroundColor Red
echo     Read-Host "`nPress Enter to exit"
echo     exit
echo }
echo.
echo $selected = @(^); foreach ($i in $selIndices^) { $selected += $allItems[$i] }
echo.
echo Write-Host "`n  You selected $($selected.Count^) add-in(s^):`n"
echo foreach ($s in $selected^) {
echo     $loc = if ($s.Path^) { $s.Path } else { "$($s.RegPath^)\$($s.RegSub^)$($s.RegVal^)" }
echo     Write-Host "    - $($s.Name^)  =  $loc"
echo }
echo.
echo $confirm = Read-Host "`n  Delete these $($selected.Count^) add-in(s^)? (y/n^)"
echo if ($confirm -ne 'y'^) {
echo     Write-Host '  Cancelled.'
echo     Read-Host "`nPress Enter to exit"
echo     exit
echo }
echo.
echo # ── Remove ──────────────────────────────────────────────────
echo $okCount = 0; $errCount = 0
echo Write-Host ''
echo.
echo function Remove-RegSubkey($item^) {
echo     try {
echo         Remove-Item -Path "$($item.RegPath^)\$($item.RegSub^)" -Recurse -Force -EA Stop
echo         Write-Host "  [OK]  Removed registry key: $($item.RegPath^)\$($item.RegSub^)" -ForegroundColor Green
echo         return $true
echo     } catch {
echo         Write-Host "  [ERR] $($_.Exception.Message^)" -ForegroundColor Red
echo         return $false
echo     }
echo }
echo.
echo function Remove-RegValue($item^) {
echo     try {
echo         Remove-ItemProperty -Path $item.RegPath -Name $item.RegVal -Force -EA Stop
echo         Write-Host "  [OK]  Removed registry value: $($item.RegPath^) = $($item.RegVal^)" -ForegroundColor Green
echo         return $true
echo     } catch {
echo         Write-Host "  [ERR] $($_.Exception.Message^)" -ForegroundColor Red
echo         return $false
echo     }
echo }
echo.
echo foreach ($s in $selected^) {
echo.
echo     # File removal
echo     if ($s.Source -eq 'file'^) {
echo         try {
echo             Remove-Item -Path $s.Path -Force -EA Stop
echo             Write-Host "  [OK]  Deleted file: $($s.Path^)" -ForegroundColor Green
echo             $okCount++
echo         } catch {
echo             Write-Host "  [ERR] $($_.Exception.Message^)" -ForegroundColor Red
echo             $errCount++
echo         }
echo         # Auto-clean matching registry entries
echo         $fn = $s.Name.ToLower(^)
echo         foreach ($ri in $regItems^) {
echo             $match = $false
echo             if ($ri.Source -eq 'reg_value' -and $ri.RegData -and $ri.RegData.ToLower(^).Contains($fn^)^) { $match = $true }
echo             if ($ri.Source -eq 'reg_subkey' -and $ri.Manifest -and $ri.Manifest.ToLower(^).Contains($fn^)^) { $match = $true }
echo             if ($ri.Name.ToLower(^) -eq $fn^) { $match = $true }
echo             if ($match^) {
echo                 if ($ri.Source -eq 'reg_subkey'^) {
echo                     if (Remove-RegSubkey $ri^) { $okCount++ } else { $errCount++ }
echo                 } elseif ($ri.Source -eq 'reg_value'^) {
echo                     if (Remove-RegValue $ri^) { $okCount++ } else { $errCount++ }
echo                 }
echo             }
echo         }
echo     }
echo.
echo     # Registry subkey removal
echo     if ($s.Source -eq 'reg_subkey'^) {
echo         if (Remove-RegSubkey $s^) { $okCount++ } else { $errCount++ }
echo     }
echo.
echo     # Registry value removal
echo     if ($s.Source -eq 'reg_value'^) {
echo         if (Remove-RegValue $s^) { $okCount++ } else { $errCount++ }
echo     }
echo }
echo.
echo Write-Host ''
echo Write-Host "  Done: $okCount succeeded, $errCount failed." -ForegroundColor Cyan
echo if ($errCount -gt 0^) {
echo     Write-Host "`n  Tip: Close all Office apps and retry if you got permission errors." -ForegroundColor Yellow
echo }
echo Write-Host ''
echo Read-Host 'Press Enter to exit'
)

:: Execute the temp PowerShell script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_TEMP%"

:: Clean up
del /f /q "%PS_TEMP%" >nul 2>&1
