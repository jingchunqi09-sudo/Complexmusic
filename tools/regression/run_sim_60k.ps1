param(
    [string]$Python = '',
    [string]$ModelSimDirectory = '',
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive' }
    if ($PSBoundParameters.ContainsKey('Python') -and [string]::IsNullOrWhiteSpace($Python)) { throw 'Explicit -Python is empty' }
    if ($PSBoundParameters.ContainsKey('ModelSimDirectory') -and [string]::IsNullOrWhiteSpace($ModelSimDirectory)) { throw 'Explicit -ModelSimDirectory is empty' }
    $pythonExplicit = -not [string]::IsNullOrWhiteSpace($Python)
    if (-not $pythonExplicit) {
        $Python = $env:R9_PYTHON
        if ([string]::IsNullOrWhiteSpace($Python)) {
            $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
            if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction SilentlyContinue }
            if ($null -ne $pythonCommand) { $Python = $pythonCommand.Source }
        }
    }
    if ([string]::IsNullOrWhiteSpace($Python) -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw 'Python executable is missing or invalid. Use -Python, or set R9_PYTHON.'
    }
    & $Python --version
    if ($LASTEXITCODE -ne 0) { throw 'Python version preflight failed' }
    $modelExplicit = -not [string]::IsNullOrWhiteSpace($ModelSimDirectory)
    if (-not $modelExplicit) { $ModelSimDirectory = $env:R9_MODELSIM_DIR }
    $common = @('--timeout-seconds', [string]$TimeoutSeconds)
    if (-not [string]::IsNullOrWhiteSpace($ModelSimDirectory)) {
        $common += @('--modelsim-dir', $ModelSimDirectory)
    }
    & $Python scripts/revision9_peripheral_verify.py @common
    if ($LASTEXITCODE -ne 0) { throw 'Peripheral regression failed' }
    & $Python scripts/revision9_verify.py --test top @common
    if ($LASTEXITCODE -ne 0) { throw 'PT8211 top regression failed' }
    exit 0
} finally { Pop-Location }
