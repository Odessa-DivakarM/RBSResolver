<#
.SYNOPSIS
  Export Odessa users, their login roles and the site-level default to a JSON file RBS Resolver can load.

.DESCRIPTION
  Runs scripts/export-users.sql (a single read-only SELECT) and writes its result as UTF-8.
  The file lists every login and its roles: treat it as sensitive, don't commit or share it
  (*.rbs-users.json is in .gitignore). RBS Resolver reads it in the browser; it is never uploaded.

.EXAMPLE
  .\scripts\export-users.ps1 -Server lwproddb-008 -Database Fx4_Dev_Core
  Windows authentication; writes .\Fx4_Dev_Core.rbs-users.json

.EXAMPLE
  .\scripts\export-users.ps1 -Server lwproddb-008 -Database Fx4_Dev_Core -Credential (Get-Credential) -LoginName jdoe
  SQL authentication (prompts), one user only.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Server,
  [Parameter(Mandatory = $true)] [string] $Database,
  [string] $LoginName,
  [string] $OutFile,
  [System.Management.Automation.PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'

try {
  if ($PSBoundParameters.ContainsKey('LoginName') -and [string]::IsNullOrWhiteSpace($LoginName)) {
    throw '-LoginName is blank. Leave it out to export every user.'
  }
  $sqlPath = Join-Path $PSScriptRoot 'export-users.sql'
  $sql = [System.IO.File]::ReadAllText($sqlPath)
  # The .sql declares @LoginName for SSMS; here it is passed as a real parameter instead.
  $pattern = '(?s)-- <parameters>.*?-- </parameters>'
  if ($sql -notmatch $pattern) { throw "The <parameters> block is missing from $sqlPath." }
  $sql = [regex]::Replace($sql, $pattern, '')

  $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
  $csb['Data Source'] = $Server
  $csb['Initial Catalog'] = $Database
  $csb['Application Name'] = 'RBS Resolver user export'
  $csb['ApplicationIntent'] = 'ReadOnly'
  if ($Credential) {
    $csb['Integrated Security'] = $false
    $secret = $Credential.Password.Copy(); $secret.MakeReadOnly()
    $conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString,
      (New-Object System.Data.SqlClient.SqlCredential($Credential.UserName, $secret)))
  } else {
    $csb['Integrated Security'] = $true
    $conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
  }

  try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 300
    $p = $cmd.Parameters.Add('@LoginName', [System.Data.SqlDbType]::NVarChar, 100)
    $p.Value = if ([string]::IsNullOrWhiteSpace($LoginName)) { [DBNull]::Value } else { $LoginName }
    $json = $cmd.ExecuteScalar()
  } finally {
    $conn.Dispose()
  }

  if ($json -isnot [string] -or -not $json.StartsWith('{')) { throw 'The query did not return a JSON document.' }
  $doc = $json | ConvertFrom-Json
  if ($doc.format -ne 'rbs-users/1') { throw "Unexpected format '$($doc.format)'." }

  if (-not $OutFile) {
    $name = if ($LoginName) { "$Database.$LoginName" } else { $Database }
    $name = ($name -replace '[\\/:*?"<>|]', '_')
    $OutFile = Join-Path (Get-Location) "$name.rbs-users.json"
  }
  # Relative to the PowerShell location, not the process directory ([IO.Path]::GetFullPath would use that).
  $OutFile = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutFile)
  [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))

  $users = @($doc.users).Count
  $site = if ($null -eq $doc.siteLevelDefault) { 'not set (the framework uses Full)' } else { "'$($doc.siteLevelDefault)' (as stored)" }
  Write-Host "Exported $users user(s) and $(@($doc.roles).Count) active role(s) from $($doc.source.server) / $($doc.source.database)."
  Write-Host "Site-level default: $site"
  Write-Host "Written to $OutFile"
  if ($LoginName -and $users -eq 0) { Write-Warning "No user has the login name '$LoginName'." }
  Write-Host 'This file lists every login and its roles. Keep it private.' -ForegroundColor Yellow
  exit 0
} catch {
  Write-Host "Export FAILED: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
