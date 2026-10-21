# claude-usage-hud

Um círculo flutuante na tela que mostra quanto você já usou do Claude Code, igual à tela de limites do app:

- **Anel externo + número grande**: sessão atual (janela de 5h) e quanto falta para resetar
- **Anel interno**: limite semanal (todos os modelos)
- **Clique no círculo**: painel com **todos** os limites (sessão, semana, por modelo, como o Fable, e créditos extras, se você tiver) e os **chats do Claude Code abertos agora** (trabalhando/ocioso, pasta, VS Code ou terminal)
- Cores: verde (< 60%), amarelo (60–85%), vermelho (≥ 85%)
- Ícone na bandeja do Windows com o mesmo anel e o resumo no tooltip

Também instala uma **status line** pro Claude Code no terminal:

```
Opus · meu-app  │  Ctx █▌░░░░ 31%  │  5h ██▌░░░ 42% 2h04m  │  7d █████░ 88% 2d4h
```

## Instalar (Windows)

Precisa de Node.js (o Claude Code já usa) e de um login do Claude Code com plano Pro/Max/Team.

1. Baixe o **[claude-usage-hud-windows.zip](https://github.com/NasckDev/claude-usage-hud/releases/latest/download/claude-usage-hud-windows.zip)** (ou clone este repositório).
2. Descompacte em qualquer pasta.
3. Dê **dois cliques em `instalar.cmd`**.

Pronto: o widget aparece no canto superior direito, ganha um atalho no menu Iniciar ("Claude Usage Widget") e passa a abrir junto com o Windows.

Opções (rodando pelo PowerShell): `.\install.ps1 -NoAutostart` (não inicia com o Windows), `.\install.ps1 -NoWidget` (só a status line).

Pra atualizar, baixe o zip de novo e rode `instalar.cmd` outra vez. Ele substitui a versão anterior e mantém a posição do widget.

## Usar

| Ação | Como |
|---|---|
| Ver detalhes | clique no círculo (Esc fecha) |
| Mover | arraste |
| Minimizar | botão **–** (aparece com o mouse em cima) ou Alt+F4. Vai pra bandeja, perto do relógio (às vezes dentro da setinha **^**) |
| Trazer de volta | clique no ícone da bandeja, ou abra "Claude Usage Widget" no menu Iniciar |
| Fechar de vez | botão **✕**, ou botão direito → Sair |
| Iniciar com o Windows | botão direito (no widget ou na bandeja) → Iniciar com o Windows |

## De onde vêm os dados (e o que ele acessa)

- **Limites**: a cada 60 s o widget consulta `https://api.anthropic.com/api/oauth/usage`, o mesmo dado da tela de limites do app. Pra isso ele **lê** o token de login do Claude Code em `~/.claude/.credentials.json` a cada consulta. O token não é gravado nem enviado pra nenhum outro lugar, e quem renova é o próprio Claude Code. A consulta **não gasta tokens nem limite**: ela só lê os números, não chama nenhum modelo.
  - Esse endpoint não é documentado oficialmente e pode mudar. Se falhar, o widget usa o que a status line gravou (só sessão/semana, e só quando o Claude Code roda no terminal).
- **Chats ativos**: `~/.claude/sessions/*.json`, que o próprio Claude Code mantém. O widget confere se o processo de cada chat ainda está vivo.
- **% de contexto por chat**: vem da status line, então só aparece pra chats no terminal (`claude`). A extensão do VS Code não roda status line.

Arquivos do widget ficam em `~/.claude/usage-hud/`: `widget.json` (posição), `widget.log` (erros), `state.json` (status line).

## Desinstalar

Dois cliques em `desinstalar.cmd`. Ele remove o widget, os atalhos, a status line e a chave `statusLine` do `~/.claude/settings.json` (só se for a deste projeto).

## macOS / Linux

O widget é só pra Windows. A status line funciona:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/NasckDev/claude-usage-hud/main/install.sh)
```

Ou clone o repositório e rode `./install.sh` (`./uninstall.sh` pra remover).

## Detalhes técnicos

- Widget: `widget/usage-widget.ps1`, PowerShell 5.1 + WPF, sem dependências. O instalador compila um lançador `ClaudeUsageWidget.exe` minúsculo (com o compilador C# que já vem no Windows) só pra abrir o widget sem piscar janela de console.
- Status line: `statusline.js`. O Claude Code chama o script passando um JSON com `rate_limits`, `context_window`, `session_id` etc. O script formata a linha e grava `~/.claude/usage-hud/state.json`:

```json
{
  "updated_at": 1792605231530,
  "rate_limits": {
    "five_hour": { "used_percentage": 42, "resets_at_ms": 1792612731000 },
    "seven_day": { "used_percentage": 88, "resets_at_ms": 1792796031000 }
  },
  "sessions": {
    "<session_id>": {
      "cwd": "C:/code/meu-app", "project": "meu-app", "name": "…", "model": "Opus",
      "context_used_pct": 31, "transcript_path": "...", "last_seen": 1792605231457
    }
  }
}
```

- O instalador faz backup do `settings.json` (`settings.json.bak`) e só mexe na chave `statusLine`. Se você já tinha outra status line, ela é substituída (fica no backup e o instalador avisa).
