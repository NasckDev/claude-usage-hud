#!/usr/bin/env bash
set -euo pipefail
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
rm -f "$CLAUDE_DIR/statusline-usage-hud.js"
rm -rf "$CLAUDE_DIR/usage-hud"
if [ -f "$SETTINGS" ]; then
  node -e '
    const fs=require("fs"); const p=process.argv[1];
    const s=JSON.parse(fs.readFileSync(p,"utf8"));
    if (s.statusLine && String(s.statusLine.command||"").includes("statusline-usage-hud")) delete s.statusLine;
    fs.writeFileSync(p, JSON.stringify(s,null,2)+"\n");
  ' "$SETTINGS"
fi
echo "✅ claude-usage-hud removido. Abra uma nova sessão do Claude Code."
