<#
.SYNOPSIS
  Destroys every container and volume, then starts from an empty database
  where the legacy seed is executed as-is.
#>
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    docker compose down -v
    docker compose up -d --wait
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
