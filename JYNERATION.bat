@echo off
rem SPDX-FileCopyrightText: Copyright (c) 2026 saj
rem SPDX-License-Identifier: MIT
setlocal EnableExtensions
title JYNERATION - Ollama Control HUD
cd /d "%~dp0"
if /i "%~1"=="--about" (
    call "%~dp0About.bat"
    exit /b %ERRORLEVEL%
)
if /i "%~1"=="--diagnostics" (
    call "%~dp0Diagnostics.bat"
    exit /b %ERRORLEVEL%
)
if /i "%~1"=="--reset-webui" (
    call "%~dp0Reset-WebUI-Credentials.bat"
    exit /b %ERRORLEVEL%
)
call "%~dp0Start-Local-AI.bat" %*
exit /b %ERRORLEVEL%
