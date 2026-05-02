@echo off
setlocal

set "ARGS="
if /I "%~1"=="/quiet" set "ARGS=-Quiet -NoLaunch"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Phantty.ps1" %ARGS%
exit /b %ERRORLEVEL%
