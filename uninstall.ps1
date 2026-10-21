# claude-usage-hud — desinstalador Windows
# Mais fácil: dois cliques em desinstalar.cmd. Ou:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
$ErrorActionPreference = 'Stop'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$Settings  = Join-Path $ClaudeDir 'settings.json'
$LnkName   = 'Claude Usage Widget.lnk'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*usage-widget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($dir in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup')) {
  Remove-Item (Join-Path $dir $LnkName) -Force -ErrorAction SilentlyContinue
}
Remove-Item (Join-Path $ClaudeDir 'statusline-usage-hud.js') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $ClaudeDir 'usage-hud') -Recurse -Force -ErrorAction SilentlyContinue

# tira a statusLine do settings.json só se for a nossa
# (via arquivo: o PS 5.1 come as aspas de argumentos passados pra programas externos)
if ((Test-Path $Settings) -and (Get-Command node -ErrorAction SilentlyContinue)) {
  $js = @'
const fs = require("fs");
const p = process.argv[2];
const s = JSON.parse(fs.readFileSync(p, "utf8").replace(/^﻿/, ""));
if (s.statusLine && String(s.statusLine.command || "").includes("statusline-usage-hud")) {
  delete s.statusLine;
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
}
'@
  $jsFile = Join-Path $env:TEMP 'claude-usage-hud-unmerge.js'
  Set-Content -Path $jsFile -Value $js -Encoding UTF8
  & node $jsFile $Settings
  if ($LASTEXITCODE -ne 0) { Write-Host "AVISO: remova a chave statusLine do $Settings manualmente." -ForegroundColor Yellow }
  Remove-Item $jsFile -Force -ErrorAction SilentlyContinue
}

Write-Host 'claude-usage-hud removido. Abra uma nova sessão do Claude Code.' -ForegroundColor Green
