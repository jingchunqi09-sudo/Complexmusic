param([string]$ModelSimBin='C:/modeltech64_10.6d/win64')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskBuild='build/physical_20261025/control_sim'
Push-Location $taskRoot
try {
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    if(!(Test-Path -LiteralPath "$taskBuild/work")) {
        & "$ModelSimBin/vlib.exe" "$taskBuild/work"
        if($LASTEXITCODE -ne 0){throw 'ModelSim vlib failed'}
    }
    & "$ModelSimBin/vlog.exe" -work "$taskBuild/work" src/bow_motion_tracker.v src/performer_pitch_map.v src/ms_core_ch.v src/ms_string_top.v src/piezo_onset_bank.v src/piezo_transient_core.v sim/physical_20261025/tb_performer_controls.v
    if($LASTEXITCODE -ne 0){throw 'Performer control compile failed'}
    $taskLog="$taskBuild/tb_performer_controls.log"
    & "$ModelSimBin/vsim.exe" -c -lib "$taskBuild/work" tb_performer_controls -l $taskLog -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
    if($LASTEXITCODE -ne 0){throw 'Performer control simulation failed'}
    $taskText=Get-Content -LiteralPath $taskLog -Raw
    if($taskText -notmatch '# PASS performer controls:' -or $taskText -match '\*\* (Fatal|Error)' -or $taskText -match '# FAIL '){throw 'Performer control simulation lacks PASS or contains failure'}
} finally {Pop-Location}
