# ===== STAGE 1: COMPLETE INVENTORY + VERIFICATION =====
# Run with PowerShell 7 (pwsh.exe) on a PC on the LAN, using an account with full read rights.
# Portable pwsh: https://github.com/PowerShell/PowerShell/releases (zip, no admin needed)
#
#   pwsh -File .\scanfiles.ps1            # inventory + robocopy + reconcile
#   pwsh -File .\scanfiles.ps1 -Only "AStar","BW Maritime"   # re-run specific folders
#
# DONE = reconcile.csv shows Status=OK for every folder AND errors.txt is empty.

param([string[]]$Only = @())

$Root   = '\\Sgsinvapfl20\20AP0026\S\SGBRS$'     # whole share, not just Workfiles
$OutDir = 'C:\Desktop'
$PerDir = Join-Path $OutDir 'per_folder'
$ErrLog = Join-Path $OutDir 'errors.txt'
New-Item -ItemType Directory -Force -Path $PerDir | Out-Null

function Q($s) { '"' + ($s -replace '"','""') + '"' }
function Safe($s) { ($s -replace '[\\/:*?"<>|]','_') }
$Header = '"TopFolder","FullPath","FileName","Ext","SizeBytes","Modified","Created","Depth","PathLen","Hidden"'

# ---------- 1. PowerShell inventory, one CSV per top-level folder ----------
function Inventory-Folder([string]$Name, [string]$Path, [switch]$NoRecurse) {
    $csv = Join-Path $PerDir ("{0}.csv" -f (Safe $Name))
    $sb  = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Header)
    $errs = @()
    $params = @{ LiteralPath=$Path; File=$true; Force=$true; ErrorAction='SilentlyContinue'; ErrorVariable='errs' }
    if (-not $NoRecurse) { $params.Recurse = $true }
    Get-ChildItem @params | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length)
        $hid = if ($_.Attributes -band [IO.FileAttributes]::Hidden) { 1 } else { 0 }
        [void]$sb.AppendLine((( Q $Name ), ( Q $_.FullName ), ( Q $_.Name ), ( Q $_.Extension.ToLower() ),
            $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.CreationTime.ToString('yyyy-MM-dd'),
            ($rel.Split('\').Count - 1), $_.FullName.Length, $hid) -join ',')
    }
    [IO.File]::WriteAllText($csv, $sb.ToString(), [Text.UTF8Encoding]::new($true))
    foreach ($e in $errs) { Add-Content $ErrLog ("{0}`t{1}`t{2}" -f $Name, $e.TargetObject, $e.Exception.Message) }
    return $csv
}

$tops = Get-ChildItem -LiteralPath $Root -Directory -Force
if ($Only.Count) { $tops = $tops | Where-Object { $Only -contains $_.Name }; Remove-Item $ErrLog -ErrorAction SilentlyContinue }
else { Remove-Item $ErrLog -ErrorAction SilentlyContinue; Inventory-Folder -Name '_ROOT_FILES' -Path $Root -NoRecurse | Out-Null }

$i = 0
foreach ($t in $tops) {
    $i++; Write-Host ("[{0}/{1}] {2}" -f $i, $tops.Count, $t.Name)
    Inventory-Folder -Name $t.Name -Path $t.FullName | Out-Null
}

# ---------- 2. Independent count via robocopy (native long-path engine) ----------
Write-Host "Robocopy verification pass..."
$rcLog = Join-Path $OutDir 'robocopy_summary.txt'
$rows = foreach ($t in $tops) {
    $log = Join-Path $OutDir ("rc_{0}.txt" -f (Safe $t.Name))
    robocopy $t.FullName 'C:\__null__' /L /S /E /BYTES /NFL /NDL /NJH /XJ /R:0 /W:0 /LOG:$log | Out-Null
    $txt  = Get-Content $log -Raw
    $rcFiles = [regex]::Match($txt, 'Files :\s+(\d+)').Groups[1].Value
    $rcBytes = [regex]::Match($txt, 'Bytes :\s+(\d+)').Groups[1].Value
    $csv = Join-Path $PerDir ("{0}.csv" -f (Safe $t.Name))
    $ps  = Import-Csv $csv
    $psFiles = @($ps).Count
    $psBytes = ($ps | Measure-Object -Property SizeBytes -Sum).Sum; if (-not $psBytes) { $psBytes = 0 }
    [pscustomobject]@{
        TopFolder = $t.Name; PS_Files = $psFiles; RC_Files = [int]$rcFiles
        PS_Bytes = [int64]$psBytes; RC_Bytes = [int64]$rcBytes
        Status = if ([int]$rcFiles -eq $psFiles -and [int64]$rcBytes -eq [int64]$psBytes) { 'OK' } else { 'MISMATCH' }
    }
}
$rows | Export-Csv (Join-Path $OutDir 'reconcile.csv') -NoTypeInformation
Remove-Item (Join-Path $OutDir 'rc_*.txt')

# ---------- 3. Merge ----------
$merged = Join-Path $OutDir 'inventory_ALL.csv'
Set-Content $merged $Header -Encoding UTF8
Get-ChildItem $PerDir -Filter *.csv | ForEach-Object { Get-Content $_.FullName | Select-Object -Skip 1 | Add-Content $merged -Encoding UTF8 }

$bad = @($rows | Where-Object Status -ne 'OK')
Write-Host ""
Write-Host ("Folders: {0}   OK: {1}   MISMATCH: {2}" -f $rows.Count, ($rows.Count - $bad.Count), $bad.Count)
Write-Host ("Total files: {0}   Long paths (>250): {1}" -f ((Get-Content $merged).Count - 1),
    @(Import-Csv $merged | Where-Object { [int]$_.PathLen -gt 250 }).Count)
if (Test-Path $ErrLog) { Write-Host "ERRORS logged -> $ErrLog  (fix rights, then re-run with -Only <folder>)" }
if ($bad.Count) { $bad | Format-Table -AutoSize }
