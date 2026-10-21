# claude-usage-hud — instalador Windows (PowerShell 5.1+)
# Mais fácil: dois cliques em instalar.cmd. Ou:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 [-NoWidget] [-NoAutostart]
#   -NoWidget     instala só a status line (sem o widget flutuante)
#   -NoAutostart  não inicia o widget junto com o Windows
param([switch]$NoWidget, [switch]$NoAutostart)
$ErrorActionPreference = 'Stop'

$Here      = $PSScriptRoot
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$Target    = Join-Path $ClaudeDir 'statusline-usage-hud.js'
$Settings  = Join-Path $ClaudeDir 'settings.json'
$WidgetDir = Join-Path $ClaudeDir 'usage-hud\widget'
$Launcher  = Join-Path $WidgetDir 'ClaudeUsageWidget.exe'
$Programs  = [Environment]::GetFolderPath('Programs')
$Startup   = [Environment]::GetFolderPath('Startup')
$LnkName   = 'Claude Usage Widget.lnk'

function Fail([string]$msg) { Write-Host "ERRO: $msg" -ForegroundColor Red; exit 1 }

if (-not $Here -or -not (Test-Path (Join-Path $Here 'statusline.js'))) { Fail 'rode o install.ps1 de dentro da pasta do claude-usage-hud (statusline.js precisa estar ao lado).' }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'Node.js não encontrado. Instale o Node (https://nodejs.org) e rode de novo.' }
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null

# 1) status line
Copy-Item (Join-Path $Here 'statusline.js') $Target -Force
Unblock-File $Target -ErrorAction SilentlyContinue

# 2) mescla a chave statusLine no settings.json sem mexer no resto (Node: o ConvertTo-Json do PS 5.1 estraga JSON)
$merge = @'
const fs = require("fs");
const [, , settingsPath, target] = process.argv;
let s = {};
if (fs.existsSync(settingsPath)) {
  const raw = fs.readFileSync(settingsPath, "utf8").replace(/^﻿/, "");
  try { s = raw.trim() ? JSON.parse(raw) : {}; }
  catch (e) { console.error("settings.json inválido, corrija antes: " + settingsPath); process.exit(2); }
  fs.copyFileSync(settingsPath, settingsPath + ".bak");
}
const prev = s.statusLine && s.statusLine.command;
if (prev && !String(prev).includes("statusline-usage-hud")) console.log("AVISO: status line anterior substituída (está no settings.json.bak): " + prev);
s.statusLine = { type: "command", command: `node "${target}"`, padding: 0 };
fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + "\n");
'@
$mergeFile = Join-Path $env:TEMP 'claude-usage-hud-merge.js'
Set-Content -Path $mergeFile -Value $merge -Encoding UTF8
& node $mergeFile $Settings ($Target -replace '\\', '/')
$code = $LASTEXITCODE
Remove-Item $mergeFile -Force -ErrorAction SilentlyContinue
if ($code -ne 0) { Fail 'não consegui atualizar o settings.json.' }
Write-Host "OK  status line: $Target"

if ($NoWidget) {
  Write-Host ''
  Write-Host 'Abra uma NOVA sessão do Claude Code. Os limites aparecem após a primeira resposta.'
  exit 0
}

# 3) widget: fecha uma versão antiga que esteja rodando e copia a nova
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*usage-widget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $WidgetDir | Out-Null
Copy-Item (Join-Path $Here 'widget\usage-widget.ps1') $WidgetDir -Force
Unblock-File (Join-Path $WidgetDir 'usage-widget.ps1') -ErrorAction SilentlyContinue

# 4) lançador .exe minúsculo: abre o widget sem piscar janela de console
#    (compilado aqui mesmo com o compilador C# que vem no .NET Framework do Windows)
$launcherSrc = @'
using System.Diagnostics;
using System.IO;
using System.Reflection;
public static class ClaudeUsageWidgetLauncher {
  public static void Main() {
    string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
    string ps = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
    var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + Path.Combine(dir, "usage-widget.ps1") + "\"");
    psi.UseShellExecute = false;
    psi.CreateNoWindow = true;
    psi.WorkingDirectory = dir;
    Process.Start(psi);
  }
}
'@
$haveLauncher = $false
try {
  if (Test-Path $Launcher) { Remove-Item $Launcher -Force }
  Add-Type -TypeDefinition $launcherSrc -OutputAssembly $Launcher -OutputType WindowsApplication
  $haveLauncher = Test-Path $Launcher
} catch {
  Write-Host "AVISO: não deu pra criar o lançador .exe ($($_.Exception.Message)). Usando o PowerShell direto." -ForegroundColor Yellow
}

# 5) atalhos: menu Iniciar (sempre) e Inicializar (autostart, opcional)
function New-WidgetShortcut([string]$path) {
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
  if ($haveLauncher) {
    $lnk.TargetPath = $Launcher
  } else {
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $WidgetDir 'usage-widget.ps1')`""
    $lnk.WindowStyle = 7
  }
  $lnk.WorkingDirectory = $WidgetDir
  $lnk.Description = 'Claude Usage Widget'
  $lnk.Save()
}
New-WidgetShortcut (Join-Path $Programs $LnkName)
if ($NoAutostart) { Remove-Item (Join-Path $Startup $LnkName) -Force -ErrorAction SilentlyContinue }
else { New-WidgetShortcut (Join-Path $Startup $LnkName) }
Write-Host "OK  widget: $WidgetDir"
Write-Host "OK  atalho no menu Iniciar: Claude Usage Widget$(if (-not $NoAutostart) { ' (e inicia junto com o Windows)' })"

# 6) abre o widget
Start-Process (Join-Path $Programs $LnkName)

Write-Host ''
Write-Host 'Pronto! O widget está no canto superior direito da tela (arraste pra onde quiser).' -ForegroundColor Green
Write-Host 'Clique no círculo pra ver todos os limites e os chats ativos.'
Write-Host 'A status line do terminal aparece na próxima sessão do Claude Code.'
