@echo off
setlocal EnableExtensions
title Ubuntu Runtime - v12.8

echo Local AI build: v12.8-direct-ubuntu-20260822-0415
echo Opening the installed Ubuntu app directly...
echo.

where ubuntu.exe >nul 2>&1
if not errorlevel 1 (
    start "" ubuntu.exe
    exit /b 0
)

where ubuntu >nul 2>&1
if not errorlevel 1 (
    start "" ubuntu
    exit /b 0
)

echo ubuntu.exe was not found on PATH.
echo Falling back to: wsl.exe -d Ubuntu
start "" wsl.exe -d Ubuntu
exit /b 0
