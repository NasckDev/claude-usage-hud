# claude-usage-hud — widget flutuante para Windows (PowerShell + WPF, sem dependências)
# Mostra o uso da sessão de 5h (anel externo), da semana (anel interno), todos os limites
# (inclusive por modelo, ex.: Fable) e os chats do Claude Code abertos agora.
#
# De onde vêm os dados:
#  - Limites: a cada 60s, o mesmo endpoint de uso que o app do Claude consulta
#    (https://api.anthropic.com/api/oauth/usage). O token de login é LIDO de
#    ~/.claude/.credentials.json a cada consulta (o Claude Code é quem renova); nunca é gravado
#    nem enviado pra outro lugar. Endpoint não documentado: se falhar, cai pro state.json.
#  - Fallback dos limites e % de contexto por chat: ~/.claude/usage-hud/state.json (status line).
#  - Chats ativos: ~/.claude/sessions/*.json (gravado pelo próprio Claude Code).
#
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File usage-widget.ps1
# Clique no círculo: detalhes · arraste: move · botão direito: menu · ícone na bandeja: mostrar/ocultar/sair

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ClaudeDir   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$HudDir      = Join-Path $ClaudeDir 'usage-hud'
$StateFile   = Join-Path $HudDir 'state.json'
$PrefsFile   = Join-Path $HudDir 'widget.json'
$LogFile     = Join-Path $HudDir 'widget.log'
$SessionsDir = Join-Path $ClaudeDir 'sessions'
$CredsFile   = Join-Path $ClaudeDir '.credentials.json'
$UsageUrl    = 'https://api.anthropic.com/api/oauth/usage'
$ApiEveryMs  = 60 * 1000        # consulta o uso da conta a cada 60s
$ApiFreshMs  = 10 * 60 * 1000   # dado da conta vale por 10 min; depois disso usa a status line
$StartupLnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$Launcher    = Join-Path $PSScriptRoot 'ClaudeUsageWidget.exe'
$StaleMs     = 15 * 60 * 1000   # sem atualização há 15 min = dados desatualizados
$SessionTtl  = 10 * 60 * 1000   # fallback sem ~/.claude/sessions: sessão vista há até 10 min
$Culture     = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$PanelWidth  = 300

# uma instância só: se já tem um widget rodando, pede pra ele aparecer e sai
$ShowSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ClaudeUsageHudWidget.Show')
$createdNew = $false
$Mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageHudWidget', [ref]$createdNew)
if (-not $createdNew) { [void]$ShowSignal.Set(); exit 0 }

Add-Type -Namespace UsageHud -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
// grava no log qualquer exceção que derrube o processo (handler em C#: roda mesmo sem runspace livre)
public static void LogFatal(string path) {
  System.AppDomain.CurrentDomain.UnhandledException += (s, e) => {
    try { System.IO.File.AppendAllText(path, System.DateTime.Now.ToString("s") + " FATAL " + e.ExceptionObject + System.Environment.NewLine); } catch {}
  };
}
'@

New-Item -ItemType Directory -Force -Path $HudDir | Out-Null
[UsageHud.Native]::LogFatal($LogFile)

# estado mutável compartilhado pelos handlers (evita problemas de escopo de scriptblock)
$S = @{
  State = $null; StateMtime = [datetime]::MinValue
  Chats = @(); Tick = 0; Expanded = $false; TopShift = 0
  Theme = ''; T = @{}; Hex = @{}
  Tray = $null; IconHandle = [IntPtr]::Zero; IconKey = ''
  LastError = ''; Exiting = $false; HintShown = $false
  Api = $null; ApiAt = 0; ApiTask = $null; ApiNextAt = 0; ApiError = ''
}
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(20)

# ---------- utilidades ----------
function Write-Log([string]$msg) {
  if ($msg -eq $S.LastError) { return }   # não repete o mesmo erro a cada segundo
  $S.LastError = $msg
  try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 256KB) { Remove-Item $LogFile -Force }
    Add-Content -Path $LogFile -Value ('{0:s} {1}' -f (Get-Date), $msg) -Encoding UTF8
  } catch {}
}

# todo handler de evento passa por aqui: um erro vira linha no log, não derruba o widget
function Invoke-Safe([scriptblock]$Action) {
  try { & $Action } catch { Write-Log "handler: $($_.Exception.Message)" }
}

function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Format-Countdown([double]$ms) {
  if ($ms -le 0) { return 'resetou' }
  $t = [TimeSpan]::FromMilliseconds($ms)
  if ($t.Days -gt 0) { return '{0}d{1}h' -f $t.Days, $t.Hours }
  if ($t.Hours -gt 0) { return '{0}h{1:00}m' -f $t.Hours, $t.Minutes }
  if ($t.Minutes -gt 0) { return '{0}m' -f $t.Minutes }
  return '<1m'
}

function Format-ResetAt([double]$ms) {
  $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).LocalDateTime
  $today = (Get-Date).Date
  if ($dt.Date -eq $today) { return 'hoje ' + $dt.ToString('HH:mm') }
  if ($dt.Date -eq $today.AddDays(1)) { return 'amanhã ' + $dt.ToString('HH:mm') }
  return $dt.ToString('ddd dd/MM HH:mm', $Culture)
}

function Format-Ago([double]$ms) {
  $sec = [math]::Max(0, ((Get-NowMs) - $ms) / 1000)
  if ($sec -lt 60) { return 'agora' }
  if ($sec -lt 3600) { return 'há {0} min' -f [math]::Floor($sec / 60) }
  if ($sec -lt 86400) { return 'há {0} h' -f [math]::Floor($sec / 3600) }
  return 'há {0} d' -f [math]::Floor($sec / 86400)
}

function Read-JsonFile([string]$path) {
  # FileShare Delete: deixa a status line renomear o arquivo por cima enquanto a gente lê
  $fs = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
  try { $txt = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
  if ($txt.Trim()) { return $txt | ConvertFrom-Json }
  return $null
}

# ---------- tema (segue o modo claro/escuro do Windows) ----------
$Palettes = @{
  dark  = @{ surface = '#F21E1E1C'; text = '#F3F1EC'; muted = '#A19E97'; track = '#3A3935'; line = '#33322F'; ok = '#4CC38A'; warn = '#E5B53A'; bad = '#F2675C'; accent = '#D97757' }
  light = @{ surface = '#F7FFFFFF'; text = '#1F1E1C'; muted = '#6E6B65'; track = '#E7E4DE'; line = '#ECE9E4'; ok = '#1E8E58'; warn = '#B7791F'; bad = '#D1453B'; accent = '#C9623F' }
}

function Get-SystemTheme {
  try {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme
    if ($v -eq 1) { return 'light' }
  } catch {}
  return 'dark'
}

function New-Brush([string]$hex) {
  $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
  $b.Freeze()
  return $b
}

function Get-LevelKey($pct) {
  if ($null -eq $pct) { return 'muted' }
  if ($pct -ge 85) { return 'bad' }
  if ($pct -ge 60) { return 'warn' }
  return 'ok'
}

# ---------- dados ----------
function Update-State {
  if (-not (Test-Path $StateFile)) { $S.State = $null; return }
  $mtime = (Get-Item $StateFile).LastWriteTimeUtc
  if ($mtime -eq $S.StateMtime) { return }
  try {
    $S.State = Read-JsonFile $StateFile
    $S.StateMtime = $mtime
  } catch { Write-Log "state.json: $($_.Exception.Message)" }   # mantém o último estado bom
}

# ---------- uso da conta (mesma fonte do app) ----------
function Get-AccessToken {
  if (-not (Test-Path $CredsFile)) { return $null }
  $o = (Read-JsonFile $CredsFile).claudeAiOauth
  if (-not $o -or -not $o.accessToken) { return $null }
  if ($o.expiresAt -and [double]$o.expiresAt -le (Get-NowMs)) { return '' }   # expirado: o Claude Code renova ao abrir
  return [string]$o.accessToken
}

function Start-ApiFetch {
  $S.ApiNextAt = (Get-NowMs) + $ApiEveryMs
  $tok = $null
  try { $tok = Get-AccessToken } catch { Write-Log "credentials: $($_.Exception.Message)" }
  if ($null -eq $tok) { $S.ApiError = 'sem login do Claude Code nesta máquina'; return }
  if ($tok -eq '') { $S.ApiError = 'login expirado: abra o Claude Code pra renovar'; return }
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $UsageUrl)
  $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $tok)
  [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
  [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'claude-usage-hud')
  $S.ApiTask = $Http.SendAsync($req)
}

# chamado a cada tick: processa a resposta quando ela chegar, sem travar a interface
function Complete-ApiFetch {
  $task = $S.ApiTask
  if (-not $task -or -not $task.IsCompleted) { return }
  $S.ApiTask = $null
  if ($task.IsFaulted -or $task.IsCanceled) {
    $S.ApiError = 'sem conexão com a Anthropic'
    if ($task.Exception) { Write-Log "usage api: $($task.Exception.GetBaseException().Message)" }
    return
  }
  $resp = $task.Result
  $code = [int]$resp.StatusCode
  if ($code -eq 200) {
    $S.Api = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    $S.ApiAt = Get-NowMs
    $S.ApiError = ''
  } elseif ($code -eq 401) {
    $S.ApiError = 'login expirado: abra o Claude Code pra renovar'
  } elseif ($code -eq 429) {
    $S.ApiError = 'muitas consultas; tentando de novo em 5 min'
    $S.ApiNextAt = (Get-NowMs) + 5 * 60 * 1000
  } else {
    $S.ApiError = "a Anthropic respondeu HTTP $code"
  }
  $resp.Dispose()
}

# ---------- limites normalizados: @{ Key; Label; Pct; ResetsMs; Details } ----------
function ConvertTo-Ms($v) {
  if ($null -eq $v -or $v -eq '') { return $null }
  if ($v -is [datetime]) { return [double]([DateTimeOffset]$v).ToUnixTimeMilliseconds() }
  if ($v -is [string]) { return [double][DateTimeOffset]::Parse($v, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() }
  $n = [double]$v
  if ($n -lt 1e12) { return $n * 1000 }
  return $n
}

function New-Limit([string]$key, [string]$label, $pct, $resetsMs, $details = @()) {
  # depois do resets_at a janela zerou, mesmo que ninguém tenha atualizado ainda
  if ($null -ne $pct -and $resetsMs -and $resetsMs -le (Get-NowMs)) { $pct = 0 }
  [pscustomobject]@{ Key = $key; Label = $label; Pct = $(if ($null -ne $pct) { [double]$pct } else { $null }); ResetsMs = $resetsMs; Details = @($details) }
}

function Get-ScopeName($scope) {
  if (-not $scope) { return $null }
  foreach ($k in 'model', 'surface') {
    $v = $scope.$k
    if ($v -is [string] -and $v) { return $v }
    if ($v -and $v.display_name) { return [string]$v.display_name }
  }
  return $null
}

function Get-ApiLimits($api) {
  $out = @()
  if ($api.limits) {
    foreach ($l in $api.limits) {
      $scope = Get-ScopeName $l.scope
      switch ([string]$l.kind) {
        'session'    { $key = 'session';    $label = 'Sessão atual (5h)' }
        'weekly_all' { $key = 'weekly_all'; $label = 'Semana · todos os modelos' }
        default {
          $key = '{0}:{1}' -f $l.kind, $scope
          $label = if ($scope -and $l.group -eq 'weekly') { "Semana · $scope" } elseif ($scope) { "$($l.kind -replace '_', ' ') · $scope" } else { $l.kind -replace '_', ' ' }
        }
      }
      $out += New-Limit $key $label $l.percent (ConvertTo-Ms $l.resets_at)
    }
  } else {
    # formato antigo, sem a lista "limits"
    if ($api.five_hour) { $out += New-Limit 'session' 'Sessão atual (5h)' $api.five_hour.utilization (ConvertTo-Ms $api.five_hour.resets_at) }
    if ($api.seven_day) { $out += New-Limit 'weekly_all' 'Semana · todos os modelos' $api.seven_day.utilization (ConvertTo-Ms $api.seven_day.resets_at) }
  }
  if ($api.spend -and $api.spend.enabled -and $null -ne $api.spend.percent) {
    $d = @()
    $u = $api.spend.used
    if ($u -and $null -ne $u.amount_minor) { $d += ('{0} {1:N2} usados' -f $u.currency, ([double]$u.amount_minor / [math]::Pow(10, [double]$u.exponent))) }
    $out += New-Limit 'spend' 'Créditos extras' $api.spend.percent $null $d
  }
  return $out
}

$LimitLabels = @{ five_hour = 'Sessão atual (5h)'; seven_day = 'Semana · todos os modelos'; spend_limit = 'Limite de gasto' }
$LimitKeys = @{ five_hour = 'session'; seven_day = 'weekly_all' }
$PeriodLabels = @{ daily = 'diário'; weekly = 'semanal'; monthly = 'mensal' }

function Get-StatusLineLimits {
  $out = @()
  $rl = if ($S.State) { $S.State.rate_limits } else { $null }
  if (-not $rl) { return $out }
  $names = @($rl.PSObject.Properties | ForEach-Object { $_.Name })
  $ordered = @('five_hour', 'seven_day' | Where-Object { $names -contains $_ }) + @($names | Where-Object { $_ -notin 'five_hour', 'seven_day' })
  foreach ($k in $ordered) {
    $lim = $rl.$k
    $d = @()
    if ($null -ne $lim.used_usd -and $null -ne $lim.limit_usd) { $d += ('US$ {0:N2} de US$ {1:N2}' -f [double]$lim.used_usd, [double]$lim.limit_usd) }
    if ($lim.period -and $PeriodLabels.ContainsKey([string]$lim.period)) { $d += $PeriodLabels[[string]$lim.period] }
    $key = if ($LimitKeys.ContainsKey($k)) { $LimitKeys[$k] } else { $k }
    $label = if ($LimitLabels.ContainsKey($k)) { $LimitLabels[$k] } else { $k -replace '_', ' ' }
    $out += New-Limit $key $label $lim.used_percentage (ConvertTo-Ms $lim.resets_at_ms) $d
  }
  return $out
}

# fonte preferida: conta (se recente); senão, status line
function Get-Limits {
  $now = Get-NowMs
  if ($S.Api -and ($now - $S.ApiAt) -lt $ApiFreshMs) {
    return @{ Items = @(Get-ApiLimits $S.Api); Source = 'conta Claude'; At = $S.ApiAt }
  }
  $items = @(Get-StatusLineLimits)
  if ($items.Count -gt 0) { return @{ Items = $items; Source = 'status line'; At = [double]$S.State.updated_at } }
  return @{ Items = @(); Source = $null; At = 0 }
}

function Test-ProcessAlive($procId, $procStart) {
  try { $p = [Diagnostics.Process]::GetProcessById([int]$procId) } catch { return $false }
  # procStart é o FILETIME de início do processo: evita confundir com PID reaproveitado
  if ($procStart) {
    try { if ([math]::Abs($p.StartTime.ToFileTimeUtc() - [int64]$procStart) -gt 20000000) { return $false } } catch {}
  }
  return $true
}

function Update-Chats {
  $known = @{}
  if ($S.State -and $S.State.sessions) {
    foreach ($p in $S.State.sessions.PSObject.Properties) { $known[$p.Name] = $p.Value }
  }
  $chats = New-Object System.Collections.ArrayList

  if (Test-Path $SessionsDir) {
    foreach ($f in Get-ChildItem -Path $SessionsDir -Filter '*.json' -File) {
      try {
        $j = Read-JsonFile $f.FullName
        if (-not $j -or -not $j.pid) { continue }
        if (-not (Test-ProcessAlive $j.pid $j.procStart)) { continue }
        $info = $known[[string]$j.sessionId]
        $name = if ($info -and $info.name) { $info.name } elseif ($j.name) { $j.name } else { Split-Path $j.cwd -Leaf }
        [void]$chats.Add([pscustomobject]@{
          Name    = $name
          Project = if ($j.cwd) { Split-Path $j.cwd -Leaf } else { '' }
          Model   = if ($info) { $info.model } else { $null }
          Ctx     = if ($info) { $info.context_used_pct } else { $null }
          Status  = $j.status
          Entry   = $j.entrypoint
          Updated = if ($j.updatedAt) { [double]$j.updatedAt } else { 0 }
        })
      } catch { Write-Log "sessions/$($f.Name): $($_.Exception.Message)" }
    }
  } else {
    # versões do Claude Code sem ~/.claude/sessions: usa o que a status line registrou
    $now = Get-NowMs
    foreach ($sess in $known.Values) {
      if ($now - [double]$sess.last_seen -gt $SessionTtl) { continue }
      [void]$chats.Add([pscustomobject]@{
        Name = if ($sess.name) { $sess.name } else { $sess.project }; Project = $sess.project; Model = $sess.model
        Ctx = $sess.context_used_pct; Status = $null; Entry = $null; Updated = [double]$sess.last_seen
      })
    }
  }
  $S.Chats = @($chats | Sort-Object @{ Expression = { $_.Status -eq 'busy' }; Descending = $true }, @{ Expression = 'Updated'; Descending = $true })
}

# ---------- janela ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <StackPanel Margin="12">
    <Grid x:Name="Dial" Width="156" Height="156" HorizontalAlignment="Center" Cursor="Hand" Background="Transparent"
          ToolTip="Clique: detalhes · Arraste: mover · Botão direito: menu">
      <Ellipse x:Name="DialBg">
        <Ellipse.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35"/></Ellipse.Effect>
      </Ellipse>
      <Canvas Width="156" Height="156">
        <Ellipse x:Name="Track5" Canvas.Left="12" Canvas.Top="12" Width="132" Height="132" StrokeThickness="10"/>
        <Path x:Name="Arc5" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <Ellipse x:Name="Track7" Canvas.Left="26" Canvas.Top="26" Width="104" Height="104" StrokeThickness="4"/>
        <Path x:Name="Arc7" StrokeThickness="4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
      </Canvas>
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock x:Name="Pct5" FontSize="30" FontWeight="SemiBold" HorizontalAlignment="Center" Typography.NumeralAlignment="Tabular"/>
        <TextBlock x:Name="Reset5" FontSize="11" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
        <TextBlock x:Name="Sub" FontSize="10" HorizontalAlignment="Center" Margin="0,3,0,0"/>
      </StackPanel>
      <StackPanel x:Name="Controls" HorizontalAlignment="Right" VerticalAlignment="Top" Visibility="Hidden">
        <Border x:Name="BtnClose" Width="22" Height="22" CornerRadius="11" BorderThickness="1" Cursor="Hand"
                ToolTip="Fechar o widget (abra de novo pelo menu Iniciar)">
          <TextBlock x:Name="BtnCloseText" Text="✕" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <Border x:Name="BtnMin" Width="22" Height="22" CornerRadius="11" BorderThickness="1" Cursor="Hand" Margin="0,4,0,0"
                ToolTip="Minimizar para a bandeja (clique no ícone perto do relógio pra voltar)">
          <TextBlock x:Name="BtnMinText" Text="–" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
        </Border>
      </StackPanel>
    </Grid>
    <Border x:Name="Panel" Width="300" Margin="0,10,0,0" CornerRadius="12" Padding="14,12,14,12" Visibility="Collapsed">
      <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.3"/></Border.Effect>
      <StackPanel x:Name="PanelBody"/>
    </Border>
  </StackPanel>
</Window>
'@
$Win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Dial', 'DialBg', 'Track5', 'Arc5', 'Track7', 'Arc7', 'Pct5', 'Reset5', 'Sub', 'Panel', 'PanelBody',
               'Controls', 'BtnClose', 'BtnCloseText', 'BtnMin', 'BtnMinText') {
  Set-Variable -Name $n -Value $Win.FindName($n)
}

function Set-Theme {
  $name = Get-SystemTheme
  if ($name -eq $S.Theme) { return }
  $S.Theme = $name
  $S.Hex = $Palettes[$name]
  $S.T = @{}
  foreach ($k in $S.Hex.Keys) { $S.T[$k] = New-Brush $S.Hex[$k] }
  $DialBg.Fill = $S.T.surface
  $Panel.Background = $S.T.surface
  $Track5.Stroke = $S.T.track
  $Track7.Stroke = $S.T.track
  $Pct5.Foreground = $S.T.text
  $Reset5.Foreground = $S.T.muted
  foreach ($b in $BtnClose, $BtnMin) { $b.Background = $S.T.surface; $b.BorderBrush = $S.T.track }
  foreach ($t in $BtnCloseText, $BtnMinText) { $t.Foreground = $S.T.text }
  $S.IconKey = ''   # força redesenhar o ícone da bandeja
}

function Set-Arc($path, $pct, [double]$r) {
  $c = 78.0   # centro do Canvas 156x156
  if ($null -eq $pct -or $pct -le 0) { $path.Data = $null; return }
  $p = [math]::Min(100.0, [double]$pct)
  if ($p -ge 99.95) {
    $path.Data = New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point($c, $c)), $r, $r)
    return
  }
  $a = $p / 100 * 2 * [math]::PI
  $fig = New-Object Windows.Media.PathFigure
  $fig.StartPoint = New-Object Windows.Point($c, ($c - $r))
  $end = New-Object Windows.Point(($c + $r * [math]::Sin($a)), ($c - $r * [math]::Cos($a)))
  [void]$fig.Segments.Add((New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0, ($p -gt 50), ([Windows.Media.SweepDirection]::Clockwise), $true)))
  $g = New-Object Windows.Media.PathGeometry
  [void]$g.Figures.Add($fig)
  $path.Data = $g
}

function Update-TrayIcon($pct, [string]$levelKey, [string]$tooltip) {
  if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 62) + '…' }   # limite do NotifyIcon
  $S.Tray.Text = $tooltip
  $key = '{0}|{1}|{2}' -f [math]::Round([double]$pct), $levelKey, $S.Theme
  if ($key -eq $S.IconKey) { return }
  $S.IconKey = $key
  $bmp = New-Object Drawing.Bitmap 32, 32
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $track = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(120, 128, 128, 128)), 5
  $g.DrawEllipse($track, 4, 4, 24, 24)
  if ($pct -gt 0) {
    $hex = if ($levelKey -eq 'muted') { $S.Hex.accent } else { $S.Hex[$levelKey] }
    $pen = New-Object Drawing.Pen ([Drawing.ColorTranslator]::FromHtml($hex)), 5
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, 4, 4, 24, 24, -90, [float]([math]::Min(100, $pct) * 3.6))
    $pen.Dispose()
  }
  $track.Dispose(); $g.Dispose()
  $h = $bmp.GetHicon()
  $bmp.Dispose()
  $old = $S.IconHandle
  $S.Tray.Icon = [Drawing.Icon]::FromHandle($h)
  $S.IconHandle = $h
  if ($old -ne [IntPtr]::Zero) { [void][UsageHud.Native]::DestroyIcon($old) }
}

function Update-Dial {
  $now = Get-NowMs
  $lims = Get-Limits
  $five = $lims.Items | Where-Object { $_.Key -eq 'session' } | Select-Object -First 1
  $week = $lims.Items | Where-Object { $_.Key -eq 'weekly_all' } | Select-Object -First 1
  $p5 = if ($five) { $five.Pct } else { $null }
  $p7 = if ($week) { $week.Pct } else { $null }
  $stale = (-not $lims.Source) -or ($now - $lims.At -gt $StaleMs)
  $k5 = Get-LevelKey $p5
  $k7 = Get-LevelKey $p7

  $Arc5.Stroke = $S.T[$k5]
  $Arc7.Stroke = $S.T[$k7]
  $Arc5.Opacity = if ($stale) { 0.55 } else { 1 }
  $Arc7.Opacity = $Arc5.Opacity
  Set-Arc $Arc5 $p5 61
  Set-Arc $Arc7 $p7 50

  if ($null -ne $p5) {
    $Pct5.Text = '{0}%' -f [math]::Round($p5)
    $Reset5.Text = if ($five.ResetsMs) { 'reseta ' + (Format-Countdown ($five.ResetsMs - $now)) } else { '' }
  } else {
    $Pct5.Text = '--'
    $Reset5.Text = 'sem dados'
  }
  if ($null -ne $p7) {
    $Sub.Text = 'semana {0}%' -f [math]::Round($p7)
    $Sub.Foreground = $S.T[$k7]
  } else {
    $Sub.Text = 'clique p/ detalhes'
    $Sub.Foreground = $S.T.muted
  }

  $tip = if ($null -ne $p5) { 'Claude 5h: {0}% · reseta {1}' -f [math]::Round($p5), (Format-Countdown ($five.ResetsMs - $now)) } else { 'Claude: sem dados de uso ainda' }
  if ($null -ne $p7) { $tip += ' · 7d {0}%' -f [math]::Round($p7) }
  Update-TrayIcon $p5 $k5 $tip
}

# ---------- painel de detalhes ----------
function New-Text([string]$text, [double]$size = 12, $brush = $S.T.text, [string]$weight = 'Normal') {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text; $t.FontSize = $size; $t.Foreground = $brush; $t.FontWeight = $weight
  $t.TextTrimming = 'CharacterEllipsis'
  return $t
}

function New-Row($left, $right) {
  $d = New-Object Windows.Controls.DockPanel
  $d.LastChildFill = $true
  [Windows.Controls.DockPanel]::SetDock($right, 'Right')
  $right.Margin = '8,0,0,0'
  [void]$d.Children.Add($right)
  [void]$d.Children.Add($left)
  return $d
}

function New-Header([string]$text) {
  $h = New-Text $text.ToUpper($Culture) 10 $S.T.muted 'SemiBold'
  $h.Margin = '0,0,0,6'
  return $h
}

function New-Divider {
  $b = New-Object Windows.Controls.Border
  $b.Height = 1; $b.Background = $S.T.line; $b.Margin = '0,10,0,10'
  return $b
}

$StatusLabels = @{ busy = 'trabalhando'; idle = 'ocioso' }
$EntryLabels = @{ 'claude-vscode' = 'VS Code' }

function Add-Limit($body, $lim) {
  $now = Get-NowMs
  $pct = $lim.Pct
  $level = Get-LevelKey $pct
  $pctTxt = if ($null -ne $pct) { '{0}%' -f [math]::Round($pct) } else { '--' }
  [void]$body.Children.Add((New-Row (New-Text $lim.Label 12.5) (New-Text $pctTxt 12.5 $S.T[$level] 'SemiBold')))

  $bar = New-Object Windows.Controls.Grid
  $bar.Margin = '0,5,0,4'
  $track = New-Object Windows.Controls.Border
  $track.Height = 6; $track.CornerRadius = 3; $track.Background = $S.T.track
  $fill = New-Object Windows.Controls.Border
  $fill.Height = 6; $fill.CornerRadius = 3; $fill.Background = $S.T[$level]; $fill.HorizontalAlignment = 'Left'
  $fill.Width = [math]::Max(0, [math]::Min(100, [double]$pct)) / 100 * ($PanelWidth - 28)
  [void]$bar.Children.Add($track); [void]$bar.Children.Add($fill)
  [void]$body.Children.Add($bar)

  $details = @()
  if ($lim.ResetsMs) {
    $left = $lim.ResetsMs - $now
    $details += if ($left -gt 0) { 'reseta em {0} · {1}' -f (Format-Countdown $left), (Format-ResetAt $lim.ResetsMs) } else { 'janela resetou' }
  }
  $details += $lim.Details
  if ($details) {
    $d = New-Text ($details -join ' · ') 11 $S.T.muted
    $d.Margin = '0,0,0,10'
    [void]$body.Children.Add($d)
  }
}

function Add-Chat($body, $c) {
  $wrap = New-Object Windows.Controls.StackPanel
  $wrap.Margin = '0,0,0,8'
  $dot = New-Object Windows.Shapes.Ellipse
  $dot.Width = 8; $dot.Height = 8; $dot.Margin = '0,0,8,0'; $dot.VerticalAlignment = 'Center'
  $dot.Fill = if ($c.Status -eq 'busy') { $S.T.accent } else { $S.T.track }
  $nameLine = New-Object Windows.Controls.DockPanel
  [void]$nameLine.Children.Add($dot)
  [void]$nameLine.Children.Add((New-Text $c.Name 12.5 $S.T.text 'SemiBold'))
  $status = if ($c.Status -and $StatusLabels.ContainsKey([string]$c.Status)) { $StatusLabels[[string]$c.Status] } elseif ($c.Status) { [string]$c.Status } else { Format-Ago $c.Updated }
  [void]$wrap.Children.Add((New-Row $nameLine (New-Text $status 11 $(if ($c.Status -eq 'busy') { $S.T.accent } else { $S.T.muted }))))

  $meta = @()
  if ($c.Project -and $c.Project -ne $c.Name) { $meta += $c.Project }
  if ($c.Model) { $meta += $c.Model }
  if ($null -ne $c.Ctx) { $meta += ('contexto {0}%' -f [math]::Round([double]$c.Ctx)) }
  if ($c.Entry) { $meta += $(if ($EntryLabels.ContainsKey([string]$c.Entry)) { $EntryLabels[[string]$c.Entry] } else { [string]$c.Entry }) }
  if ($meta) {
    $m = New-Text ($meta -join ' · ') 11 $S.T.muted
    $m.Margin = '16,1,0,0'
    [void]$wrap.Children.Add($m)
  }
  [void]$body.Children.Add($wrap)
}

function Update-Panel {
  $body = $PanelBody
  $body.Children.Clear()

  [void]$body.Children.Add((New-Header 'Limites'))
  $lims = Get-Limits
  if ($lims.Items.Count -gt 0) {
    foreach ($l in $lims.Items) { Add-Limit $body $l }
  } else {
    $msg = if ($S.ApiTask) {
      'Buscando o uso da sua conta…'
    } elseif ($S.ApiError) {
      "Não deu pra ler o uso da conta ($($S.ApiError)). Abra o Claude Code e envie uma mensagem."
    } else {
      'Abra o Claude Code e envie uma mensagem: os limites aparecem após a primeira resposta (planos Pro/Max/Team).'
    }
    $t = New-Text $msg 11.5 $S.T.muted
    $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,4'
    [void]$body.Children.Add($t)
  }

  [void]$body.Children.Add((New-Divider))
  [void]$body.Children.Add((New-Header ('Chats ativos · {0}' -f $S.Chats.Count)))
  if ($S.Chats.Count -eq 0) {
    [void]$body.Children.Add((New-Text 'Nenhum chat do Claude Code aberto.' 11.5 $S.T.muted))
  } else {
    foreach ($c in $S.Chats) { Add-Chat $body $c }
  }

  if ($lims.Source) {
    [void]$body.Children.Add((New-Divider))
    $age = (Get-NowMs) - $lims.At
    $foot = if ($age -gt $StaleMs) { 'Dados desatualizados ({0}, via {1}).' -f (Format-Ago $lims.At), $lims.Source } else { 'Atualizado {0} · via {1}' -f (Format-Ago $lims.At), $lims.Source }
    if ($S.ApiError -and $lims.Source -ne 'conta Claude') { $foot += " · conta: $($S.ApiError)" }
    $f = New-Text $foot 10.5 $(if ($age -gt $StaleMs) { $S.T.warn } else { $S.T.muted })
    $f.TextWrapping = 'Wrap'
    [void]$body.Children.Add($f)
  }
}

# ---------- posição, autostart, menus ----------
$WinMargin = 12
$CollapsedWidth = 156 + 2 * $WinMargin

function Save-Prefs {
  try {
    $cx = $Win.Left + $Win.ActualWidth / 2
    @{ x = [math]::Round($cx); y = [math]::Round($Win.Top - $S.TopShift); expanded = $S.Expanded } |
      ConvertTo-Json | Set-Content -Path $PrefsFile -Encoding UTF8
  } catch { Write-Log "widget.json: $($_.Exception.Message)" }
}

function Restore-Position {
  $vl = [Windows.SystemParameters]::VirtualScreenLeft; $vt = [Windows.SystemParameters]::VirtualScreenTop
  $vw = [Windows.SystemParameters]::VirtualScreenWidth; $vh = [Windows.SystemParameters]::VirtualScreenHeight
  try {
    $p = Get-Content $PrefsFile -Raw -ErrorAction Stop | ConvertFrom-Json
    $x = [double]$p.x - $CollapsedWidth / 2; $y = [double]$p.y
    if ($x -ge $vl - 40 -and $x -le $vl + $vw - 60 -and $y -ge $vt - 20 -and $y -le $vh + $vt - 60) {
      $Win.Left = $x; $Win.Top = $y
      return [bool]$p.expanded
    }
  } catch {}
  $wa = [Windows.SystemParameters]::WorkArea   # padrão: canto superior direito
  $Win.Left = $wa.Right - $CollapsedWidth - 16
  $Win.Top = $wa.Top + 16
  return $false
}

function Set-Expanded([bool]$on) {
  $S.Expanded = $on
  if ($on) { Update-Chats; Update-Panel }
  $Panel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
  $Win.UpdateLayout()
  if ($on) {
    # se o painel passar do fim da tela, sobe a janela (e desce de volta ao recolher)
    $bottom = [Windows.SystemParameters]::VirtualScreenTop + [Windows.SystemParameters]::VirtualScreenHeight
    $over = $Win.Top + $Win.ActualHeight - $bottom
    if ($over -gt 0) { $S.TopShift = $over; $Win.Top -= $over }
  } elseif ($S.TopShift -ne 0) {
    $Win.Top += $S.TopShift; $S.TopShift = 0
  }
  $MenuDetails.IsChecked = $on
  Save-Prefs
}

function Test-Autostart { Test-Path $StartupLnk }

function Set-Autostart([bool]$on) {
  if (-not $on) { Remove-Item $StartupLnk -Force -ErrorAction SilentlyContinue; return }
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLnk)
  if (Test-Path $Launcher) {
    $lnk.TargetPath = $Launcher
  } else {
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk.WindowStyle = 7
  }
  $lnk.WorkingDirectory = $PSScriptRoot
  $lnk.Description = 'Claude Usage Widget'
  $lnk.Save()
}

function Show-Widget { $Win.Show(); $Win.Topmost = $true; $Win.Activate() | Out-Null }

function Hide-Widget {
  $Win.Hide()
  if (-not $S.HintShown) {
    # o Windows 11 costuma esconder ícones novos na setinha ^ da bandeja
    $S.HintShown = $true
    $S.Tray.ShowBalloonTip(4000, 'Claude Usage continua rodando',
      'Clique no ícone do anel perto do relógio (talvez dentro da setinha ^) pra trazer o widget de volta.', 'Info')
  }
}

function Switch-Visible {
  if ($Win.IsVisible) { Hide-Widget } else { Show-Widget }
}

function Exit-Widget {
  $S.Exiting = $true
  $Timer.Stop()
  Save-Prefs
  $S.Tray.Visible = $false
  $S.Tray.Dispose()
  if ($S.IconHandle -ne [IntPtr]::Zero) { [void][UsageHud.Native]::DestroyIcon($S.IconHandle) }
  $App.Shutdown()
}

# menu do botão direito no widget
$Menu = New-Object Windows.Controls.ContextMenu
$MenuDetails = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Detalhes'; IsCheckable = $true }
$MenuHide = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Ocultar (fica na bandeja)' }
$MenuAuto = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Iniciar com o Windows'; IsCheckable = $true }
$MenuQuit = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Sair' }
foreach ($m in $MenuDetails, $MenuHide, $MenuAuto, (New-Object Windows.Controls.Separator), $MenuQuit) { [void]$Menu.Items.Add($m) }
$Win.ContextMenu = $Menu
$Menu.Add_Opened({ Invoke-Safe { $MenuAuto.IsChecked = Test-Autostart; $MenuDetails.IsChecked = $S.Expanded } })
$MenuDetails.Add_Click({ Invoke-Safe { Set-Expanded (-not $S.Expanded) } })
$MenuHide.Add_Click({ Invoke-Safe { Hide-Widget } })
$MenuAuto.Add_Click({ Invoke-Safe { Set-Autostart $MenuAuto.IsChecked } })
$MenuQuit.Add_Click({ Invoke-Safe { Exit-Widget } })

# ícone e menu da bandeja
$S.Tray = New-Object System.Windows.Forms.NotifyIcon
$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$TrayShow = $TrayMenu.Items.Add('Mostrar / ocultar widget')
$TrayDetails = $TrayMenu.Items.Add('Detalhes')
$TrayAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Iniciar com o Windows'
[void]$TrayMenu.Items.Add($TrayAuto)
[void]$TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$TrayQuit = $TrayMenu.Items.Add('Sair')
$TrayMenu.Add_Opening({ Invoke-Safe { $TrayAuto.Checked = Test-Autostart; $TrayDetails.Checked = $S.Expanded } })
$TrayShow.Add_Click({ Invoke-Safe { Switch-Visible } })
$TrayDetails.Add_Click({ Invoke-Safe { if (-not $Win.IsVisible) { Show-Widget }; Set-Expanded (-not $S.Expanded) } })
$TrayAuto.Add_Click({ Invoke-Safe { Set-Autostart (-not (Test-Autostart)) } })
$TrayQuit.Add_Click({ Invoke-Safe { Exit-Widget } })
$S.Tray.ContextMenuStrip = $TrayMenu
$S.Tray.Add_MouseClick({ param($src, $e) Invoke-Safe { if ($e.Button -eq 'Left') { Switch-Visible } } })

# ---------- interação ----------
$Dial.Add_MouseLeftButtonDown({
  param($src, $e)
  Invoke-Safe {
    $l0 = $Win.Left; $t0 = $Win.Top
    try { $Win.DragMove() } catch {}
    if ([math]::Abs($Win.Left - $l0) + [math]::Abs($Win.Top - $t0) -lt 3) { Set-Expanded (-not $S.Expanded) }
    else { $S.TopShift = 0; Save-Prefs }
  }
  $e.Handled = $true
})
$Panel.Add_MouseLeftButtonDown({
  param($src, $e)
  Invoke-Safe {
    try { $Win.DragMove() } catch {}
    $S.TopShift = 0; Save-Prefs
  }
  $e.Handled = $true
})
# botões que aparecem com o mouse em cima (Handled impede o clique de virar arrastar/expandir)
$BtnClose.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true; Invoke-Safe { Exit-Widget } })
$BtnMin.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true; Invoke-Safe { Hide-Widget } })
$Win.Add_MouseEnter({ $Controls.Visibility = 'Visible' })
$Win.Add_MouseLeave({ $Controls.Visibility = 'Hidden' })
$Win.Add_KeyDown({ param($src, $e) Invoke-Safe { if ($e.Key -eq 'Escape' -and $S.Expanded) { Set-Expanded $false } } })
# Alt+F4 esconde na bandeja em vez de destruir a janela (só "Sair" encerra de verdade)
$Win.Add_Closing({
  param($src, $e)
  if (-not $S.Exiting) { $e.Cancel = $true; Invoke-Safe { Hide-Widget } }
})
# mantém o círculo no mesmo lugar quando o painel (mais largo) abre ou fecha
$Win.Add_SizeChanged({
  param($src, $e)
  Invoke-Safe {
    if ($e.WidthChanged -and $e.PreviousSize.Width -gt 0) { $Win.Left -= ($e.NewSize.Width - $e.PreviousSize.Width) / 2 }
  }
})
$Win.Add_SourceInitialized({
  Invoke-Safe {
    # WS_EX_TOOLWINDOW: some do Alt+Tab
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper $Win).Handle
    $ex = [UsageHud.Native]::GetWindowLong($hwnd, -20)
    [void][UsageHud.Native]::SetWindowLong($hwnd, -20, ($ex -bor 0x80))
  }
})

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(1)
$Timer.Add_Tick({
  try {
    $S.Tick++
    if ($ShowSignal.WaitOne(0)) { Show-Widget }   # alguém abriu o atalho de novo
    if ($S.Tick % 5 -eq 0) { Set-Theme }
    Complete-ApiFetch
    if (-not $S.ApiTask -and (Get-NowMs) -ge $S.ApiNextAt) { Start-ApiFetch }
    Update-State
    Update-Dial
    if ($S.Expanded) {
      if ($S.Tick % 3 -eq 0) { Update-Chats }
      Update-Panel
    }
  } catch { Write-Log "tick: $($_.Exception.Message)" }
})

# ---------- start ----------
Set-Theme
Update-State
Update-Chats
Update-Dial
$startExpanded = Restore-Position
$S.Tray.Visible = $true

$App = New-Object Windows.Application
$App.ShutdownMode = 'OnExplicitShutdown'
$App.Add_DispatcherUnhandledException({ param($src, $e) Write-Log "unhandled: $($e.Exception.Message)"; $e.Handled = $true })
$Win.Add_ContentRendered({ Invoke-Safe { if ($startExpanded) { Set-Expanded $true } } })
$Timer.Start()
[void]$App.Run($Win)
$Mutex.ReleaseMutex()
