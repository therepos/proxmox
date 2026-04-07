@echo off
setlocal EnableDelayedExpansion
:: ============================================================
::  Office Add-in Export (XML + VBA + file copy)
::  Double-click to run. No Python needed.
:: ============================================================

set "PS_TEMP=%TEMP%\addin-export-%RANDOM%.ps1"

:: Extract everything after the __PS_BEGIN__ marker into a temp .ps1
set "FOUND="
(
    for /f "usebackq delims=" %%L in ("%~f0") do (
        if defined FOUND echo(%%L
        if "%%L"=="::__PS_BEGIN__" set "FOUND=1"
    )
) > "%PS_TEMP%"

:: Run it, passing the folder where this .bat lives as arg
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_TEMP%" "%~dp0"
set "RC=%ERRORLEVEL%"

:: Clean up
del /f /q "%PS_TEMP%" >nul 2>&1
exit /b %RC%

::__PS_BEGIN__
# =============================================================
# Office Add-in Export - PowerShell
# Strategy: COM first (cleanest), raw OLE fallback (no trust needed)
# =============================================================

param([string]$ScriptDir)
$ScriptDir = $ScriptDir.TrimEnd('\')

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Office Add-in Export'

# -- Config ---------------------------------------------------
$appdata = $env:APPDATA

$scanPaths = @(
    @{ Folder = "$appdata\Microsoft\AddIns";            Exts = @('.xlam','.xla','.ppam','.ppa') }
    @{ Folder = "$appdata\Microsoft\Word\STARTUP";      Exts = @('.dotm','.dot') }
    @{ Folder = "$appdata\Microsoft\PowerPoint\AddIns"; Exts = @('.ppam','.ppa') }
    @{ Folder = "$appdata\Microsoft\Excel\XLSTART";     Exts = @('.xlam','.xla') }
)

$appLabels = @{
    '.xlam'='Excel'; '.xla'='Excel'
    '.dotm'='Word';  '.dot'='Word'
    '.ppam'='PowerPoint'; '.ppa'='PowerPoint'
}

$comProgIds = @{
    'Excel'      = 'Excel.Application'
    'Word'       = 'Word.Application'
    'PowerPoint' = 'PowerPoint.Application'
}

$vbComponentTypes = @{
    1   = 'bas'   # vbext_ct_StdModule
    2   = 'cls'   # vbext_ct_ClassModule
    3   = 'frm'   # vbext_ct_MSForm
    100 = 'cls'   # vbext_ct_Document
}

$skipPatterns = @('ThisWorkbook','ThisDocument','Sheet1','Sheet2','Sheet3','Sheet4','Sheet5')

# The vbaProject.bin path inside the ZIP per app type
$vbaPaths = @{
    'Excel'      = 'xl/vbaProject.bin'
    'Word'       = 'word/vbaProject.bin'
    'PowerPoint' = 'ppt/vbaProject.bin'
}

# -- Scan files -----------------------------------------------
$allItems = [System.Collections.ArrayList]::new()

foreach ($sp in $scanPaths) {
    if (-not (Test-Path $sp.Folder)) { continue }
    foreach ($f in Get-ChildItem -Path $sp.Folder -File) {
        $ext = $f.Extension.ToLower()
        if ($sp.Exts -contains $ext) {
            $app = if ($appLabels[$ext]) { $appLabels[$ext] } else { 'Office' }
            [void]$allItems.Add(@{
                Name = $f.BaseName
                File = $f.Name
                Path = $f.FullName
                Ext  = $ext
                App  = $app
            })
        }
    }
}

$allItems = @($allItems | Sort-Object { $_.App }, { $_.Name.ToLower() })

# -- Display ---------------------------------------------------
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  Office Add-in Export' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

if ($allItems.Count -eq 0) {
    Write-Host "`nNo add-ins found.`n" -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit
}

Write-Host "`nFound add-ins:`n"
for ($i = 0; $i -lt $allItems.Count; $i++) {
    $a = $allItems[$i]
    $num = ($i + 1).ToString().PadLeft(2)
    Write-Host "  [$num]  $($a.File)  ($($a.App))"
}

Write-Host ''
$choice = Read-Host '  Enter number to export (or q to quit)'
if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq 'q') {
    Write-Host '  Cancelled.'
    Read-Host "`nPress Enter to exit"
    exit
}

try {
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $allItems.Count) { throw 'out of range' }
} catch {
    Write-Host '  Invalid selection.' -ForegroundColor Red
    Read-Host "`nPress Enter to exit"
    exit
}

$selected = $allItems[$idx]
$addinPath = $selected.Path
$outputDir = Join-Path $ScriptDir $selected.Name

Write-Host ''
Write-Host "  Exporting: $($selected.File)  ($($selected.App))"
Write-Host "  From:      $addinPath"
Write-Host "  To:        $outputDir"

if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

# =============================================================
# [1/3] Extract ribbon XML (native ZIP)
# =============================================================
Write-Host ''
Write-Host '[1/3] Extracting ribbon XML...' -ForegroundColor Cyan

$xmlExtracted = $false
$xmlCandidates = @(
    'customUI/customUI14.xml'
    'customUI/customUI.xml'
    'customUI14/customUI14.xml'
)

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($addinPath)

    foreach ($candidate in $xmlCandidates) {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $candidate } | Select-Object -First 1
        if ($entry) {
            $dest = Join-Path $outputDir "$($selected.Name).xml"
            $stream = $entry.Open()
            $fileStream = [System.IO.File]::Create($dest)
            $stream.CopyTo($fileStream)
            $fileStream.Close()
            $stream.Close()
            Write-Host "  -> $dest" -ForegroundColor Green
            $xmlExtracted = $true
            break
        }
    }

    $zip.Dispose()

    if (-not $xmlExtracted) {
        Write-Host '  -> No customUI XML found (skipped)' -ForegroundColor Yellow
    }
} catch {
    Write-Host "  -> WARNING: $($_.Exception.Message)" -ForegroundColor Yellow
}

# =============================================================
# [2/3] Extract VBA modules
#       Strategy A: COM automation (cleanest output)
#       Strategy B: Raw OLE binary parsing (no trust needed)
# =============================================================
Write-Host ''
Write-Host '[2/3] Extracting VBA modules...' -ForegroundColor Cyan

$vbaExtracted = $false

# ----- Strategy A: COM ----------------------------------------
function Export-VBA-COM {
    param($selected, $outputDir)

    $progId = $comProgIds[$selected.App]
    if (-not $progId) { return $false }

    $app = $null
    $wb  = $null

    try {
        $app = New-Object -ComObject $progId
        $app.Visible = $false
        $app.DisplayAlerts = $false

        switch ($selected.App) {
            'Excel'      { $wb = $app.Workbooks.Open($selected.Path, 0, $true) }
            'Word'       { $wb = $app.Documents.Open($selected.Path, $false, $true) }
            'PowerPoint' { $wb = $app.Presentations.Open($selected.Path, $true, $false, $false) }
        }

        $vbProject = $wb.VBProject
        if (-not $vbProject) { throw 'Cannot access VBProject' }

        $exportCount = 0

        foreach ($comp in $vbProject.VBComponents) {
            $compName = $comp.Name
            $compType = $comp.Type

            $skip = $false
            foreach ($pat in $skipPatterns) {
                if ($compName -like "$pat*") { $skip = $true; break }
            }
            if ($skip) { continue }

            $ext = $vbComponentTypes[[int]$compType]
            if (-not $ext) { continue }

            $codeModule = $comp.CodeModule
            if ($codeModule.CountOfLines -le 0) { continue }

            $exportFile = Join-Path $outputDir "$compName.$ext"
            $comp.Export($exportFile)
            Write-Host "  -> $exportFile" -ForegroundColor Green
            $exportCount++
        }

        if ($exportCount -gt 0) {
            Write-Host "  -> $exportCount module(s) exported via COM" -ForegroundColor Green
            return $true
        }
        return $false

    } catch {
        throw $_
    } finally {
        try {
            if ($wb) {
                switch ($selected.App) {
                    'Excel'      { $wb.Close($false) }
                    'Word'       { $wb.Close([ref]$false) }
                    'PowerPoint' { $wb.Close() }
                }
            }
        } catch {}
        try { if ($app) { $app.Quit() } } catch {}
        if ($wb)  { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) }
        if ($app) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

# ----- Strategy B: Raw OLE binary parsing ---------------------
# Reads vbaProject.bin from the ZIP, parses the Compound File Binary
# (CFB/OLE2) format, finds MODULE streams, decompresses VBA source.

function Decompress-VBA {
    # MS-OVBA 2.4.1 - RLE decompression
    param([byte[]]$data, [int]$offset)

    $result = [System.IO.MemoryStream]::new()
    $pos = $offset

    if ($pos -ge $data.Length) { return $result.ToArray() }

    $sigByte = $data[$pos]; $pos++
    if ($sigByte -ne 0x01) { return $result.ToArray() }

    while ($pos -lt $data.Length) {
        # Each chunk: 2-byte header + compressed data
        if (($pos + 1) -ge $data.Length) { break }
        $header = [BitConverter]::ToUInt16($data, $pos); $pos += 2
        $chunkSize = ($header -band 0x0FFF) + 3
        $isCompressed = ($header -band 0x8000) -ne 0
        $chunkEnd = $pos + $chunkSize - 2

        if ($chunkEnd -gt $data.Length) { $chunkEnd = $data.Length }

        if (-not $isCompressed) {
            while ($pos -lt $chunkEnd) {
                $result.WriteByte($data[$pos]); $pos++
            }
            continue
        }

        $decompStart = $result.Length

        while ($pos -lt $chunkEnd) {
            if ($pos -ge $data.Length) { break }
            $flagByte = $data[$pos]; $pos++

            for ($bit = 0; $bit -lt 8; $bit++) {
                if ($pos -ge $chunkEnd) { break }

                if (($flagByte -band (1 -shl $bit)) -eq 0) {
                    # Literal byte
                    $result.WriteByte($data[$pos]); $pos++
                } else {
                    # Copy token
                    if (($pos + 1) -ge $data.Length) { $pos += 2; break }
                    $token = [BitConverter]::ToUInt16($data, $pos); $pos += 2

                    $decompLen = $result.Length - $decompStart
                    if ($decompLen -le 0) { $decompLen = 1 }

                    $bitCount = [Math]::Max(4, [Math]::Ceiling([Math]::Log($decompLen, 2)))
                    if ($bitCount -gt 12) { $bitCount = 12 }
                    $lengthMask = 0xFFFF -shr $bitCount
                    $offsetShift = 16 - $bitCount

                    $copyLen = ($token -band $lengthMask) + 3
                    $copyOffset = ($token -shr (16 - $bitCount)) + 1

                    $buf = $result.ToArray()
                    for ($c = 0; $c -lt $copyLen; $c++) {
                        $srcPos = $buf.Length - $copyOffset
                        if ($srcPos -lt 0) { $result.WriteByte(0); continue }
                        $result.WriteByte($buf[$srcPos])
                        $buf = $result.ToArray()
                    }
                }
            }
        }
    }

    return $result.ToArray()
}

function Read-UInt32LE([byte[]]$bytes, [int]$offset) {
    return [BitConverter]::ToUInt32($bytes, $offset)
}

function Read-UInt16LE([byte[]]$bytes, [int]$offset) {
    return [BitConverter]::ToUInt16($bytes, $offset)
}

function Export-VBA-Raw {
    param($selected, $outputDir)

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Find vbaProject.bin in ZIP
    $vbaPath = $vbaPaths[$selected.App]
    if (-not $vbaPath) { return $false }

    $zip = $null
    $binBytes = $null

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($selected.Path)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $vbaPath } | Select-Object -First 1
        if (-not $entry) {
            # Try alternate casings
            $entry = $zip.Entries | Where-Object { $_.FullName -ieq $vbaPath } | Select-Object -First 1
        }
        if (-not $entry) {
            Write-Host '  -> No vbaProject.bin found (skipped)' -ForegroundColor Yellow
            return $false
        }

        $ms = [System.IO.MemoryStream]::new()
        $stream = $entry.Open()
        $stream.CopyTo($ms)
        $stream.Close()
        $binBytes = $ms.ToArray()
        $ms.Close()
    } catch {
        Write-Host "  -> WARNING: Cannot read vbaProject.bin: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    } finally {
        if ($zip) { $zip.Dispose() }
    }

    # Parse CFB (Compound File Binary Format) / OLE2
    # Header: first 512 bytes
    if ($binBytes.Length -lt 512) {
        Write-Host '  -> vbaProject.bin too small' -ForegroundColor Yellow
        return $false
    }

    $magic = [BitConverter]::ToString($binBytes, 0, 8)
    if ($magic -ne 'D0-CF-11-E0-A1-B1-1A-E1') {
        Write-Host '  -> Not a valid OLE2 file' -ForegroundColor Yellow
        return $false
    }

    $sectorSize = [Math]::Pow(2, (Read-UInt16LE $binBytes 30))
    $miniSectorSize = [Math]::Pow(2, (Read-UInt16LE $binBytes 32))
    $fatSectors = Read-UInt32LE $binBytes 44
    $dirStart = Read-UInt32LE $binBytes 48
    $miniCutoff = Read-UInt32LE $binBytes 56
    $miniFatStart = Read-UInt32LE $binBytes 60

    # Helper: sector offset
    function SectorOffset([int]$sector) { return (($sector + 1) * $sectorSize) }

    # Build FAT (sector allocation table)
    $fat = [System.Collections.ArrayList]::new()
    $difatEntries = @()
    for ($i = 0; $i -lt [Math]::Min(109, $fatSectors); $i++) {
        $difatEntries += (Read-UInt32LE $binBytes (76 + $i * 4))
    }
    foreach ($fs in $difatEntries) {
        if ($fs -ge 0xFFFFFFFE) { continue }
        $off = SectorOffset $fs
        for ($j = 0; $j -lt ($sectorSize / 4); $j++) {
            if (($off + $j * 4 + 3) -lt $binBytes.Length) {
                [void]$fat.Add((Read-UInt32LE $binBytes ($off + $j * 4)))
            }
        }
    }

    # Read a chain of sectors
    function Read-SectorChain([int]$startSector) {
        $ms = [System.IO.MemoryStream]::new()
        $sec = $startSector
        $safety = 0
        while ($sec -lt 0xFFFFFFFE -and $safety -lt 100000) {
            $off = SectorOffset $sec
            $len = [Math]::Min($sectorSize, $binBytes.Length - $off)
            if ($off -ge $binBytes.Length -or $len -le 0) { break }
            $ms.Write($binBytes, $off, $len)
            if ($sec -ge $fat.Count) { break }
            $sec = $fat[$sec]
            $safety++
        }
        return $ms.ToArray()
    }

    # Read directory entries
    $dirData = Read-SectorChain $dirStart
    $entries = @()
    for ($i = 0; ($i * 128) + 127 -lt $dirData.Length; $i++) {
        $off = $i * 128
        $nameLen = (Read-UInt16LE $dirData ($off + 64))
        if ($nameLen -le 0 -or $nameLen -gt 64) { continue }
        $nameBytes = $dirData[($off)..($off + $nameLen - 1)]
        $entryName = [System.Text.Encoding]::Unicode.GetString($nameBytes).TrimEnd("`0")
        $entryType = $dirData[$off + 66]
        $entryStart = Read-UInt32LE $dirData ($off + 116)
        $entrySize = Read-UInt32LE $dirData ($off + 120)

        $entries += @{
            Name      = $entryName
            Type      = $entryType  # 1=storage, 2=stream, 5=root
            Start     = $entryStart
            Size      = $entrySize
            Index     = $i
        }
    }

    # Build mini-FAT and mini-stream if needed
    $rootEntry = $entries | Where-Object { $_.Type -eq 5 } | Select-Object -First 1
    $miniStreamData = $null
    $miniFat = @()

    if ($rootEntry -and $miniFatStart -lt 0xFFFFFFFE) {
        $miniStreamData = Read-SectorChain $rootEntry.Start

        $miniFatData = Read-SectorChain $miniFatStart
        for ($i = 0; ($i * 4 + 3) -lt $miniFatData.Length; $i++) {
            $miniFat += (Read-UInt32LE $miniFatData ($i * 4))
        }
    }

    function Read-MiniSectorChain([int]$startSector, [int]$size) {
        if (-not $miniStreamData) { return @() }
        $ms = [System.IO.MemoryStream]::new()
        $sec = $startSector
        $remaining = $size
        $safety = 0
        while ($sec -lt 0xFFFFFFFE -and $remaining -gt 0 -and $safety -lt 100000) {
            $off = $sec * $miniSectorSize
            $len = [Math]::Min($miniSectorSize, [Math]::Min($remaining, $miniStreamData.Length - $off))
            if ($off -ge $miniStreamData.Length -or $len -le 0) { break }
            $ms.Write($miniStreamData, $off, $len)
            $remaining -= $len
            if ($sec -ge $miniFat.Count) { break }
            $sec = $miniFat[$sec]
            $safety++
        }
        return $ms.ToArray()
    }

    function Read-StreamData($entry) {
        if ($entry.Size -lt $miniCutoff -and $miniStreamData) {
            return Read-MiniSectorChain $entry.Start $entry.Size
        } else {
            $data = Read-SectorChain $entry.Start
            if ($data.Length -gt $entry.Size) {
                $data = $data[0..($entry.Size - 1)]
            }
            return $data
        }
    }

    # Find VBA/dir stream to get module names and offsets
    $dirEntry = $entries | Where-Object { $_.Name -eq 'dir' } | Select-Object -First 1
    if (-not $dirEntry) {
        Write-Host '  -> No dir stream found in vbaProject.bin' -ForegroundColor Yellow
        return $false
    }

    $dirCompressed = Read-StreamData $dirEntry
    $dirDecompressed = Decompress-VBA $dirCompressed 0

    if (-not $dirDecompressed -or $dirDecompressed.Length -eq 0) {
        Write-Host '  -> Could not decompress dir stream' -ForegroundColor Yellow
        return $false
    }

    # Parse dir stream to find module names and code offsets
    # MS-OVBA 2.3.4.2 - dir stream records
    $modules = @()
    $pos = 0
    $dd = $dirDecompressed
    $currentModule = $null

    while ($pos + 5 -lt $dd.Length) {
        $recordId = Read-UInt16LE $dd $pos
        $recordSize = Read-UInt32LE $dd ($pos + 2)
        $dataStart = $pos + 6

        switch ($recordId) {
            0x0019 { # MODULENAME
                if ($currentModule) { $modules += $currentModule }
                $nameBytes = $dd[$dataStart..($dataStart + $recordSize - 1)]
                $moduleName = [System.Text.Encoding]::ASCII.GetString($nameBytes).TrimEnd("`0")
                $currentModule = @{ Name = $moduleName; Offset = 0; StreamName = $moduleName }
            }
            0x0031 { # MODULEOFFSET
                if ($currentModule -and $recordSize -ge 4) {
                    $currentModule.Offset = Read-UInt32LE $dd $dataStart
                }
            }
            0x002B { # MODULE terminator
                if ($currentModule) {
                    $modules += $currentModule
                    $currentModule = $null
                }
            }
        }

        $pos = $dataStart + $recordSize
    }
    if ($currentModule) { $modules += $currentModule }

    # Export each module
    $exportCount = 0

    foreach ($mod in $modules) {
        $modName = $mod.Name

        # Skip document modules
        $skip = $false
        foreach ($pat in $skipPatterns) {
            if ($modName -like "$pat*") { $skip = $true; break }
        }
        if ($skip) { continue }

        # Find the stream in the CFB
        $streamEntry = $entries | Where-Object { $_.Name -eq $mod.StreamName } | Select-Object -First 1
        if (-not $streamEntry) { continue }

        $streamData = Read-StreamData $streamEntry
        if (-not $streamData -or $streamData.Length -le $mod.Offset) { continue }

        try {
            $sourceBytes = Decompress-VBA $streamData $mod.Offset
            if (-not $sourceBytes -or $sourceBytes.Length -eq 0) { continue }

            $source = [System.Text.Encoding]::UTF8.GetString($sourceBytes)
            if ([string]::IsNullOrWhiteSpace($source)) { continue }

            # Clean up source
            $source = $source -replace "`r`n", "`n" -replace "`r", "`n"

            $dest = Join-Path $outputDir "$modName.bas"
            [System.IO.File]::WriteAllText($dest, $source, [System.Text.Encoding]::UTF8)
            Write-Host "  -> $dest" -ForegroundColor Green
            $exportCount++
        } catch {
            Write-Host "  -> WARNING: Could not decompress $modName : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($exportCount -gt 0) {
        Write-Host "  -> $exportCount module(s) exported via raw OLE parsing" -ForegroundColor Green
        return $true
    } else {
        Write-Host '  -> No standard modules found' -ForegroundColor Yellow
        return $false
    }
}

# ----- Try COM first, fallback to raw parsing -----------------
$comSuccess = $false

try {
    $comSuccess = Export-VBA-COM $selected $outputDir
} catch {
    $msg = $_.Exception.Message
    if ($msg -match 'programmatic access|VBProject|6068') {
        Write-Host '  -> COM blocked (Trust access not enabled), trying raw parsing...' -ForegroundColor Yellow
    } elseif ($msg -match 'CLSID|ComObject|HRESULT|Retrieving') {
        Write-Host "  -> Office COM not available, trying raw parsing..." -ForegroundColor Yellow
    } else {
        Write-Host "  -> COM failed: $msg" -ForegroundColor Yellow
        Write-Host '  -> Trying raw parsing...' -ForegroundColor Yellow
    }
}

if (-not $comSuccess) {
    try {
        $vbaExtracted = Export-VBA-Raw $selected $outputDir
    } catch {
        Write-Host "  -> Raw parsing failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =============================================================
# [3/3] Copy add-in file
# =============================================================
Write-Host ''
Write-Host '[3/3] Copying add-in file...' -ForegroundColor Cyan

try {
    $dest = Join-Path $outputDir $selected.File
    Copy-Item -Path $addinPath -Destination $dest -Force
    Write-Host "  -> $dest" -ForegroundColor Green
} catch {
    Write-Host "  -> ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

# -- Summary ---------------------------------------------------
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  Done!' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Output folder: $outputDir"
Write-Host ''

# Open the output folder in Explorer
try { Start-Process explorer.exe $outputDir } catch {}

Read-Host 'Press Enter to exit'
