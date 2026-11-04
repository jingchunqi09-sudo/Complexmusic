$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location -LiteralPath $taskRoot
$toolDir='D:\applicationstudy\modelsim\win64'
$buildDir='build/physical_20261025/adc_protocol'
New-Item -ItemType Directory -Force $buildDir | Out-Null
& "$toolDir\vlib.exe" "$buildDir/work"
if($LASTEXITCODE -ne 0) {throw 'vlib failed'}
& "$toolDir\vlog.exe" -quiet -work "$buildDir/work" 'src/ad7091r4_sensor_adapter.v' 'main_piezo_test_20261024/sim/reference_adc_model.v' 'sim/physical_20261025/tb_ad7091r4_physical.v'
if($LASTEXITCODE -ne 0) {throw 'vlog failed'}
for($caseId=0;$caseId -le 6;$caseId++) {
    $logPath="$buildDir/case_$caseId.log"
    & "$toolDir\vsim.exe" -c -lib "$buildDir/work" tb_ad7091r4_physical "-gCASE=$caseId" -do 'run -all; quit -code 0' -l $logPath | Out-Null
    if($LASTEXITCODE -ne 0) {throw "vsim failed CASE=$caseId"}
    $logText=Get-Content -LiteralPath $logPath -Raw
    if($logText -notmatch "PASS AD7091R4 CASE=$caseId " -or $logText -match '\*\* (Fatal|Error):') {throw "ADC protocol regression failed CASE=$caseId; see $logPath"}
    Write-Host "PASS ADC CASE=$caseId"
}
