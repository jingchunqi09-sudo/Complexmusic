param([string]$ModelSimBin='C:/modeltech64_10.6d/win64')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskOutput=Join-Path $taskRoot 'build/physical_20261025/regression'
New-Item -ItemType Directory -Force $taskOutput | Out-Null
Push-Location $taskRoot
try {
    $taskPaths=@(Get-ChildItem src -File -Recurse | Where-Object {$_.Extension -in '.v','.vh','.ipc'} | ForEach-Object FullName)
    $taskPaths+=@(Get-ChildItem constraints -File | ForEach-Object FullName)
    $taskPaths+=@(Get-ChildItem sim/physical_20261025 -File -Recurse | ForEach-Object FullName)
    # The ADC runner compiles this independent pin-level model outside sim/.
    $taskPaths+=@(Get-Item -LiteralPath 'main_piezo_test_20261024/sim/reference_adc_model.v' | ForEach-Object FullName)
    # Pin the executed regression scripts. API clients and offline exploratory
    # sound scripts do not participate in this RTL run and have separate logs.
    $taskPaths+=@(Get-ChildItem scripts -Filter 'run_physical*' -File | ForEach-Object FullName)
    $taskBefore=@{}
    foreach($taskPath in $taskPaths){$taskBefore[$taskPath.Substring($taskRoot.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash}
    $taskStart=Get-Date
    if(!(Test-Path -LiteralPath "$taskOutput/work")) {
        & "$ModelSimBin/vlib.exe" "$taskOutput/work"
        if($LASTEXITCODE -ne 0){throw 'ModelSim vlib failed'}
    }
    & "$ModelSimBin/vlog.exe" -quiet -work "$taskOutput/work" '+incdir+src' (Get-ChildItem src -Filter '*.v' -File | ForEach-Object FullName) *> "$taskOutput/compile.log"
    if($LASTEXITCODE -ne 0){throw 'All-source compilation failed'}
    $taskRuns=@(
        'scripts/run_physical_left_sim.ps1',
        'sim/physical_20261025/run_adc_protocol.ps1',
        'scripts/run_physical_control_sim.ps1',
        'scripts/run_physical_pitch_sim.ps1',
        'scripts/run_physical_piezo_sim.ps1',
        'scripts/run_physical_bank_sim.ps1'
    )
    $taskResults=@()
    foreach($taskScript in $taskRuns){
        $taskName=[IO.Path]::GetFileNameWithoutExtension($taskScript)
        $taskLog=Join-Path $taskOutput ($taskName+'.log')
        # ModelSim RPC channel occasionally stays busy right after the previous
        # group exits (observed on this 16GB host): let the process fully exit.
        Start-Sleep -Milliseconds 900
        & powershell -NoProfile -ExecutionPolicy Bypass -File $taskScript *> $taskLog
        if($LASTEXITCODE -ne 0){throw "Failed $taskScript : see $taskLog"}
        $taskResults += [pscustomobject]@{Script=$taskScript;Status='PASS';Log=$taskLog.Substring($taskRoot.Length+1).Replace('\','/');LogSHA256=(Get-FileHash -LiteralPath $taskLog -Algorithm SHA256).Hash}
        Write-Output "PASS $taskScript"
    }
    foreach($taskRel in $taskBefore.Keys){
        if((Get-FileHash -LiteralPath (Join-Path $taskRoot $taskRel) -Algorithm SHA256).Hash -ne $taskBefore[$taskRel]){throw "Input changed during regression: $taskRel"}
    }
    [ordered]@{Status='PASS';StartedAt=$taskStart.ToString('o');FinishedAt=(Get-Date).ToString('o');Sources=$taskBefore;Results=$taskResults;Boundary='RTL behavioral tests; some sensor-publication boundaries forced in integration. No board/analog validation.'} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$taskOutput/manifest.json" -Encoding utf8
} finally {Pop-Location}
