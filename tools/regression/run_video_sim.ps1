param([string]$ModelSimDirectory='', [string]$PythonExecutable='')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    if($ModelSimDirectory){$env:PATH=$ModelSimDirectory+';'+$env:PATH}
    $library='build/video_regression'
    New-Item -ItemType Directory -Force build,sim/results | Out-Null
    if(!(Test-Path "$library/_info")) { & vlib $library; if($LASTEXITCODE){throw 'vlib failed'} }
    # Vendor encrypted PHY is replaced only for behavioural logic simulation.
    # Gowin implementation uses the genuine src/video_vendor files in the GPRJ.
    [xml]$gprj=Get-Content -Raw -LiteralPath 'tang_mega_60k.gprj'
    $sources=@($gprj.Project.FileList.File | Where-Object {
        $_.enable -eq '1' -and $_.type -eq 'file.verilog' -and $_.path -notlike 'src/video_vendor/*'
    } | ForEach-Object {Join-Path $projectRoot $_.path}) + @(
        'sim/vendor_video_stubs.v','sim/display_observer_tb.v','sim/display_envelope_tb.v','sim/video_timing_tb.v',
        'sim/instrument_dashboard_tb.v','sim/hdmi_audio_independence_tb.v')
    $compile=& vlog -work $library +incdir+src @sources 2>&1
    $compile | Write-Output
    if($LASTEXITCODE -or "$compile" -match 'Errors:\s*[1-9]'){throw 'video compilation failed'}
    foreach($test in @('display_observer_tb','display_envelope_tb','video_timing_tb','instrument_dashboard_tb','hdmi_audio_independence_tb')) {
        $log="sim/results/$test.log"
        & vsim -c -lib $library $test -l $log -do 'run -all; quit -f'
        $code=$LASTEXITCODE
        $result=Get-Content $log -Raw
        if($code -or $result -notmatch "PASS $test" -or $result -match 'FAIL|\*\* Fatal|Errors:\s*[1-9]') {
            throw "video test failed: $test"
        }
    }
    if($PythonExecutable) {
        & $PythonExecutable -c "from PIL import Image; Image.open('sim/results/dashboard.ppm').save('sim/results/dashboard.png')"
        if($LASTEXITCODE){throw 'dashboard PNG export failed'}
    }
    Write-Output 'PASS video suite (behavioural PHY; physical HDMI remains unverified)'
} finally {Pop-Location}
