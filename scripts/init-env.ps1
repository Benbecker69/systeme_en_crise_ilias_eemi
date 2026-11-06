<#
.SYNOPSIS
  Creates .env from .env.example, replacing every "change-me" value with a
  random secret. Does nothing if .env already exists.
#>
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root '.env'
if (Test-Path $target) {
    Write-Output '.env already exists: kept as is'
    exit 0
}

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function New-Secret([int]$bytes) {
    $buffer = New-Object byte[] $bytes
    $rng.GetBytes($buffer)
    return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

$lines = Get-Content (Join-Path $root '.env.example') -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=change-me') {
        $size = 16
        if ($Matches[1] -eq 'DIRECTUS_SECRET') { $size = 32 }
        "$($Matches[1])=$(New-Secret $size)"
    }
    else { $_ }
}
# UTF-8 without BOM, LF line endings (read by Docker Compose and Python)
[System.IO.File]::WriteAllText($target, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
Write-Output '.env created with random secrets'
