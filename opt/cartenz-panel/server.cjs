// server.cjs – Cartenz Panel API (Shadowsocks fix + list & delete accounts)

const fs = require("fs");
const path = require("path");
const express = require("express");
const session = require("express-session");
const bcrypt = require("bcryptjs");
const { exec } = require("child_process");

// ===== Konfigurasi =====
const PORT = process.env.PORT ? Number(process.env.PORT) : 8080;
const SESSION_SECRET =
  process.env.SESSION_SECRET || "dev_secret_ubah_dengan_ENV";

const APP_DIR = __dirname;
const DATA_FILE = path.join(APP_DIR, "users.json");
const PUBLIC_DIR = path.join(APP_DIR, "public");

// ===== users.json helper =====
function ensureUsers() {
  if (!fs.existsSync(DATA_FILE)) {
    const passhash = bcrypt.hashSync("ganti_password", 12);
    fs.writeFileSync(
      DATA_FILE,
      JSON.stringify([{ username: "admin", passhash, role: "admin" }], null, 2)
    );
    console.log("[init] users.json dibuat. User: admin / ganti_password (segera ganti!)");
  }
}
function readUsers() {
  try { return JSON.parse(fs.readFileSync(DATA_FILE, "utf8")); }
  catch { return []; }
}
function writeUsers(arr) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(arr, null, 2));
}

// ===== App =====
const app = express();
app.set("trust proxy", 1);
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true }));
app.use(
  session({
    name: "cartenz.sid",
    secret: SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: { httpOnly: true, sameSite: "lax", maxAge: 7 * 24 * 60 * 60 * 1000, secure: false },
  })
);
if (fs.existsSync(PUBLIC_DIR)) {
  app.use(express.static(PUBLIC_DIR, { maxAge: 0 }));
}

// ===== Auth =====
function authRequired(req, res, next) {
  if (req.session && req.session.user) return next();
  return res.status(401).json({ error: "unauthorized" });
}
app.post("/api/login", (req, res) => {
  const { username = "", password = "" } = req.body || {};
  const u = readUsers().find((x) => x.username === username);
  if (!u) return res.status(400).json({ error: "Invalid credentials" });
  if (!bcrypt.compareSync(password, u.passhash))
    return res.status(400).json({ error: "Invalid credentials" });
  req.session.user = { username: u.username, role: u.role || "admin" };
  res.json({ ok: true, user: req.session.user });
});
app.post("/api/logout", (req, res) => req.session.destroy(() => res.json({ ok: true })));
app.get("/api/me", (req, res) => res.json({ user: req.session?.user || null }));
app.post("/api/change-password", authRequired, (req, res) => {
  const { oldPassword = "", newPassword = "" } = req.body || {};
  if (!newPassword || newPassword.length < 6)
    return res.status(400).json({ error: "Password baru minimal 6 karakter" });
  const users = readUsers();
  const i = users.findIndex((x) => x.username === req.session.user.username);
  if (i < 0) return res.status(400).json({ error: "User tidak ditemukan" });
  if (!bcrypt.compareSync(oldPassword, users[i].passhash))
    return res.status(400).json({ error: "Password lama salah" });
  users[i].passhash = bcrypt.hashSync(newPassword, 12);
  writeUsers(users);
  res.json({ ok: true });
});

// ===== Shell helpers (tanpa login shell + strip ANSI) =====
const ANSI_REGEX = /\u001b\[[0-9;?]*[ -/]*[@-~]|\u001b[@-Z\\-_]|\r/g; // ESC seq + CR
function stripAnsi(s = "") { return s.replace(ANSI_REGEX, ""); }

function sh(cmd, { timeout = 120000 } = {}) {
  return new Promise((resolve, reject) => {
    exec(
      cmd,
      {
        shell: "/bin/bash",
        timeout,
        maxBuffer: 5 * 1024 * 1024,
        env: {
          ...process.env,
          TERM: "dumb",
          LC_ALL: "C",
          COLUMNS: "120",
          LINES: "40",
          NONINTERACTIVE: "1",
        },
      },
      (err, stdout, stderr) => {
        const raw = `${stdout || ""}${stderr || ""}`;
        const cleaned = stripAnsi(raw).trim();
        if (err) return reject(new Error(cleaned || err.message));
        resolve(cleaned || "(no output)");
      }
    );
  });
}

// ===== Util =====
function randPass(len = 10) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  let s = "";
  for (let i = 0; i < len; i++) s += chars[Math.floor(Math.random() * chars.length)];
  return s;
}
function fileExists(p) { try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; } }

// ===== Peta perintah =====
const TRIAL_MAP = {
  ssh: "/usr/bin/trial",
  vmess: "/usr/bin/trialvmess",
  vless: "/usr/bin/trialvless",
  trojan: "/usr/bin/trialtrojan",
  ss: "/usr/bin/trialssws",
};
const ADD_MAP = {
  vmess: { feed: (r, d) => `printf '%s\n%s\n' '${r}' '${d}' | /usr/bin/add-ws` },
  vless: { feed: (r, d) => `printf '%s\n%s\n' '${r}' '${d}' | /usr/bin/add-vless` },
  trojan:{ feed: (r, d) => `printf '%s\n%s\n' '${r}' '${d}' | /usr/bin/add-tr` },
  ss:    { feed: (r, d) => `printf '%s\n%s\n' '${r}' '${d}' | /usr/bin/add-ssws` },
};

// ===== Trial =====
app.post("/api/trial/:kind", authRequired, async (req, res) => {
  try {
    const kind = String(req.params.kind || "").toLowerCase();
    const script = TRIAL_MAP[kind];
    if (!script) return res.status(400).json({ error: "Unsupported kind" });
    const out = await sh(script);
    res.json({ output: out });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ===== Add SSH =====
async function handleAddSSH(req, res) {
  try {
    const username = (req.body.username || req.body.remarks || "").trim();
    const passwordRaw = (req.body.password || "").toString();
    const days = parseInt(req.body.days, 10) || 30;
    const password = passwordRaw || randPass();

    if (!/^[a-zA-Z0-9_][a-zA-Z0-9_\-]{1,31}$/.test(username))
      return res.status(400).json({ error: "username invalid" });
    if (days < 1 || days > 3650) return res.status(400).json({ error: "days out of range" });

    const safePass = password.replace(/'/g, "'\\''");
    const cmd = `printf '%s\n%s\n%s\n' '${username}' '${safePass}' '${days}' | /usr/bin/usernew`;
    const out = await sh(cmd, { timeout: 180000 });
    res.json({ output: out, generatedPassword: !passwordRaw ? password : undefined });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}

// ===== Add Generic =====
async function handleAddGeneric(req, res) {
  try {
    const kind = String(req.params.kind || "").toLowerCase();

    // izinkan ssh juga lewat endpoint generik
    if (kind === "ssh") return handleAddSSH(req, res);

    const cfg = ADD_MAP[kind];
    if (!cfg) return res.status(400).json({ error: "Unsupported kind" });

    const remarks = (req.body.remarks || "").trim();
    const days = parseInt(req.body.days, 10) || 30;
    if (!remarks) return res.status(400).json({ error: "remarks is required" });
    if (days < 1 || days > 3650) return res.status(400).json({ error: "days out of range" });

    const cmd = cfg.feed(remarks, days);
    const out = await sh(cmd);
    res.json({ output: out });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}

// Endpoint generik
app.post("/api/add/:kind", authRequired, handleAddGeneric);

// ===== FIX: Shadowsocks alias & dukung GET (beberapa UI lama pakai GET) =====
function wrap(method, path, handler) { app[method](path, authRequired, handler); }
wrap("post", "/api/add/ss", (req, res) => { req.params = { kind: "ss" }; return handleAddGeneric(req, res); });
wrap("get",  "/api/add/ss", (req, res) => { req.params = { kind: "ss" }; return handleAddGeneric(req, res); });
wrap("post", "/api/add/shadowsocks", (req, res) => { req.params = { kind: "ss" }; return handleAddGeneric(req, res); });
wrap("get",  "/api/add/shadowsocks", (req, res) => { req.params = { kind: "ss" }; return handleAddGeneric(req, res); });

// Endpoint khusus tetap ada
app.post("/api/add/ssh", authRequired, handleAddSSH);

// ===== List Accounts =====
function parseXrayAccounts() {
  const result = { vmess: [], vless: [], trojan: [], ss: [] };
  let txt = "";
  try { txt = fs.readFileSync("/etc/xray/config.json", "utf8"); } catch { return result; }

  // VMESS  →  ### user 2025-11-30
  (txt.match(/^###\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/gm) || []).forEach(line => {
    const m = line.match(/^###\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/);
    if (m) result.vmess.push({ user: m[1], exp: m[2] });
  });

  // VLESS  →  #& user 2025-11-30
  (txt.match(/^#&\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/gm) || []).forEach(line => {
    const m = line.match(/^#&\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/);
    if (m) result.vless.push({ user: m[1], exp: m[2] });
  });

  // TROJAN →  #! user 2025-11-30
  (txt.match(/^#!\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/gm) || []).forEach(line => {
    const m = line.match(/^#!\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/);
    if (m) result.trojan.push({ user: m[1], exp: m[2] });
  });

  // SS (ws/grpc) juga memakai "### user exp" di blok #ssws/#ssgrpc
  // Kita masukkan yang belum terbaca di vmess (pakai set untuk hindari dobel)
  const vmessSet = new Set(result.vmess.map(x => x.user));
  (txt.match(/^###\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/gm) || []).forEach(line => {
    const m = line.match(/^###\s+(\S+)\s+(\d{4}-\d{2}-\d{2})/);
    if (m && !vmessSet.has(m[1])) result.ss.push({ user: m[1], exp: m[2] });
  });

  return result;
}

async function listSSHAccounts() {
  // Ambil user dengan shell /bin/false & uid >= 1000
  const cmd = `
    awk -F: '($3>=1000)&&($7=="/bin/false"){print $1}' /etc/passwd | while read u; do
      exp=$(chage -l "$u" | awk -F": " "/Account expires/{print \\$2}");
      echo "$u|$exp";
    done
  `;
  const out = await sh(cmd);
  const rows = out.split("\n").filter(Boolean);
  return rows.map(r => {
    const [user, exp] = r.split("|");
    return { user, exp: (exp || "").trim() };
  });
}

app.get("/api/accounts", authRequired, async (req, res) => {
  try {
    const ssh = await listSSHAccounts().catch(() => []);
    const xr = parseXrayAccounts();
    res.json({ ssh, vmess: xr.vmess, vless: xr.vless, trojan: xr.trojan, ss: xr.ss });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ===== Delete Accounts =====
app.delete("/api/accounts/:kind/:name", authRequired, async (req, res) => {
  try {
    const kind = String(req.params.kind || "").toLowerCase();
    const name = String(req.params.name || "").trim();

    if (!name) return res.status(400).json({ error: "name required" });

    if (kind === "ssh") {
      const out = await sh(`pkill -KILL -u '${name}' 2>/dev/null || true; userdel -f '${name}' && echo "deleted"`);
      return res.json({ ok: true, output: out });
    }

    const DEL = {
      vmess: "/usr/bin/del-ws",
      vless: "/usr/bin/del-vless",
      trojan: "/usr/bin/del-tr",
      ss: "/usr/bin/del-ssws",
      shadowsocks: "/usr/bin/del-ssws",
    }[kind];

    if (!DEL || !fileExists(DEL)) {
      return res
        .status(501)
        .json({ error: "delete-script not found", needed: DEL || "(unknown)" });
    }

    const out = await sh(`printf '%s\n' '${name}' | ${DEL}`);
    return res.json({ ok: true, output: out });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ===== Health =====
app.get("/api/ping", (_req, res) => res.json({ ok: true }));

// ===== Start =====
ensureUsers();
app.listen(PORT, () => console.log(`[panel] listening on :${PORT}`));

