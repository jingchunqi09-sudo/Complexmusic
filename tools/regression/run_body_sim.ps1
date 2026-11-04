param([string]$ModelSimDirectory = "D:\applicationstudy\modelsim\win64", [string]$PythonExecutable = "")
$ErrorActionPreference = "Stop"
$projectDirectory = Split-Path -Parent $PSScriptRoot
Push-Location $projectDirectory
try {
    $env:PATH = $ModelSimDirectory + ";" + $env:PATH
    $libraryDirectory = "build/body_regression"
    New-Item -ItemType Directory -Force -Path "build", "sim/results" | Out-Null
    if (-not (Test-Path "$libraryDirectory/_info")) { & vlib $libraryDirectory }
    & vlog -work $libraryDirectory src/instrument_body_resonator.v sim/instrument_body_resonator_tb.v
    if ($LASTEXITCODE -ne 0) { throw "Body RTL compilation failed." }
    & vsim -c -lib $libraryDirectory instrument_body_resonator_tb -l sim/results/instrument_body_resonator_tb.log -do "run -all; quit -f"
    $simulationExit = $LASTEXITCODE
    $logText = Get-Content -Raw sim/results/instrument_body_resonator_tb.log
    if ($simulationExit -ne 0 -or $logText -notmatch "PASS instrument_body_resonator_tb" -or $logText -match "FAIL|\*\* Fatal") {
        throw "Body testbench failed."
    }
    if ($PythonExecutable) {
        & $PythonExecutable scripts/analyze_body_resonator.py
        if ($LASTEXITCODE -ne 0) { throw "Body frequency/pole check failed." }
    }
} finally { Pop-Location }
