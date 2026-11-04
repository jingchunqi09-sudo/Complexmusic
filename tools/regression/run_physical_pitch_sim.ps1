param([string]$ModelSimBin='C:/modeltech64_10.6d/win64')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskBuild='build/physical_20261025/pitch_boundary'
Push-Location $taskRoot
try{
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    if(!(Test-Path -LiteralPath "$taskBuild/work")){& "$ModelSimBin/vlib.exe" "$taskBuild/work"}
    $taskPaths=@('src/performer_pitch_map.v','sim/physical_20261025/performer_pitch_map_before.v.txt','sim/physical_20261025/tb_pitch_group_boundary.v')
    $taskHashes=@{}
    foreach($taskPath in $taskPaths){$taskHashes[$taskPath]=(Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    & "$ModelSimBin/vlog.exe" -work "$taskBuild/work" @taskPaths
    if($LASTEXITCODE -ne 0){throw 'Pitch boundary compile failed'}
    $taskLog="$taskBuild/tb_pitch_group_boundary.log"
    & "$ModelSimBin/vsim.exe" -c -lib "$taskBuild/work" tb_pitch_group_boundary -l $taskLog -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
    $taskText=Get-Content -Raw -LiteralPath $taskLog
    if($taskText -notmatch 'PASS pitch group boundary: transitions=9 production_counterexamples=3 candidate_errors=0' -or $taskText -match '\*\* (Fatal|Error)'){throw 'Pitch boundary lacks expected before-fail/after-pass result'}
    foreach($taskPath in $taskPaths){if((Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskHashes[$taskPath]){throw 'Pitch source changed during test'}}
    [ordered]@{status='PASS_BEFORE_COUNTEREXAMPLE_AFTER_FIXED';source_sha256=$taskHashes;log_sha256=(Get-FileHash -LiteralPath $taskLog -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$taskBuild/qualification.json"
} finally {Pop-Location}
