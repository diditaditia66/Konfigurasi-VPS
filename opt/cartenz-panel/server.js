// server.js (CommonJS) — Cartenz Panel
// ENV wajib: SESSION_SECRET (mis. export SESSION_SECRET=$(openssl rand -hex 32))
// Port default 8080

const express = require("express");
const session = require("express-session");
const bcrypt = require("bcryptjs");
const fs = require("fs");
const fsp = require("fs/promises");
const path = require("path");
const { exec } = require("child_process");

const __dirname = __dirname || path.dirname(process.argv[1]);
const PORT = process.env.PORT || 8080;
const SESSION_SECRET = process.env.SESSION_SECRET || "";
const USERS_PATH = path.join(__dirname, "users.json");

if (!SESSION_SECRET) {
  console.error("[fatal] SESSION_SECRET kosong. Set ENV lalu restart service.");
  process.exit(1);
}

// ------- App & middleware -------
const app = express();
app.use(express.static(path.join(__dirname, "public"), { index: "index.html" }));
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true }));

app.set("trust proxy", 1);
app.use(
  session({
    name: "cartenz.sid",
    secret: SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: { httpOnly: true, sameSite: "lax", maxAge: 1000 * 60 * 60 * 6 },
  })
);

// ------- Users helpers -------
async function ensureUsersJson() {
  if (!fs.existsSync(USERS_PATH)) {
    const passhash = await bcrypt.hash("ganti_password", 12);
    const seed = [{ username: "admin", passhash, role: "admin" }];
    await fsp.writeFile(USERS_PATH, JSON.stringify(seed, null, 2));
    console.log("[init] users.json dibuat. User: admin / ganti_password");
  }
}
function loadUsers() {
  return fsp.readFile(USERS_PATH, "utf8").then((t) => JSON.parse(t));
}
function saveUsers(users) {
  return fsp.writeFile(USERS_PATH, JSON.stringify(users, null, 2));
}
awaiter(ensureUsersJson());

// ------- Utils -------
function stripAnsi(s) {
  return (s || "").replace(/\x1B\[[0-9;]*[A-Za-z]/g, "").replace(/\r/g, "");
}
function clampOutput(s, maxBytes = 200 * 1024) {
  const b = Buffer.from(s || "", "utf8");
  if (b.length <= maxBytes) return s;
  return b.subarray(0, maxBytes - 1024).toString("utf8") + "\n\n[Output dipotong]\n";
}
function execBash(cmd, timeoutMs = 20000) {
  return new Promise((resolve) => {
    exec(
      `bash -lc '${cmd.replace(/'/g, `'\\''`)}'`,
      { env: { ...process.env, TERM: "vt100" }, timeout: timeoutMs, maxBuffer: 5 * 1024 * 1024 },
      (err, stdout, stderr) => {
        let out = (stdout || "") + (stderr || "");
        if (err && err.killed) out += "\n[Perintah dihentikan karena timeout]\n";
        resolve(clampOutput(stripAnsi(out)));
      }
    );
  });
}
function joinInputs(inputs = [], extraBlank = 5) {
  const blanks = Array.from({ length: extraBlank }, () => "").join("\n");
  return [...inputs, blanks].join("\n");
}
function ensureAuth(req, res, next) {
  if (req.session && req.session.user) return next();
  return res.status(401).json({ ok: false, error: "Unauthorized" });
}
function sanitizeUser(u) {
  return String(u || "").trim().replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 32);
}
function sanitizeDays(d) {
  const n = parseInt(String(d || "0").replace(/[^0-9]/g, ""), 10);
  if (!Number.isFinite(n) || n <= 0) return 1;
  return Math.min(n, 365);
}

// ------- Auth API -------
app.get("/api/whoami", (req, res) => res.json({ ok: true, user: req.session?.user || null }));

app.post("/api/login", async (req, res) => {
  try {
    const { username, password } = req.body || {};
    const users = await loadUsers();
    const u = users.find((x) => x.username === username);
    if (!u) return res.json({ ok: false, error: "Invalid credentials" });
    const ok = await bcrypt.compare(String(password || ""), u.passhash);
    if (!ok) return res.json({ ok: false, error: "Invalid credentials" });
    req.session.user = { username: u.username, role: u.role || "user" };
    res.json({ ok: true });
  } catch {
    res.json({ ok: false, error: "Login error" });
  }
});

app.post("/api/logout", (req, res) => req.session.destroy(() => res.json({ ok: true })));

app.post("/api/change-password", ensureAuth, async (req, res) => {
  try {
    const { currentPassword, newPassword } = req.body || {};
    if (!newPassword || String(newPassword).length < 6)
      return res.json({ ok: false, error: "Password baru minimal 6 karakter" });
    const users = await loadUsers();
    const me = users.findIndex((x) => x.username === req.session.user.username);
    if (me < 0) return res.json({ ok: false, error: "User tidak ditemukan" });
    const ok = await bcrypt.compare(String(currentPassword || ""), users[me].passhash);
    if (!ok) return res.json({ ok: false, error: "Password saat ini salah" });
    users[me].passhash = await bcrypt.hash(String(newPassword), 12);
    await saveUsers(users);
    res.json({ ok: true, message: "Password berhasil diganti" });
  } catch {
    res.json({ ok: false, error: "Gagal ganti password" });
  }
});

// ------- Script maps & timeouts -------
const TRIAL = {
  ssh: "/usr/bin/trial",
  vmess: "/usr/bin/trialvmess",
  vless: "/usr/bin/trialvless",
  trojan: "/usr/bin/trialtrojan",
  ssws: "/usr/bin/trialssws",
};
const ADD = {
  vmess: "/usr/bin/add-ws",
  vless: "/usr/bin/add-vless",
  trojan: "/usr/bin/add-tr",
  ssws: "/usr/bin/add-ssws",
};
const TIMEOUT = {
  trial: { ssh: 15000, vmess: 22000, vless: 22000, trojan: 22000, ssws: 25000 },
  add: { vmess: 22000, vless: 22000, trojan: 22000, ssws: 25000 },
};

// ------- Trial endpoints -------
app.post("/api/trial/:type", ensureAuth, async (req, res) => {
  try {
    const type = String(req.params.type || "").toLowerCase();
    const script = TRIAL[type];
    if (!script) return res.status(400).json({ ok: false, error: "Jenis trial tidak dikenal" });
    const cmd = `{ printf '%s' "${joinInputs([], 6)}"; } | ${script}`;
    const out = await execBash(cmd, TIMEOUT.trial[type] || 20000);
    res.json({ ok: true, text: out });
  } catch {
    res.json({ ok: false, error: "Trial gagal dijalankan" });
  }
});

// ------- Add endpoints -------
app.post("/api/add/:type", ensureAuth, async (req, res) => {
  try {
    const type = String(req.params.type || "").toLowerCase();
    const script = ADD[type];
    if (!script) return res.status(400).json({ ok: false, error: "Jenis add tidak dikenal" });

    const u = sanitizeUser(req.body?.user);
    const d = sanitizeDays(req.body?.days);
    if (!u) return res.json({ ok: false, error: "Username/remarks tidak valid" });

    const piped = joinInputs([u, String(d)], 6);
    const cmd = `{ printf '%s\n' "${piped}"; } | ${script}`;
    const out = await execBash(cmd, TIMEOUT.add[type] || 22000);
    res.json({ ok: true, text: out });
  } catch {
    res.json({ ok: false, error: "Add gagal dijalankan" });
  }
});

// ------- Fallback UI -------
app.get("*", (req, res) => res.sendFile(path.join(__dirname, "public", "index.html")));

// ------- Start -------
app.listen(PORT, () => console.log(`[panel] listening on :${PORT}`));

// small helper to allow top-level await behavior in CJS
function awaiter(p) { p.then(()=>{}).catch((e)=>console.error(e)); }

