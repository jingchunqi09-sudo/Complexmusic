param([string]$ModelSimBin='C:/modeltech64_10.6d/win64')
# R17：右手压电判据换成 piezo_string_det（rh6 移植版）。
#
# 旧版 tb_piezo_v3 用 6.2 kHz 的 ms_stim.hex，而生产 ADC 实际是 24.9 kSPS/通道
# （GAP 1060 + SPI 800 + 转换 133 ≈ 2000 clk @50 MHz）。旧回因此在"时间常数短 4 倍"
# 的情况下全绿，实板却会误响 —— 这条回归按 24900 Hz 自己生成激励，验证三件事：
#   1) 单弦拨弦输出音符事件（不能被空间判据吃掉）
#   2) 四路同相等幅的拍琴身被空间判据拒绝（不发声）
#   3) 被拒的琴体事件抬升 vibrato_depth（拍琴身 -> 颤音）
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskBuild='build/physical_20261025/piezo_r17'
Push-Location $taskRoot
try{
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    if(!(Test-Path -LiteralPath "$taskBuild/work")){& "$ModelSimBin/vlib.exe" "$taskBuild/work"}
    $taskPaths=@(
        'src/piezo_band_ch.v',
        'src/piezo_string_det.v',
        'sim/tb_piezo_r17.v'
    )
    & "$ModelSimBin/vlog.exe" -work "$taskBuild/work" -incr @taskPaths
    if($LASTEXITCODE -ne 0){throw 'Piezo R17 compile failed'}
    $taskLogName='tb_piezo_r17.log'
    Push-Location $taskBuild
    try{
        & "$ModelSimBin/vsim.exe" -c -lib work tb_piezo_r17 -l $taskLogName -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
        $taskExit=$LASTEXITCODE
    } finally {Pop-Location}
    $taskLog=Join-Path $taskBuild $taskLogName
    $taskText=Get-Content -Raw -LiteralPath $taskLog
    if($taskExit -ne 0){throw "Piezo R17 simulation failed (exit $taskExit)"}
    if($taskText -notmatch 'PASS piezo r17'){throw 'Piezo R17 lacks PASS'}
    if($taskText -match '\*\* (Fatal|Error)'){throw 'Piezo R17 log contains fatal/error'}
    Select-String -Path $taskLog -Pattern 'EVENT|RESULT|VIB|PASS piezo r17' | ForEach-Object {$_.Line}
} finally {Pop-Location}
