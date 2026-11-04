param([string]$ModelSimDirectory="C:/modeltech64_10.6d/win64",
      [string]$PythonExecutable="python")
$ErrorActionPreference="Stop"
Push-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
try {
    $env:PATH=$ModelSimDirectory+";"+$env:PATH
    $libraryDirectory="build/revision5_ukulele_decay_work"
    New-Item -ItemType Directory -Force -Path "build","sim/results/revision5_ukulele" | Out-Null
    if(!(Test-Path "$libraryDirectory/_info")) { & vlib $libraryDirectory;if($LASTEXITCODE-ne 0){throw "vlib failed"} }
    & vlog +incdir+src -work $libraryDirectory src/instrument_body_resonator.v src/plucked_body_filter.v src/ukulele_waveguide_voice.v sim/scripts/revision5_ukulele_decay_tb.v
    if($LASTEXITCODE-ne 0){throw "Compile failed"}
    & vsim -c -lib $libraryDirectory revision5_ukulele_decay_tb -l sim/results/revision5_ukulele/natural_decay.log -do "run -all; quit -f"
    $simulatorExitCode=$LASTEXITCODE
    $logText=Get-Content -Raw sim/results/revision5_ukulele/natural_decay.log
    if($simulatorExitCode-ne 0 -or $logText-notmatch 'PASS revision5_ukulele_decay_tb' -or $logText-match '\*\* Fatal|Errors:\s*[1-9]'){throw "Natural decay simulation failed"}
    & $PythonExecutable sim/scripts/revision5_ukulele_decay_analyze.py
    if($LASTEXITCODE-ne 0){throw "Natural-tail AC/DC audit failed"}
} finally {Pop-Location}
