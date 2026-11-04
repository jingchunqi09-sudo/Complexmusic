@echo off
chcp 65001 >nul
title ESP32 flash - firmware 3.5.10 (pairs with R54 bitstream)
cd /d "%~dp0"
set PYTHONPATH=
set PYTHONUTF8=1

rem ------------------------------------------------------------------
rem Flashes the RELEASED firmware (firmware_3.5.10.bin under ../releases/R54/),
rem not the .pio build output. No compile step.
rem   - R54 bitstream: ../releases/R54/R54-bitstream.fs  (Gowin Programmer)
rem   - use this when you go back to R54 and do not want the newer build
rem   - use the one-click cmd when you want "compile then flash"
rem Extra args are passed through, e.g.:
rem   shao_lu_R54_3.5.10.cmd --port COM7
rem Keep this file ASCII-only: a .cmd with Chinese text gets garbled by
rem the console codepage. All Chinese messages come from flash_tool.py.
rem ------------------------------------------------------------------

python "%~dp0tools\flash_tool.py" --bin 3.5.10 --yes %*
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" (
  echo [FAILED] exit code %RC%
  echo   common causes: board not plugged / port busy / charge-only USB cable
  echo   check ports with:  python tools\flash_tool.py --list
)
echo.
pause
