# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
$ErrorActionPreference = "Stop"
$setup = Join-Path $PSScriptRoot "Setup-Local-AI.ps1"
Write-Host "JYNERATION // Runtime Repair"
& $setup -Repair
