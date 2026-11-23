@echo off
rem Double-click launcher for BE-ternaBastionConnector.ps1 (no console window stays open).
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0BE-ternaBastionConnector.ps1"
