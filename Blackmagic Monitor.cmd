@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-bmc-monitor.ps1"
if errorlevel 1 pause
