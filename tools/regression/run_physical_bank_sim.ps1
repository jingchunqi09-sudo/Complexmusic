param([string]$ModelSimBin='C:/modeltech64_10.6d/win64')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskBuild='build/physical_20261025/bank_integration'
Push-Location $taskRoot
try {
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    if(!(Test-Path -LiteralPath "$taskBuild/work")) {
        & "$ModelSimBin/vlib.exe" "$taskBuild/work"
        if($LASTEXITCODE -ne 0){throw 'ModelSim vlib failed'}
    }
    $taskSources=@(Get-ChildItem -LiteralPath src -Filter '*.v' -File | ForEach-Object {$_.FullName})
    $taskSources += (Join-Path $taskRoot 'sim/physical_20261025/tb_physical_bank_integration.v')
    $taskHashPaths=@($taskSources)+(Join-Path $taskRoot 'scripts/run_physical_bank_sim.ps1')+
        @(Get-ChildItem -LiteralPath src -Filter '*.vh' -File | ForEach-Object {$_.FullName})+
        @(Get-ChildItem -LiteralPath sim/physical_20261025/model_candidates -File | ForEach-Object {$_.FullName})
    $taskBefore=@{}
    foreach($taskPath in $taskHashPaths){$taskBefore[$taskPath]=(Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    & "$ModelSimBin/vlog.exe" -work "$taskBuild/work" '+incdir+src' @taskSources 2>&1 | Tee-Object -FilePath "$taskBuild/compile.log"
    if($LASTEXITCODE -ne 0){throw 'Physical bank integration compile failed'}
    $taskLog="$taskBuild/tb_physical_bank_integration.log"
    & "$ModelSimBin/vsim.exe" -c -lib "$taskBuild/work" tb_physical_bank_integration -l $taskLog -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
    if($LASTEXITCODE -ne 0){throw 'Physical bank integration failed'}
    $taskText=Get-Content -LiteralPath $taskLog -Raw
    if($taskText -notmatch '# PASS physical bank integration:' -or $taskText -match '\*\* (Fatal|Error)' -or $taskText -match '# FAIL '){throw 'Integration lacks PASS or contains failure'}
    $taskNegativeLog="$taskBuild/negative_wrong_velocity.log"
    & "$ModelSimBin/vsim.exe" -c -lib "$taskBuild/work" tb_physical_bank_integration -gNEGATIVE_WRONG_LANE=1 -l $taskNegativeLog -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
    $taskNegativeText=Get-Content -LiteralPath $taskNegativeLog -Raw
    if($taskNegativeText -notmatch 'FAIL physical bank integration.*bank snapshot preserves independent pluck velocities' -or $taskNegativeText -match '# PASS physical bank integration:'){throw 'Negative wrong-velocity self-check was not rejected at the intended assertion'}
    foreach($taskPath in $taskHashPaths){if((Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskBefore[$taskPath]){throw "Source changed while test ran: $taskPath"}}
    $taskManifest=[ordered]@{status='PASS';negative_self_check='PASS wrong pending velocity byte rejected';timestamp_utc=[DateTime]::UtcNow.ToString('o');tool='ModelSim SE-64 10.6d';source_sha256=$taskBefore;log_sha256=(Get-FileHash -LiteralPath $taskLog -Algorithm SHA256).Hash.ToLowerInvariant();boundary='Real production top/frontend/controllers/8 voices/PT8211; sensor publication boundaries forced; no external SPI/analog/board validation'}
    $taskManifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 "$taskBuild/manifest.json"
} finally {Pop-Location}
