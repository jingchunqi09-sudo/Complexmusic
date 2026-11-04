param(
    [switch]$Quick,
    [string]$ModelSimDirectory = "C:/modeltech64_10.6d/win64",
    [string]$PythonExecutable = "python"
)
$ErrorActionPreference = "Stop"
$projectDirectory = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $projectDirectory
try {
    $env:PATH = $ModelSimDirectory + ";" + $env:PATH
    $libraryDirectory = "build/revision5_ukulele_work"
    New-Item -ItemType Directory -Force -Path "build","sim/results/revision5_ukulele" | Out-Null
    $baselineDirectory="sim/scripts/revision5_ukulele_baseline"
    $baselineBuild="build/revision5_ukulele_baseline"
    New-Item -ItemType Directory -Force -Path $baselineBuild | Out-Null
    foreach($entry in (Get-Content -Raw "$baselineDirectory/source_hashes.json" | ConvertFrom-Json)) {
        $name=Split-Path -Leaf $entry.Path
        if((Get-FileHash -LiteralPath "$baselineDirectory/$name" -Algorithm SHA256).Hash -ne $entry.SHA256) {
            throw "Frozen A/B baseline hash mismatch: $name"
        }
    }
    Copy-Item -LiteralPath "$baselineDirectory/source_hashes.json" -Destination "$baselineBuild/source_hashes.json" -Force
    $model=Get-Content -Raw -LiteralPath "$baselineDirectory/ukulele_waveguide_voice.v"
    $model=$model.Replace('module ukulele_waveguide_voice #(', 'module revision4_ukulele_baseline #(').Replace('instrument_body_resonator u_body','revision4_ukulele_body u_body').Replace('plucked_body_filter u_body','revision4_ukulele_legacy_body u_body').Replace('"src/instrument_pitch.vh"','"sim/scripts/revision5_ukulele_baseline/instrument_pitch.vh"')
    Set-Content -LiteralPath "$baselineBuild/revision4_ukulele_baseline.v" -Value $model -Encoding UTF8
    $body=Get-Content -Raw -LiteralPath "$baselineDirectory/instrument_body_resonator.v"
    Set-Content -LiteralPath "$baselineBuild/revision4_ukulele_body.v" -Value $body.Replace('module instrument_body_resonator','module revision4_ukulele_body') -Encoding UTF8
    $body=Get-Content -Raw -LiteralPath "$baselineDirectory/plucked_body_filter.v"
    Set-Content -LiteralPath "$baselineBuild/revision4_ukulele_legacy_body.v" -Value $body.Replace('module plucked_body_filter','module revision4_ukulele_legacy_body') -Encoding UTF8
    if (-not (Test-Path "$libraryDirectory/_info")) {
        & vlib $libraryDirectory
        if ($LASTEXITCODE -ne 0) { throw "Cannot create independent simulation library." }
    }
    & vlog +incdir+src -work $libraryDirectory src/instrument_body_resonator.v src/plucked_body_filter.v src/voice_envelope.v src/ukulele_waveguide_voice.v build/revision5_ukulele_baseline/revision4_ukulele_body.v build/revision5_ukulele_baseline/revision4_ukulele_legacy_body.v build/revision5_ukulele_baseline/revision4_ukulele_baseline.v sim/scripts/revision5_ukulele_tb.v
    if ($LASTEXITCODE -ne 0) { throw "Ukulele RTL compilation failed." }
    $logPath = "sim/results/revision5_ukulele/simulation.log"
    if ($Quick) {
        & vsim -c -lib $libraryDirectory revision5_ukulele_tb +quick -l $logPath -do "run -all; quit -f"
    } else {
        & vsim -c -lib $libraryDirectory revision5_ukulele_tb -l $logPath -do "run -all; quit -f"
    }
    $simulatorExitCode = $LASTEXITCODE
    $logText = Get-Content -Raw $logPath
    if ($simulatorExitCode -ne 0 -or $logText -notmatch "PASS revision5_ukulele_tb" -or
        $logText -match "FAIL|\*\* Fatal|Errors:\s*[1-9]") { throw "Ukulele RTL regression failed; see $logPath." }
    if (!$Quick) {
        & $PythonExecutable sim/scripts/revision5_ukulele_analyze.py
        if ($LASTEXITCODE -ne 0) { throw "Ukulele audio measurements failed." }
    }
} finally { Pop-Location }
