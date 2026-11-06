<#
.SYNOPSIS
  Full installation from scratch, in one command:
  .env -> empty database + seed -> migration -> SQL tests -> application -> rights checks.
  WARNING: destroys the existing containers and volumes (scripts/reset.ps1).
#>
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $steps = @(
        @('1/6 .env file', { & "$PSScriptRoot/init-env.ps1" }),
        @('2/6 Empty database + seed', { & "$PSScriptRoot/reset.ps1" }),
        @('3/6 Migration', { & "$PSScriptRoot/run-sql.ps1" sql/migration.sql | Out-Null }),
        @('4/6 SQL tests (idempotency + integrity)', { & "$PSScriptRoot/test.ps1" }),
        @('5/6 Directus application', { & "$PSScriptRoot/setup-app.ps1" }),
        @('6/6 Access rights checks', { & "$PSScriptRoot/verify-app.ps1" })
    )
    foreach ($step in $steps) {
        Write-Output "`n===== $($step[0])"
        & $step[1]
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed at step: $($step[0])"; exit 1 }
    }
    Write-Output @'

===== Installation complete
  Application: http://localhost:8055
  pgAdmin:     http://localhost:5050
  PostgreSQL:  localhost:5433, database maintenancepro
  Accounts: docs/guide-installation.md, passwords in .env
'@
    exit 0
}
finally {
    Pop-Location
}
