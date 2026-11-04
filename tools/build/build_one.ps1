# 单个配置的构建脚本（可指定 place 策略），用于 place 对比重跑
# 用法： powershell -File scripts\build_one.ps1 -Name R30p1 -Score 1 -Vol 0 -Tap 0 -Place 1
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][int]$Score,
    [Parameter(Mandatory=$true)][int]$Vol,
    [Parameter(Mandatory=$true)][int]$Tap,
    [int]$Place = 1
)
$ErrorActionPreference = 'Stop'
Set-Location "D:\applicationstudy\Fpga\GOwin\documents\Tang Mega 60K MUSIC"
$gw  = "D:\applicationstudy\Fpga\Gowin_vip\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$top = "src\tang_mega_60k_top.v"

$s = Get-Content $top -Raw -Encoding UTF8
$s = $s -replace 'localparam integer LINK_SCORE_ENABLE\s*=\s*\d+;',  "localparam integer LINK_SCORE_ENABLE  = $Score;"
$s = $s -replace 'localparam integer LINK_VOLUME_ENABLE\s*=\s*\d+;', "localparam integer LINK_VOLUME_ENABLE = $Vol;"
$s = $s -replace 'localparam integer LINK_PCM_TAP\s*=\s*\d+;',       "localparam integer LINK_PCM_TAP       = $Tap;"
[System.IO.File]::WriteAllText((Resolve-Path $top).Path, $s, (New-Object System.Text.UTF8Encoding($false)))

# place 策略写进 PnR 脚本的副本，不动主脚本
$tcl = Get-Content build/r24_bow/pnr_only.tcl -Raw
$tcl = $tcl -replace 'set_option -place_option \d+', "set_option -place_option $Place"
$tclPath = "build/r24_bow/pnr_$Name.tcl"
[System.IO.File]::WriteAllText((Resolve-Path "build\r24_bow").Path + "\pnr_$Name.tcl", $tcl, (New-Object System.Text.UTF8Encoding($false)))

& $gw build/r24_bow/syn_only.tcl *> "build/r24_bow/syn_$Name.log"
$synErr = (Select-String -Path "build/r24_bow/syn_$Name.log" -Pattern "ERROR" | Measure-Object).Count
& $gw "build/r24_bow/pnr_$Name.tcl" *> "build/r24_bow/pnr_$Name.log"
$done = (Select-String -Path "build/r24_bow/pnr_$Name.log" -Pattern "Bitstream generation completed" | Measure-Object).Count
if ($done -ge 1) {
    Copy-Item impl\pnr\tang_mega_60k.fs      "build\r24_bow\$Name.fs"      -Force
    Copy-Item impl\pnr\tang_mega_60k.tr      "build\r24_bow\$Name.tr"      -Force
    Copy-Item impl\pnr\tang_mega_60k.rpt.txt "build\r24_bow\$Name.rpt.txt" -Force
}
$m = Select-String -Path "build/r24_bow\$Name.tr" -Pattern "system_clock_50mhz\s+50\.000\(MHz\)\s+([0-9.]+)" | Select-Object -First 1
"[$Name] score=$Score vol=$Vol tap=$Tap place=$Place synErr=$synErr bitstream=$done clock=$($m.Line.Trim())"
