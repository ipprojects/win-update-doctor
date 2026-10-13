@echo off
:: Launcher for Windows Update Doctor with Auto-Elevation to Administrator
title Windows Update Doctor Launcher
echo Memeriksa hak akses Administrator...

net session >nul 2>&1
if %errorlevel% == 0 (
    goto :runScript
) else (
    echo Meminta elevasi hak akses Administrator (UAC)...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:runScript
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinUpdateDoctor.ps1" -Action All
pause
