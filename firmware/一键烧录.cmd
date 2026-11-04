@echo off
chcp 65001 >nul
title ESP32 Flash - this project (all required files, auto port)
cd /d "%~dp0"
set PYTHONPATH=
set PYTHONUTF8=1
python "%~dp0tools\flash_tool.py" --all --yes %*
echo.
pause
