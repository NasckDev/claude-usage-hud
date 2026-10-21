#!/usr/bin/env bash
# claude-usage-hud — instalador (macOS / Linux / WSL)
# Uso local:   ./install.sh
# Uso remoto:  bash <(curl -sSL https://raw.githubusercontent.com/NasckDev/claude-usage-hud/main/install.sh)
set -euo pipefail

REPO_RAW="${CLAUDE_USAGE_HUD_RAW:-https://raw.githubusercontent.com/NasckDev/claude-usage-hud/main}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TARGET="$CLAUDE_DIR/statusline-usage-hud.js"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v node >/dev/null 2>&1 || { echo "❌ Node.js não encontrado. O Claude Code precisa dele, então instale o Node e rode de novo."; exit 1; }

mkdir -p "$CLAUDE_DIR"

# 1) copia o script (local se existir ao lado, senão baixa)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$HERE" ] && [ -f "$HERE/statusline.js" ]; then
  cp "$HERE/statusline.js" "$TARGET"
else
  curl -fsSL "$REPO_RAW/statusline.js" -o "$TARGET"
fi
chmod +x "$TARGET"

# 2) mescla a chave statusLine no settings.json sem apagar o resto
node - "$SETTINGS" "$TARGET" <<'EOF'
const fs = require("fs");
const [,, settingsPath, target] = process.argv;
let s = {};
if (fs.existsSync(settingsPath)) {
  try { s = JSON.parse(fs.readFileSync(settingsPath, "utf8")); }
  catch (e) { console.error("❌ settings.json inválido, corrija antes:", settingsPath); process.exit(1); }
  fs.copyFileSync(settingsPath, settingsPath + ".bak");
}
s.statusLine = { type: "command", command: `node "${target}"`, padding: 0 };
fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + "\n");
EOF

echo "✅ claude-usage-hud instalado."
echo "   Script:   $TARGET"
echo "   Settings: $SETTINGS (backup em settings.json.bak)"
echo
echo "Abra uma NOVA sessão do Claude Code. Os limites aparecem após a primeira resposta."
