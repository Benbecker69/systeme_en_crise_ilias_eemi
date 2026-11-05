<#
.SYNOPSIS
  Builds the Directus application (run after the migration). Re-runnable.
#>
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    & "$PSScriptRoot/run-sql.ps1" directus/relations.sql
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    python -I directus/setup.py
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
