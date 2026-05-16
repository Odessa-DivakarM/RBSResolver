# ---------------------------------------------------------------
#  RBS Resolver — static-site deploy script
#
#  Usage (run from any directory):
#      powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
#
#  What it does:
#    1. Verifies all four release files exist locally.
#    2. Backs up the current site folder on LWPRODAPP-009.
#    3. Stops the IIS app pool.
#    4. Copies the four release files over UNC.
#    5. Restarts the app pool (always — even if the copy failed).
#    6. Polls the site root for HTTP 200 to confirm it's up.
#
#  Prerequisites on the local machine:
#    - WinRM access to LWPRODAPP-009 (Invoke-Command must work).
#    - Write access to \\LWPRODAPP-009\E$\Sites\RBSResolver via UNC.
# ---------------------------------------------------------------

$server   = 'LWPRODAPP-009'
$sitePath = 'E:\Sites\RBSResolver'
$appPool  = 'RBSResolver'
$baseUrl  = 'http://rbsresolver.s009.odessacore.local'

$sourceDir    = (Resolve-Path "$PSScriptRoot\..").Path
$uncPath      = "\\$server\$($sitePath -replace '^([A-Za-z]):', '$1$')"
$releaseFiles = @('index.html', 'SPEC.html', 'SPEC.md', 'web.config')

# ── Pre-flight: confirm every release file is present locally ──
Write-Host ""
Write-Host "[pre-flight] Checking source files in: $sourceDir" -ForegroundColor Cyan
foreach ($file in $releaseFiles) {
    $fullPath = "$sourceDir\$file"
    if (-not (Test-Path $fullPath)) {
        throw "Source file not found: $fullPath — aborting before touching the server."
    }
    Write-Host "             $file  OK" -ForegroundColor Gray
}

Write-Host ""
Write-Host "[prod] Target  : $uncPath" -ForegroundColor Cyan

# ── Step 1: Backup current site + stop the app pool ──
Write-Host "[prod] Backing up site and stopping app pool '$appPool' ..." -ForegroundColor Cyan
Invoke-Command -ComputerName $server -ScriptBlock {
    param($sitePath, $appPool)
    Import-Module WebAdministration

    $backupPath = "${sitePath}_backup"
    if (Test-Path $sitePath) {
        if (Test-Path $backupPath) { Remove-Item $backupPath -Recurse -Force }
        robocopy $sitePath $backupPath /E /NP /NFL /NDL | Out-Null
        Write-Host "  Backup written to $backupPath"
    }

    Stop-WebAppPool -Name $appPool
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-WebAppPoolState -Name $appPool).Value -ne 'Stopped') {
        if ((Get-Date) -gt $deadline) { throw "App pool '$appPool' did not stop within 30 s." }
        Start-Sleep -Seconds 1
    }
    Write-Host "  App pool stopped."
} -ArgumentList $sitePath, $appPool

try {
    # ── Step 2: Copy the four release files over UNC ──
    Write-Host "[prod] Copying files ..." -ForegroundColor Cyan
    foreach ($file in $releaseFiles) {
        Copy-Item -Path "$sourceDir\$file" -Destination "$uncPath\$file" -Force
        Write-Host "       copied  $file" -ForegroundColor Gray
    }
}
finally {
    # ── Step 3: Restart the app pool — always, even on copy failure ──
    Write-Host "[prod] Starting app pool '$appPool' ..." -ForegroundColor Cyan
    Invoke-Command -ComputerName $server -ScriptBlock {
        param($appPool)
        Import-Module WebAdministration
        Start-WebAppPool -Name $appPool
        Write-Host "  App pool started."
    } -ArgumentList $appPool
}

# ── Step 4: Health check — poll the site root for HTTP 200 ──
Write-Host "[prod] Waiting for $baseUrl to respond ..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(30)
$ok       = $false
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ok = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}

Write-Host ""
if ($ok) {
    Write-Host "[prod] Deployment complete — site is up at $baseUrl" -ForegroundColor Green
} else {
    Write-Warning "[prod] Site did not return HTTP 200 within 30 s. Check $baseUrl manually."
}
