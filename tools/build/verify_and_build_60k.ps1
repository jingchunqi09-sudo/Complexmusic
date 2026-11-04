param(
    [string]$PythonExecutable = 'python',
    [switch]$Rebuild,
    [string]$Label = ''
)
# Current R9 entry. Default rechecks the retained same-source qualification.
# Rebuild uses an unused explicit label and the identical production constraints.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & $PythonExecutable scripts/revision9_joint_qualify.py --candidate next_final --stage next --evidence-spec docs/verification/r9_20261012/evidence.json
    if ($LASTEXITCODE) { throw 'Current source/evidence qualification failed.' }
    if ($Rebuild) {
        if ($Label -notmatch '^[A-Za-z0-9_]+$') { throw 'Rebuild requires an unused -Label containing letters, digits or underscores.' }
        & $PythonExecutable scripts/revision9_build_candidate.py --label $Label --physical-map
        if ($LASTEXITCODE) { throw 'Candidate build failed.' }
        & $PythonExecutable scripts/revision9_joint_qualify.py --candidate $Label --stage next --evidence-spec docs/verification/r9_20261012/evidence.json
        if ($LASTEXITCODE) { throw 'Rebuilt candidate qualification failed.' }
    }
    Write-Output 'Digital checks passed. No serial connection, programming or board qualification performed.'
} finally {
    Pop-Location
}
