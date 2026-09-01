@echo off
setlocal EnableExtensions
title JYNERATION - Ollama Control HUD
cd /d "%~dp0"
set "PS5=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PYTHON="
if exist "%PS5%" for /f "delims=" %%I in ('"%PS5%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Find-Python.ps1"') do if not defined PYTHON set "PYTHON=%%I"
if not defined PYTHON for /f "delims=" %%I in ('where python.exe 2^>nul') do if not defined PYTHON set "PYTHON=%%I"
if not defined PYTHON (
    echo Python is required for the QML control center.
    echo Run Local-AI.bat to use the PowerShell control menu instead.
    pause
    exit /b 10
)
"%PYTHON%" -c "import PySide6" >nul 2>&1
if errorlevel 1 (
    echo PySide6 is not installed for this Python interpreter.
    echo Run Local-AI.bat to use the PowerShell control menu instead.
    pause
    exit /b 11
)
for %%I in ("%PYTHON%") do set "PYTHONW=%%~dpIpythonw.exe"
if not exist "%PYTHONW%" (
    echo pythonw.exe is required to launch the HUD without a console window.
    echo Run Local-AI.bat to use the PowerShell control menu instead.
    pause
    exit /b 12
)
start "" /b "%PYTHONW%" "%~dp0ui\LocalAIController.py"
exit /b 0
