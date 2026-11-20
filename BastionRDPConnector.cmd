@echo off
rem Double-click launcher for BastionRDPConnector.ps1 (no console window stays open).
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0BastionRDPConnector.ps1"
