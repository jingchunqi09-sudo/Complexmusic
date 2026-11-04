param(
    [string]$GowinBin = 'D:\applicationstudy\Fpga\Gowin_vip\Gowin\Gowin_V1.9.12.03_x64\IDE\bin'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gowinShell = Join-Path $GowinBin 'gw_sh.exe'
if (!(Test-Path -LiteralPath $gowinShell)) { throw "Gowin Tcl tool not found: $gowinShell" }
$projectFile = Join-Path $projectRoot 'tang_mega_60k.gprj'
if (!(Test-Path -LiteralPath $projectFile)) { throw "Project not found: $projectFile" }
$bitstreamFile = Join-Path $projectRoot 'impl\pnr\tang_mega_60k.fs'
$timingReport = Join-Path $projectRoot 'impl\pnr\tang_mega_60k.tr'
$implementationReport = Join-Path $projectRoot 'impl\pnr\tang_mega_60k.rpt.txt'
$sourcePaths = @($projectFile, (Join-Path $PSScriptRoot 'gowin_build_60k.tcl'),
    (Join-Path $PSScriptRoot 'gowin_build_60k.ps1'), (Join-Path $PSScriptRoot 'check_gowin_timing.ps1')) + @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'src') -File -Recurse | Where-Object { $_.Extension -in '.v','.vh' } | ForEach-Object { $_.FullName }
) + @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'constraints') -File | ForEach-Object { $_.FullName }
)
$sourceHashes = @($sourcePaths | ForEach-Object {
    [pscustomobject]@{ Path = $_.Substring($projectRoot.Length+1).Replace('\','/'); SHA256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$buildStarted = Get-Date
$audioParameter=[regex]::Match((Get-Content (Join-Path $projectRoot 'src/tang_mega_60k_top.v') -Raw),'parameter\s+integer\s+USE_EXTERNAL_AUDIO_CLOCK\s*=\s*(\d+)')
if(-not $audioParameter.Success){throw 'Cannot identify default audio-clock profile'}
$externalAudioMode=[int]$audioParameter.Groups[1].Value -ne 0
Push-Location $projectRoot
try {
    $tclScript = (Join-Path $PSScriptRoot 'gowin_build_60k.tcl').Replace('\','/')
    & $gowinShell $tclScript
    if ($LASTEXITCODE -ne 0) { throw "Gowin build exited with code $LASTEXITCODE" }
    if (!(Test-Path -LiteralPath $bitstreamFile)) {
        throw "Gowin returned without the PNR bitstream. Check impl/gwsynthesis and impl/pnr logs."
    }
    if ((Get-Item -LiteralPath $bitstreamFile).LastWriteTime -lt $buildStarted) {
        throw "Only an older bitstream exists. Check this build's Gowin logs before programming."
    }
    foreach($reportFile in @($timingReport,$implementationReport)) {
        if(!(Test-Path -LiteralPath $reportFile) -or (Get-Item -LiteralPath $reportFile).LastWriteTime -lt $buildStarted) {
            throw "This build's implementation/timing report is missing or stale: $reportFile"
        }
    }
    foreach ($sourceHash in $sourceHashes) {
        $currentHash = (Get-FileHash -LiteralPath (Join-Path $projectRoot $sourceHash.Path) -Algorithm SHA256).Hash
        if ($currentHash -ne $sourceHash.SHA256) { throw "Source changed during build: $($sourceHash.Path). Rebuild before programming." }
    }
    # Preserve this build's product identity even when constrained timing fails.
    $timingResult = & (Join-Path $PSScriptRoot 'check_gowin_timing.ps1') -TimingReport $timingReport -AllowTimingFailure
    $manifest = [pscustomobject]@{
        BuiltAt = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
        Device = 'GW5AT-LV60PG484AC1/I0'
        AudioClock = $(if($externalAudioMode){'external_bck_mailbox'}else{'internal_50mhz_divider'})
        SampleRateHz = $(if($externalAudioMode){48000}else{48828.125})
        BitstreamPath = 'impl/pnr/tang_mega_60k.fs'
        BitstreamSHA256 = (Get-FileHash -LiteralPath $bitstreamFile -Algorithm SHA256).Hash
        TimingReportSHA256 = (Get-FileHash -LiteralPath $timingReport -Algorithm SHA256).Hash
        ImplementationReportPath = 'impl/pnr/tang_mega_60k.rpt.txt'
        ImplementationReportSHA256 = (Get-FileHash -LiteralPath $implementationReport -Algorithm SHA256).Hash
        TimingStatus = $timingResult.Status
        TimingGatePassed = $timingResult.Passed
        Qualification = 'NOT_RELEASE_QUALIFIED_UNTIL_SAME_SOURCE_REGRESSION'
        Timing = $timingResult
        Sources = $sourceHashes
    }
    $resultsDirectory = Join-Path $projectRoot 'build\results'
    New-Item -ItemType Directory -Force $resultsDirectory | Out-Null
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultsDirectory 'gowin_60k_build_manifest.json') -Encoding utf8
    Write-Output "Bitstream: $bitstreamFile"
    Write-Output "Timing reports: $(Join-Path $projectRoot 'impl\pnr')"
    if(-not $timingResult.Passed) {
        throw "This build is NOT_RELEASE_QUALIFIED: $($timingResult.Failures -join '; '). Current FS and STA hashes were saved to the build manifest."
    }
    Write-Output 'Constrained setup/hold/recovery/removal/pulse-width timing passed. Physical sensors and analog output still require board measurements.'
} finally {
    Pop-Location
}
