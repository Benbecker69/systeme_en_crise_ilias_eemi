<#
.SYNOPSIS
  Builds the Directus application (run after the migration). Re-runnable.
  The Python script runs in the "outils" container: no local Python needed.
#>
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    & "$PSScriptRoot/run-sql.ps1" directus/relations.sql
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    docker compose run --rm outils python directus/setup.py
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
