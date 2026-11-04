@echo off
chcp 65001 >nul
title ESP32 flash - firmware 3.5.13 (encoder x10, pairs with R54 bitstream)
cd /d "%~dp0"
set PYTHONPATH=
set PYTHONUTF8=1

rem ------------------------------------------------------------------
rem 3.5.13 = encoder sensitivity x10 (volume / tone / reverb wet only;
rem          tuning pitch stays at 1 semitone per detent).
rem Bitstream is NOT rebuilt: this is an ESP32-only change, so it still
rem pairs with the R54 .fs already on the board.
rem Flashes the released bin (firmware_3.5.13.bin in the R54 folder),
rem not the .pio build output. No compile step.
rem Extra args are passed through, e.g.:
rem   shao_lu_R54_3.5.13.cmd --port COM7
rem Keep this file ASCII-only: a .cmd with Chinese text gets garbled by
rem the console codepage. All Chinese messages come from flash_tool.py.
rem ------------------------------------------------------------------

python "%~dp0tools\flash_tool.py" --bin 3.5.13 --yes %*
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" (
  echo [FAILED] exit code %RC%
  echo   common causes: board not plugged / port busy / charge-only USB cable
  echo   check ports with:  python tools\flash_tool.py --list
)
echo.
pause
