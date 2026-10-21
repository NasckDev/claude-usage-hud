@echo off
rem Instala o claude-usage-hud (status line + widget flutuante). Dois cliques e pronto.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
