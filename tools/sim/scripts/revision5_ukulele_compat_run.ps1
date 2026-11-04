param([string]$ModelSimDirectory="C:/modeltech64_10.6d/win64",
      [string]$PythonExecutable="python")
$ErrorActionPreference="Stop"
Push-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
try {
    $env:PATH=$ModelSimDirectory+";"+$env:PATH
    $libraryDirectory="build/revision5_ukulele_default_work"
    $buildDirectory="build/revision5_ukulele_default"
    New-Item -ItemType Directory -Force -Path $buildDirectory,"sim/results/revision5_ukulele_default_pitch" | Out-Null
    # Reuse revision4's independent acceptance checks without changing its library or artifacts.
    $test=Get-Content -Raw -LiteralPath "sim/revision4_ukulele_tb.v"
    $test=$test.Replace('revision4_ukulele_tb','revision5_ukulele_default_tb').Replace('revision4_ukulele_pitch','revision5_ukulele_default_pitch').Replace('revision4_ukulele_a4.txt','revision5_ukulele_default_a4.txt')
    Set-Content -LiteralPath "$buildDirectory/revision5_ukulele_default_tb.v" -Value $test -Encoding UTF8
    $analyzer=Get-Content -Raw -LiteralPath "scripts/analyze_revision4_ukulele.py"
    $analyzer=$analyzer.Replace('parents[1]','parents[2]').Replace('revision4_ukulele_pitch','revision5_ukulele_default_pitch').Replace('revision4_ukulele_a4.txt','revision5_ukulele_default_a4.txt').Replace('PASS revision4','PASS revision5 default compatibility')
    Set-Content -LiteralPath "$buildDirectory/analyze.py" -Value $analyzer -Encoding UTF8
    if(!(Test-Path "$libraryDirectory/_info")) { & vlib $libraryDirectory;if($LASTEXITCODE-ne 0){throw "vlib failed"} }
    & vlog +incdir+src -work $libraryDirectory src/instrument_body_resonator.v src/plucked_body_filter.v src/ukulele_waveguide_voice.v "$buildDirectory/revision5_ukulele_default_tb.v"
    if($LASTEXITCODE-ne 0){throw "Compile failed"}
    & vsim -c -lib $libraryDirectory revision5_ukulele_default_tb -l sim/results/revision5_ukulele_default.log -do "run -all; quit -f"
    $simulatorExitCode=$LASTEXITCODE
    $logText=Get-Content -Raw sim/results/revision5_ukulele_default.log
    if($simulatorExitCode-ne 0 -or $logText-notmatch 'PASS revision5_ukulele_default_tb' -or $logText-match '\*\* Fatal|Errors:\s*[1-9]'){throw "Default-rate compatibility failed"}
    & $PythonExecutable "$buildDirectory/analyze.py"
    if($LASTEXITCODE-ne 0){throw "Default-rate measurements failed"}
} finally {Pop-Location}
