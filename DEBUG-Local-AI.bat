@echo off
setlocal
title Local AI Debug Bootstrap

echo This debug window stays open.
echo A SECOND PowerShell window should open for Local AI.
echo.

call "%~dp0Local-AI.bat"
set "RC=%ERRORLEVEL%"

echo.
echo Bootstrap returned: %RC%
echo.
echo If the PowerShell window reports an error, send its text or the newest:
echo   %~dp0logs\controller-*.log
echo.
echo Bootstrap log:
echo   %~dp0bootstrap.log
echo.
pause
exit /b %RC%
