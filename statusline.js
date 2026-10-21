#!/usr/bin/env node
// claude-usage-hud — status line do Claude Code
// Mostra: contexto, sessão 5h (com reset), semana 7d (com reset), modelo e pasta.
// Também grava ~/.claude/usage-hud/state.json para o widget flutuante ler.
// Sem dependências: só Node (que o Claude Code já usa).

const fs = require("fs");
const os = require("os");
const path = require("path");

const STATE_DIR = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"), "usage-hud");
const STATE_FILE = path.join(STATE_DIR, "state.json");
// sessão some do state.json após 12h sem atualizar (o widget cruza com os processos vivos)
const SESSION_TTL_MS = 12 * 60 * 60 * 1000;

// ---------- utilidades ----------
const c = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  bold: "\x1b[1m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  cyan: "\x1b[36m",
  magenta: "\x1b[35m",
};

function color(pct) {
  if (pct == null) return c.dim;
  if (pct >= 85) return c.red;
  if (pct >= 60) return c.yellow;
  return c.green;
}

// barra de 6 blocos: █ cheio, ▌ meio, ░ vazio
function gauge(pct, width = 6) {
  if (pct == null) return "░".repeat(width);
  const filled = Math.max(0, Math.min(width, (pct / 100) * width));
  const full = Math.floor(filled);
  const half = filled - full >= 0.5 ? 1 : 0;
  return "█".repeat(full) + (half ? "▌" : "") + "░".repeat(Math.max(0, width - full - half));
}

// resets_at pode vir como epoch (s ou ms) ou ISO string
function toMs(resetsAt) {
  if (resetsAt == null) return null;
  if (typeof resetsAt === "number") return resetsAt < 1e12 ? resetsAt * 1000 : resetsAt;
  const t = Date.parse(resetsAt);
  return Number.isNaN(t) ? null : t;
}

function countdown(resetsAt) {
  const ms = toMs(resetsAt);
  if (!ms) return "";
  let diff = Math.max(0, ms - Date.now());
  const d = Math.floor(diff / 86400000); diff -= d * 86400000;
  const h = Math.floor(diff / 3600000); diff -= h * 3600000;
  const m = Math.floor(diff / 60000);
  if (d > 0) return `${d}d${h}h`;
  if (h > 0) return `${h}h${String(m).padStart(2, "0")}m`;
  return `${m}m`;
}

function seg(label, pct, resetsAt) {
  const col = color(pct);
  const pctTxt = pct == null ? "--" : `${Math.round(pct)}%`;
  const cd = countdown(resetsAt);
  return `${c.dim}${label}${c.reset} ${col}${gauge(pct)} ${pctTxt}${c.reset}${cd ? ` ${c.dim}${cd}${c.reset}` : ""}`;
}

function get(obj, ...keys) {
  let cur = obj;
  for (const k of keys) {
    if (cur == null || typeof cur !== "object") return undefined;
    cur = cur[k];
  }
  return cur;
}

// ---------- estado compartilhado (para o widget) ----------
function writeState(input) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    let state = {};
    try { state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch {}

    const now = Date.now();
    const rl = input.rate_limits;
    const sessions = state.sessions || {};

    // registra/atualiza a sessão atual
    const sid = input.session_id;
    if (sid) sessions[sid] = {
      session_id: sid,
      cwd: get(input, "workspace", "current_dir") || input.cwd || null,
      project: path.basename(get(input, "workspace", "project_dir") || input.cwd || ""),
      name: input.session_name || null,
      model: get(input, "model", "display_name") || null,
      context_used_pct: contextUsed(input),
      transcript_path: input.transcript_path || null,
      last_seen: now,
    };

    // remove sessões antigas
    for (const [id, s] of Object.entries(sessions)) {
      if (now - (s.last_seen || 0) > SESSION_TTL_MS) delete sessions[id];
    }

    const next = {
      updated_at: now,
      // só sobrescreve rate_limits se vier algo (no começo da sessão pode vir ausente)
      rate_limits: rl ? normalizeRateLimits(rl) : (state.rate_limits || null),
      sessions,
    };
    // grava em arquivo temporário e renomeia, pra quem lê nunca pegar JSON pela metade
    const tmp = `${STATE_FILE}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(next, null, 2));
    try { fs.renameSync(tmp, STATE_FILE); }
    catch { fs.writeFileSync(STATE_FILE, JSON.stringify(next, null, 2)); try { fs.unlinkSync(tmp); } catch {} }
  } catch {
    // nunca deixa a status line quebrar por causa do arquivo
  }
}

function normalizeRateLimits(rl) {
  const out = {};
  for (const [k, v] of Object.entries(rl)) {
    if (v && typeof v === "object") {
      // mantém campos extras (ex.: spend_limit.used_usd/limit_usd/period)
      const { resets_at, ...rest } = v;
      out[k] = { ...rest, used_percentage: v.used_percentage ?? null, resets_at_ms: toMs(resets_at) };
    }
  }
  return out;
}

function contextUsed(input) {
  const used = get(input, "context_window", "used_percentage");
  if (typeof used === "number") return used;
  const rem = get(input, "context_window", "remaining_percentage");
  if (typeof rem === "number") return 100 - rem;
  return null;
}

// ---------- main ----------
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let input = {};
  try { input = JSON.parse(raw || "{}"); } catch {}

  writeState(input);

  const model = get(input, "model", "display_name") || "Claude";
  const dir = path.basename(get(input, "workspace", "current_dir") || input.cwd || "") || "~";
  const ctx = contextUsed(input);
  const fh = input.rate_limits?.five_hour;
  const sd = input.rate_limits?.seven_day;

  const parts = [
    `${c.magenta}${model}${c.reset} ${c.dim}· ${dir}${c.reset}`,
    seg("Ctx", ctx),
  ];

  if (fh || sd) {
    parts.push(seg("5h", fh?.used_percentage, fh?.resets_at));
    parts.push(seg("7d", sd?.used_percentage, sd?.resets_at));
  } else {
    parts.push(`${c.dim}limites: aguardando 1ª resposta${c.reset}`);
  }

  const cols = parseInt(process.env.COLUMNS || "0", 10);
  let line = parts.join(`  ${c.dim}│${c.reset}  `);
  // em terminal estreito, tira o modelo/pasta
  if (cols && stripAnsi(line).length > cols) line = parts.slice(1).join(`  ${c.dim}│${c.reset}  `);

  try { process.stdout.write(line + "\n"); } catch {}
});

function stripAnsi(s) { return s.replace(/\x1b\[[0-9;]*m/g, ""); }
