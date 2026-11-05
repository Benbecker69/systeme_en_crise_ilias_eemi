<#
.SYNOPSIS
  1. Re-runs the migration and checks it changes nothing (idempotency).
  2. Runs the SQL test suite (all changes rolled back).
#>
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $snapshotCmd = "psql -v ON_ERROR_STOP=1 -U `"`$POSTGRES_USER`" -d `"`$POSTGRES_DB`" -At -f /work/sql/tests/snapshot.sql"
    $before = docker compose exec -T db sh -c $snapshotCmd
    if ($LASTEXITCODE -ne 0 -or -not $before) { Write-Error "Snapshot failed (run the migration first)"; exit 1 }

    & "$PSScriptRoot/run-sql.ps1" sql/migration.sql | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Migration re-run failed"; exit 1 }

    $after = docker compose exec -T db sh -c $snapshotCmd
    if (-not $after -or $before -ne $after) {
        Write-Error "Idempotency FAIL`n before: $before`n after:  $after"
        exit 1
    }
    Write-Output "--- T00 idempotency PASS ($after)"

    & "$PSScriptRoot/run-sql.ps1" sql/tests/test_migration.sql 2>&1 |
        Where-Object { $_ -match 'PASS|FAIL|ERROR|---|===' } |
        ForEach-Object { ($_ -replace '^.*NOTICE:\s*', '') }
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
