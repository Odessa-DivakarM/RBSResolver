# ---------------------------------------------------------------
#  RBS Resolver - static-site deploy script
#
#  Usage (run from any directory):
#      powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
#
#  What it does:
#    1. Verifies all four release files exist locally, and that the server's share is reachable.
#    2. Backs up the current site folder on LWPRODAPP-009.
#    3. Stops the IIS app pool.
#    4. Copies the four release files over UNC.
#    5. Restarts the app pool (always, once it was stopped - even if the copy failed).
#    6. Polls the site root for HTTP 200 to confirm it's up.
#
#  Stops at the first failure: a later step never runs after an earlier one failed, and the script ends
#  with "Deployment FAILED" and exit code 1. The one exception is restarting the app pool, which still
#  runs after a failed copy so the site isn't left down (it may then serve a mix of old and new files -
#  the failure message says which were copied).
#
#  Prerequisites on the local machine:
#    - WinRM access to LWPRODAPP-009 (Invoke-Command must work).
#    - Write access to \\LWPRODAPP-009\E$\Sites\RBSResolver via UNC.
# ---------------------------------------------------------------

# Every error is fatal. The default ('Continue') printed a failed connection or copy and carried on.
$ErrorActionPreference = 'Stop'

$server   = 'LWPRODAPP-009'
$sitePath = 'E:\Sites\RBSResolver'
$appPool  = 'RBSResolver'
$baseUrl  = 'http://rbsresolver.s009.odessacore.local'

$sourceDir    = (Resolve-Path "$PSScriptRoot\..").Path
$uncPath      = "\\$server\$($sitePath -replace '^([A-Za-z]):', '$1$')"
$releaseFiles = @('index.html', 'SPEC.html', 'SPEC.md', 'web.config')

$poolStopped = $false   # once true, the app pool must be started again whatever happens next
$copied      = @()
$failure     = $null

try {
    # -- Pre-flight: every release file present locally, server share reachable --
    Write-Host ""
    Write-Host "[pre-flight] Checking source files in: $sourceDir" -ForegroundColor Cyan
    foreach ($file in $releaseFiles) {
        $fullPath = "$sourceDir\$file"
        if (-not (Test-Path $fullPath)) {
            throw "Source file not found: $fullPath - nothing on the server was touched."
        }
        Write-Host "             $file  OK" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "[prod] Target  : $uncPath" -ForegroundColor Cyan
    if (-not (Test-Path $uncPath)) {
        throw "Cannot reach $uncPath (off the corporate network / VPN, or no access?) - nothing on the server was touched."
    }

    # -- Step 1: Backup current site + stop the app pool --
    Write-Host "[prod] Backing up site and stopping app pool '$appPool' ..." -ForegroundColor Cyan
    Invoke-Command -ComputerName $server -ErrorAction Stop -ArgumentList $sitePath, $appPool -ScriptBlock {
        param($sitePath, $appPool)
        $ErrorActionPreference = 'Stop'   # the remote session has its own preference
        Import-Module WebAdministration

        $backupPath = "${sitePath}_backup"
        if (Test-Path $sitePath) {
            if (Test-Path $backupPath) { Remove-Item $backupPath -Recurse -Force }
            robocopy $sitePath $backupPath /E /NP /NFL /NDL | Out-Null
            # robocopy: 0-7 = success (files copied / nothing to copy / extras), 8+ = at least one failure
            if ($LASTEXITCODE -ge 8) { throw "Backup failed (robocopy exit code $LASTEXITCODE) - app pool not stopped." }
            Write-Host "  Backup written to $backupPath"
        }

        try {
            Stop-WebAppPool -Name $appPool
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-WebAppPoolState -Name $appPool).Value -ne 'Stopped') {
                if ((Get-Date) -gt $deadline) { throw "App pool '$appPool' did not stop within 30 s." }
                Start-Sleep -Seconds 1
            }
        } catch {
            # Don't leave the site down because the stop half-worked.
            try { Start-WebAppPool -Name $appPool } catch { }
            throw
        }
        Write-Host "  App pool stopped."
    }
    $poolStopped = $true

    # -- Step 2: Copy the four release files over UNC (stops at the first failed file) --
    Write-Host "[prod] Copying files ..." -ForegroundColor Cyan
    foreach ($file in $releaseFiles) {
        Copy-Item -Path "$sourceDir\$file" -Destination "$uncPath\$file" -Force
        $copied += $file
        Write-Host "       copied  $file" -ForegroundColor Gray
    }
}
catch {
    $failure = $_
}
finally {
    # -- Step 3: Restart the app pool - always, once it was stopped --
    if ($poolStopped) {
        Write-Host "[prod] Starting app pool '$appPool' ..." -ForegroundColor Cyan
        try {
            Invoke-Command -ComputerName $server -ErrorAction Stop -ArgumentList $appPool -ScriptBlock {
                param($appPool)
                $ErrorActionPreference = 'Stop'
                Import-Module WebAdministration
                Start-WebAppPool -Name $appPool
                Write-Host "  App pool started."
            }
        } catch {
            Write-Host "[prod] Could not start app pool '$appPool': $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "[prod] THE SITE IS DOWN - start the pool on $server by hand." -ForegroundColor Red
            if (-not $failure) { $failure = $_ }
        }
    }
}

if ($failure) {
    Write-Host ""
    Write-Host "[prod] Deployment FAILED: $($failure.Exception.Message)" -ForegroundColor Red
    if ($poolStopped) {
        $notCopied = $releaseFiles | Where-Object { $copied -notcontains $_ }
        Write-Host "[prod] Copied: $(if ($copied) { $copied -join ', ' } else { 'none' }). Not copied: $(if ($notCopied) { $notCopied -join ', ' } else { 'none' })." -ForegroundColor Red
        if ($copied -and $notCopied) {
            Write-Host "[prod] The site now mixes new and old files. Re-run the deploy, or restore ${sitePath}_backup on $server." -ForegroundColor Red
        }
    } else {
        Write-Host "[prod] The site was not changed." -ForegroundColor Red
    }
    exit 1
}

# -- Step 4: Health check - poll the site root for HTTP 200 --
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
    Write-Host "[prod] Deployment complete - site is up at $baseUrl" -ForegroundColor Green
    exit 0
}
Write-Host "[prod] Deployment FAILED: files copied, but $baseUrl did not return HTTP 200 within 30 s. Check it manually." -ForegroundColor Red
exit 1
