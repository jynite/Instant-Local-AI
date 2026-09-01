@echo off
setlocal EnableExtensions
title JYNERATION - Ollama Control HUD
cd /d "%~dp0"
set "PS5=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do set "PWSH=%%I"
if not exist "%PWSH%" if exist "%PS5%" for /f "delims=" %%I in ('%PS5% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Find-Pwsh.ps1"') do set "PWSH=%%I"
if not exist "%PWSH%" (
    echo PowerShell 7 is required. Run Setup-Local-AI.bat first.
    pause
    exit /b 10
)
set "PYTHON="
if exist "%PS5%" for /f "delims=" %%I in ('"%PS5%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Find-Python.ps1"') do if not defined PYTHON set "PYTHON=%%I"
if not defined PYTHON for /f "delims=" %%I in ('where python.exe 2^>nul') do if not defined PYTHON set "PYTHON=%%I"
if not defined PYTHON goto :powershell_menu
"%PYTHON%" -c "import PySide6" >nul 2>&1
if errorlevel 1 goto :powershell_menu
for %%I in ("%PYTHON%") do set "PYTHONW=%%~dpIpythonw.exe"
if not exist "%PYTHONW%" goto :python_console
start "" /b "%PYTHONW%" "%~dp0ui\LocalAIController.py"
set "RC=0"
goto :finish

:python_console
"%PYTHON%" "%~dp0ui\LocalAIController.py"
set "RC=%ERRORLEVEL%"
goto :finish

:powershell_menu
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Local-AI.ps1" -Action menu
set "RC=%ERRORLEVEL%"

:finish
if not "%JYNERATION_NONINTERACTIVE%"=="1" if not "%RC%"=="0" pause
exit /b %RC%
