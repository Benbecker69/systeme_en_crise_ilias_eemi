<#
.SYNOPSIS
  Checks the access separation of the Directus application with the demo accounts.
#>
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    docker compose run --rm outils python directus/verify.py
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
