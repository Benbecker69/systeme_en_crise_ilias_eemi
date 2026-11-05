<#
.SYNOPSIS
  Runs a project SQL file inside the PostgreSQL container (stops on first error).
.EXAMPLE
  ./scripts/run-sql.ps1 sql/migration.sql
#>
param(
    [Parameter(Mandatory = $true)][string]$File
)

$root = Split-Path -Parent $PSScriptRoot
$relative = $File -replace '\\', '/'
if (-not (Test-Path (Join-Path $root $relative))) {
    Write-Error "File not found: $relative"
    exit 1
}

Push-Location $root
try {
    docker compose exec -T db sh -c "psql -v ON_ERROR_STOP=1 -U `"`$POSTGRES_USER`" -d `"`$POSTGRES_DB`" -f /work/$relative"
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
