# ---------------------------------------------------------------
#  RBS Resolver - static-site deploy script
#
#  Usage (run from any directory):
#      powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
#
#  What it does:
#    1. Verifies all five release files exist locally, and that the server's share is reachable.
#    2. Backs up the current site folder on LWPRODAPP-009 (to _backup_new, replacing _backup only once
#       complete, so a failed backup keeps the previous one).
#    3. Stops the IIS app pool (if it is running).
#    4. Copies the five release files over UNC (creating scripts\ on the server if needed).
#    5. Makes sure the app pool is running again - whenever step 2/3 reached the server, even if a
#       later step failed or the connection dropped after the pool was stopped.
#    6. Polls the site root for HTTP 200 to confirm it's up, then checks the SQL script is served.
#
#  Stops at the first failure: a later step never runs after an earlier one failed, and the script ends
#  with "Deployment FAILED" and exit code 1. The one exception is step 5, which still runs after a
#  failure so the site isn't left down (after a failed copy it may serve a mix of old and new files -
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
# scripts\export-users.sql is downloaded from the app ("Users from Odessa"), so it ships too, at the same path.
$releaseFiles = @('index.html', 'SPEC.html', 'SPEC.md', 'web.config', 'scripts\export-users.sql')

$stopAttempted = $false   # step 1 reached the server: the pool MAY be stopped even if step 1 failed
$poolStopped   = $false   # step 1 confirmed the pool is stopped
$poolAfter     = $null    # the pool's state reported by step 3 ('Started', or $null if it couldn't be checked)
$copied        = @()
$failure       = $null
$session       = $null

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
    # Connect first: if the session can't even be opened, nothing on the server was touched ("not changed").
    # Once it is open, a failure may come after the remote stop (e.g. the connection drops), so step 3 must
    # check the pool rather than the script reporting "not changed" for a site that is down.
    $session = New-PSSession -ComputerName $server -ErrorAction Stop
    $stopAttempted = $true
    Invoke-Command -Session $session -ErrorAction Stop -ArgumentList $sitePath, $appPool -ScriptBlock {
        param($sitePath, $appPool)
        $ErrorActionPreference = 'Stop'   # the remote session has its own preference
        Import-Module WebAdministration

        # The new backup goes to _backup_new and only replaces the old one once it is complete, so a
        # failed backup never destroys the last good rollback point.
        $backupPath = "${sitePath}_backup"
        $newBackup  = "${sitePath}_backup_new"
        if (Test-Path $sitePath) {
            if (Test-Path $newBackup) { Remove-Item $newBackup -Recurse -Force }   # left by an earlier failed run
            robocopy $sitePath $newBackup /E /NP /NFL /NDL | Out-Null
            # robocopy: 0-7 = success (files copied / nothing to copy / extras), 8+ = at least one failure
            if ($LASTEXITCODE -ge 8) {
                $code = $LASTEXITCODE
                Remove-Item $newBackup -Recurse -Force -ErrorAction SilentlyContinue
                throw "Backup failed (robocopy exit code $code) - the previous backup was kept and the app pool was not stopped."
            }
            if (Test-Path $backupPath) { Remove-Item $backupPath -Recurse -Force }
            Rename-Item -Path $newBackup -NewName (Split-Path $backupPath -Leaf)
            Write-Host "  Backup written to $backupPath"
        }

        # Act on the pool's real state: it may already be stopped (by hand, or by an earlier failed run).
        $state = (Get-WebAppPoolState -Name $appPool).Value
        if ($state -eq 'Stopped') {
            Write-Host "  App pool was already stopped."
        } else {
            try {
                $stopSent = $false
                $deadline = (Get-Date).AddSeconds(30)
                while (($now = (Get-WebAppPoolState -Name $appPool).Value) -ne 'Stopped') {
                    # Stop only a running pool; one still 'Starting' is stopped once it gets there.
                    if ($now -eq 'Started' -and -not $stopSent) { Stop-WebAppPool -Name $appPool; $stopSent = $true; continue }
                    if ((Get-Date) -gt $deadline) { throw "App pool '$appPool' did not stop within 30 s (it was '$state', now '$now')." }
                    Start-Sleep -Seconds 1
                }
            } catch {
                # Don't leave the site down because the stop half-worked.
                try { if ((Get-WebAppPoolState -Name $appPool).Value -ne 'Started') { Start-WebAppPool -Name $appPool } } catch { }
                throw
            }
            Write-Host "  App pool stopped."
        }
    }
    $poolStopped = $true

    # -- Step 2: Copy the five release files over UNC (stops at the first failed file) --
    Write-Host "[prod] Copying files ..." -ForegroundColor Cyan
    foreach ($file in $releaseFiles) {
        $destDir = Split-Path "$uncPath\$file" -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        Copy-Item -Path "$sourceDir\$file" -Destination "$uncPath\$file" -Force
        $copied += $file
        Write-Host "       copied  $file" -ForegroundColor Gray
    }
}
catch {
    $failure = $_
}
finally {
    # -- Step 3: Make sure the app pool is running - whenever step 1 reached the server --
    # Checks the real state rather than assuming: after a failed step 1 the pool may or may not be stopped.
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    if ($stopAttempted) {
        Write-Host "[prod] Making sure app pool '$appPool' is running ..." -ForegroundColor Cyan
        try {
            $poolAfter = Invoke-Command -ComputerName $server -ErrorAction Stop -ArgumentList $appPool -ScriptBlock {
                param($appPool)
                $ErrorActionPreference = 'Stop'
                Import-Module WebAdministration
                if ((Get-WebAppPoolState -Name $appPool).Value -eq 'Started') {
                    Write-Host "  App pool is running."
                } else {
                    Start-WebAppPool -Name $appPool
                    Write-Host "  App pool started."
                }
                (Get-WebAppPoolState -Name $appPool).Value
            }
        } catch {
            Write-Host "[prod] Could not check or start app pool '$appPool': $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "[prod] THE SITE MAY BE DOWN - check the pool on $server and start it by hand." -ForegroundColor Red
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
    } elseif ($stopAttempted) {
        # Step 1 failed on or on the way to the server: no file was copied, but the pool may have been
        # stopped. Step 3 above says what it found.
        $poolNote = if ($poolAfter -eq 'Started') { 'the app pool is running' } else { "the app pool's state is unknown" }
        Write-Host "[prod] No files were copied; $poolNote." -ForegroundColor Red
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
    # The app links to the SQL script; IIS must serve it (a .sql mapping in web.config), or the browser
    # would save an IIS error page as export-users.sql.
    $sqlUrl = "$baseUrl/scripts/export-users.sql"
    $sqlWhy = $null
    try {
        $s = Invoke-WebRequest -Uri $sqlUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $body = if ($s.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($s.Content) } else { [string]$s.Content }
        if ($s.StatusCode -ne 200) { $sqlWhy = "HTTP $($s.StatusCode)" }
        elseif (-not $body.TrimStart().StartsWith('/*')) { $sqlWhy = 'the response is not the SQL script' }
    } catch { $sqlWhy = $_.Exception.Message }
    if ($sqlWhy) {
        Write-Host "[prod] Deployment FAILED: the site is up, but $sqlUrl is not served as the SQL script ($sqlWhy). Check the .sql mapping and request filtering in IIS." -ForegroundColor Red
        exit 1
    }
    Write-Host "[prod] Deployment complete - site is up at $baseUrl" -ForegroundColor Green
    exit 0
}
Write-Host "[prod] Deployment FAILED: files copied, but $baseUrl did not return HTTP 200 within 30 s. Check it manually." -ForegroundColor Red
exit 1
