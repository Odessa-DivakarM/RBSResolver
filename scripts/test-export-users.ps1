<#
.SYNOPSIS
  Checks scripts/export-users.sql and export-users.ps1 against a real Odessa database. Read-only.

.DESCRIPTION
  Run it before releasing a change to the export. Every check prints PASS or FAIL; the exit code is 1 when
  any fails. Nothing is written to the database. The one export file it makes goes to %TEMP% and is deleted.

  1. The .sql file: one <parameters> and one <result> block, ASCII only, and the escapes in <result> still
     built from NCHAR(92) (an editor can silently turn a typed escape back into the character).
  2. Run as SSMS runs it: one <?rbs-users {json}?> value, with "?>" only at the very end, and valid JSON.
  3. export-users.ps1 writes the same JSON (apart from exportedAt), and -LoginName exports just that user.
  4. Every user's roles equal the login join (GetRolesForUser: RolesForUsers, Roles, RoleFunctions, all active),
     and the site default, the role list with each default, and the lockout match their own queries.
  5. "?>", U+FFFE, U+FFFF and "\?>" inside a JSON string come back unchanged through the <result> block.

.EXAMPLE
  .\scripts\test-export-users.ps1 -Server lwproddb-008 -Database Fx4_Dev_Core -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Server,
  [Parameter(Mandatory = $true)] [string] $Database,
  [System.Management.Automation.PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'
$script:failed = 0
# A test passes only by returning $true; returning a string fails it with that string as the reason.
function Check([string] $name, [scriptblock] $test) {
  try { $r = & $test; $ok = ($r -is [bool]) -and $r } catch { $ok = $false; $r = $_.Exception.Message }
  if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
  else { $script:failed++; Write-Host "FAIL  $name$(if ($r -is [string] -and $r) { " - $r" })" -ForegroundColor Red }
}
function Open-Connection {
  $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
  $csb['Data Source'] = $Server; $csb['Initial Catalog'] = $Database; $csb['Application Name'] = 'RBS Resolver export test'
  if ($Credential) {
    $csb['Integrated Security'] = $false
    $secret = $Credential.Password.Copy(); $secret.MakeReadOnly()
    $c = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString, (New-Object System.Data.SqlClient.SqlCredential($Credential.UserName, $secret)))
  } else {
    $csb['Integrated Security'] = $true
    $c = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
  }
  $c.Open(); $c
}
function Scalar([string] $sql) {
  $c = Open-Connection
  try { $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300; $cmd.ExecuteScalar() } finally { $c.Dispose() }
}
# Exact comparison. -ceq and IndexOf(string) follow the current culture, which ignores characters such as
# U+FFFE / U+FFFF and treats "?>" + a combining mark as not containing "?>".
function Same-Text([string] $a, [string] $b) { [string]::Equals($a, $b, [StringComparison]::Ordinal) }
function Ends-Only-With-PI-Close([string] $x) { $x.IndexOf('?>', [StringComparison]::Ordinal) -eq $x.Length - 2 }
# Compares two export documents, ignoring when each was made.
function Same-Doc($a, $b) {
  $a.exportedAt = $null; $b.exportedAt = $null
  Same-Text ($a | ConvertTo-Json -Depth 10 -Compress) ($b | ConvertTo-Json -Depth 10 -Compress)
}

$sqlPath = Join-Path $PSScriptRoot 'export-users.sql'
$sql = [System.IO.File]::ReadAllText($sqlPath)
$resultBlock = [regex]::Match($sql, '(?s)-- <result>.*?-- </result>').Value
$tmp = Join-Path $env:TEMP ("rbs-export-test-{0}.rbs-users.json" -f [guid]::NewGuid().ToString('N'))

Write-Host "Testing the users export against $Server / $Database (read-only)" -ForegroundColor Cyan

# 1 -- the file
Check 'the .sql has exactly one <parameters> block and one <result> block' {
  ([regex]::Matches($sql, '-- <parameters>').Count -eq 1) -and ([regex]::Matches($sql, '-- </parameters>').Count -eq 1) -and
  ([regex]::Matches($sql, '-- <result>').Count -eq 1) -and ([regex]::Matches($sql, '-- </result>').Count -eq 1)
}
Check 'the .sql is ASCII only (SSMS may open it in any code page)' { -not ($sql.ToCharArray() | Where-Object { [int]$_ -gt 127 }) }
Check 'the <result> escapes are still built from NCHAR(92), not typed' {
  $resultBlock.Contains('NCHAR(92)') -and $resultBlock.Contains("N'u003e'") -and $resultBlock.Contains("N'ufffe'") -and $resultBlock.Contains("N'uffff'")
}

# 2 -- run as SSMS runs it: the file exactly as downloaded
$ssms = $null
Check 'run as-is, it returns one <?rbs-users {json}?> value whose JSON is valid' {
  $x = [string](Scalar $sql)
  $m = [regex]::Match($x, '(?s)^<\?rbs-users\s(.*)\?>$')
  if (-not $m.Success) { return 'not a <?rbs-users ...?> value' }
  if (-not (Ends-Only-With-PI-Close $x)) { return '"?>" occurs before the end, so the wrapper ends early' }
  $script:ssms = $m.Groups[1].Value | ConvertFrom-Json
  $script:ssms.format -eq 'rbs-users/1'
}

# 3 -- export-users.ps1
$runnerArgs = @{ Server = $Server; Database = $Database; OutFile = $tmp }
if ($Credential) { $runnerArgs.Credential = $Credential }
try {
  Check 'export-users.ps1 writes the same JSON as the SSMS route (apart from exportedAt)' {
    & (Join-Path $PSScriptRoot 'export-users.ps1') @runnerArgs *> $null
    if ($LASTEXITCODE -ne 0) { return "export-users.ps1 exited $LASTEXITCODE" }
    $file = [System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    if (-not $script:ssms) { return 'no SSMS result to compare with' }
    Same-Doc $file ($script:ssms | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
  }
  Check 'export-users.ps1 -LoginName exports only that user' {
    if (-not $script:ssms) { return 'no SSMS result to compare with' }
    $first = @($script:ssms.users)[0]
    & (Join-Path $PSScriptRoot 'export-users.ps1') @runnerArgs -LoginName $first.loginName *> $null
    $one = [System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    $want = @($script:ssms.users | Where-Object { $_.loginName -eq $first.loginName }).Count   # the SQL match ignores case, like login
    ($LASTEXITCODE -eq 0) -and (@($one.users).Count -eq $want) -and (@($one.users | Where-Object { $_.loginName -ne $first.loginName }).Count -eq 0)
  }
} finally {
  if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp }
}

# 4 -- the roles login loads
Check "every user's roles equal the login join" {
  if (-not $script:ssms) { return 'no SSMS result to compare with' }
  $c = Open-Connection
  try {
    $cmd = $c.CreateCommand()
    $cmd.CommandText = 'SELECT rfu.UserId, r.Name FROM dbo.RolesForUsers rfu JOIN dbo.Roles r ON r.Id = rfu.RoleId JOIN dbo.RoleFunctions rf ON rf.Id = r.RoleFunctionId WHERE rfu.IsActive = 1 AND r.IsActive = 1 AND rf.IsActive = 1'
    $rd = $cmd.ExecuteReader(); $db = @{}
    while ($rd.Read()) { $k = [string]$rd.GetInt64(0); if (-not $db.ContainsKey($k)) { $db[$k] = New-Object System.Collections.Generic.List[string] }; $db[$k].Add($rd.GetString(1)) }
    $rd.Close()
    $cmd.CommandText = 'SELECT COUNT(*) FROM dbo.Users'; $users = [int]$cmd.ExecuteScalar()
  } finally { $c.Dispose() }
  if (@($script:ssms.users).Count -ne $users) { return "$(@($script:ssms.users).Count) users exported, $users in dbo.Users" }
  $bad = @($script:ssms.users | Where-Object {
    -not (Same-Text ((@($_.roles | ForEach-Object { $_.name }) | Sort-Object) -join '|') ((@($db[[string]$_.id]) | Where-Object { $_ } | Sort-Object) -join '|'))
  })
  if ($bad.Count) { return "$($bad.Count) user(s) differ, e.g. #$($bad[0].id)" }
  $true
}

# 4b -- the rest of the document
Check 'the site default, the role list with their defaults, and the lockout match the database' {
  if (-not $script:ssms) { return 'no SSMS result to compare with' }
  $c = Open-Connection
  try {
    $cmd = $c.CreateCommand()
    $cmd.CommandText = "SELECT Value FROM dbo.GlobalParameters WHERE Category COLLATE Latin1_General_BIN2 = N'UserRole' AND Name COLLATE Latin1_General_BIN2 = N'DefaultRolePermission' AND IsActive = 1"
    $site = $cmd.ExecuteScalar(); if ($site -is [DBNull]) { $site = $null }
    $cmd.CommandText = 'SELECT TOP (1) AccountLockoutDurationInMins FROM dbo.SecurityConfigs ORDER BY Id'
    $lock = $cmd.ExecuteScalar(); if ($lock -is [DBNull]) { $lock = $null }
    $cmd.CommandText = 'SELECT r.Name, r.DefaultPermission FROM dbo.Roles r JOIN dbo.RoleFunctions rf ON rf.Id = r.RoleFunctionId WHERE r.IsActive = 1 AND rf.IsActive = 1'
    $rd = $cmd.ExecuteReader(); $roles = New-Object System.Collections.Generic.List[string]
    while ($rd.Read()) { $roles.Add($rd.GetString(0) + '=' + $rd.GetString(1)) }
    $rd.Close()
  } finally { $c.Dispose() }
  # null (no row: Full) and '' (blank: Undefined) mean different things, and [string] would make both ''.
  if ((($null -eq $script:ssms.siteLevelDefault) -ne ($null -eq $site)) -or -not (Same-Text $script:ssms.siteLevelDefault $site)) {
    return "site default '$($script:ssms.siteLevelDefault)' exported, '$site' in the database"
  }
  if ($script:ssms.accountLockoutDurationInMins -ne $lock) { return "lockout $($script:ssms.accountLockoutDurationInMins) exported, $lock in the database" }
  $exported = (@($script:ssms.roles | ForEach-Object { $_.name + '=' + $_.defaultPermission }) | Sort-Object) -join '|'
  if (-not (Same-Text $exported ((@($roles) | Sort-Object) -join '|'))) { return "role list differs ($(@($script:ssms.roles).Count) exported, $($roles.Count) in the database)" }
  $true
}

# 5 -- the escapes in <result>, on a made-up value: a?>b U+FFFE U+FFFF c\?>d
Check '"?>", U+FFFE, U+FFFF and "\?>" come back unchanged through the XML wrapper' {
  $value = "N'a?' + NCHAR(62) + N'b' + NCHAR(65534) + NCHAR(65535) + N'c' + NCHAR(92) + NCHAR(92) + N'?' + NCHAR(62) + N'd'"
  $batch = "DECLARE @json nvarchar(max) = N'{`"s`":`"' + $value + N'`"}';`n" + $resultBlock
  $x = [string](Scalar $batch)
  if (-not (Ends-Only-With-PI-Close $x)) { return '"?>" occurs before the end' }
  $s = ([regex]::Match($x, '(?s)^<\?rbs-users\s(.*)\?>$').Groups[1].Value | ConvertFrom-Json).s
  $want = 'a?>b' + [char]0xFFFE + [char]0xFFFF + 'c' + [char]92 + '?>d'
  if (-not (Same-Text $s $want)) { return "got $($s.Length) characters, want $($want.Length)" }
  $true
}

Write-Host ''
if ($script:failed) { Write-Host "$script:failed check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
exit 0
