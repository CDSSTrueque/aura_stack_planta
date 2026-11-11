@echo off
:: Doble clic: pide permisos de administrador y corre instalar-planta-aura.ps1
:: (ver ese archivo para lo que hace).
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar-planta-aura.ps1"
echo.
pause
