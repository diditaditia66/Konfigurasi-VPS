// parsers.js
/**
 * Normalisasi teks: buang ANSI, CR, dan strip baris dekoratif ━━ dll
 */
export function clean(raw) {
  const ansi = /\x1B\[[0-9;]*[A-Za-z]/g;
  return (raw || "")
    .replace(ansi, "")
    .replace(/\r/g, "")
    .split("\n")
    .map(l => l.replace(/^\s*\|\s*|\s*\|\s*$/g, "").trim())
    .filter(l => l && !/^[\-=━─]{10,}$/.test(l))
    .join("\n");
}

/**
 * Ambil pasangan "Label : value", case-insensitive,
 * TIDAK memotong URL (ambil semua setelah ':' apa adanya).
 */
export function kvParse(block) {
  const obj = {};
  const lines = block.split("\n");
  for (const line of lines) {
    const m = line.match(/^\s*([A-Za-z0-9 \/()#-]+?)\s*:\s*(.*)$/);
    if (m) {
      const key = m[1].trim().toLowerCase();
      const val = m[2].trim();
      obj[key] = val;
    }
  }
  return obj;
}

/**
 * Ekstrak "blok akun" mulai dari baris yang mengandung "Remarks" sampai habis
 * (atau sampai ketemu baris kosong kosong panjang).
 */
export function extractAccountBlock(raw) {
  const lines = clean(raw).split("\n");
  const startIdx = lines.findIndex(l => /^remarks\b/i.test(l));
  if (startIdx === -1) return clean(raw);
  return lines.slice(startIdx).join("\n");
}

/**
 * Bentuk kartu HTML untuk masing-masing jenis dari object kv.
 * Semuanya menyatukan LINK TLS / none / gRPC di satu kartu.
 */
function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

export function renderVMess(block) {
  const kv = typeof block === "string" ? kvParse(block) : block;
  const html = `
<b>VMESS ACCOUNT</b>

<b>>> DETAILS <<</b>
Remarks     : <code>${esc(kv["remarks"] || "")}</code>
id (UUID)   : <code>${esc(kv["id"] || kv["id (uuid)"] || "")}</code>
alterId     : <code>${esc(kv["alterid"] || "0")}</code>
Security    : <code>${esc(kv["security"] || "auto")}</code>
Expired On  : <code>${esc(kv["expired on"] || kv["expired date"] || kv["expire"] || "")}</code>

<b>>> CONNECTION <<</b>
Domain/Host : <code>${esc(kv["domain"] || kv["domain/host"] || kv["host"] || kv["host/ip"] || "")}</code>
Network     : <code>${esc(kv["network"] || "ws")}</code>
Path        : <code>${esc(kv["path"] || "")}</code>
ServiceName : <code>${esc(kv["servicename"] || kv["service name"] || kv["grpc name"] || "")}</code>
Port TLS    : <code>${esc(kv["port tls"] || kv["tls"] || "")}</code>
Port none   : <code>${esc(kv["port none tls"] || kv["port none"] || kv["none"] || "")}</code>
Port gRPC   : <code>${esc(kv["port grpc"] || kv["grpc"] || "")}</code>

<b>>> LINKS <<</b>
${kv["link tls"] ? `VMess TLS : <pre>${esc(kv["link tls"])}</pre>` : ""}
${kv["link none tls"] || kv["link none"] ? `VMess none TLS : <pre>${esc(kv["link none tls"] || kv["link none"])}</pre>` : ""}
${kv["link grpc"] ? `VMess gRPC : <pre>${esc(kv["link grpc"])}</pre>` : ""}
`.trim();
  return html;
}

export function renderVLess(block) {
  const kv = typeof block === "string" ? kvParse(block) : block;
  const html = `
<b>VLESS ACCOUNT</b>

<b>>> DETAILS <<</b>
Remarks     : <code>${esc(kv["remarks"] || "")}</code>
id (UUID)   : <code>${esc(kv["id"] || kv["uuid"] || "")}</code>
Encryption  : <code>${esc(kv["encryption"] || "none")}</code>
Expired On  : <code>${esc(kv["expired on"] || kv["expired date"] || kv["expire"] || "")}</code>

<b>>> CONNECTION <<</b>
Domain/Host : <code>${esc(kv["domain"] || kv["domain/host"] || kv["host"] || kv["host/ip"] || "")}</code>
Network     : <code>${esc(kv["network"] || "ws/grpc")}</code>
Path (WS)   : <code>${esc(kv["path"] || kv["path (ws)"] || "/vless")}</code>
gRPC Name   : <code>${esc(kv["grpc name"] || kv["servicename"] || kv["service name"] || "vless-grpc")}</code>
Port TLS    : <code>${esc(kv["port tls"] || kv["tls"] || "")}</code>
Port none   : <code>${esc(kv["port none tls"] || kv["port none"] || kv["none"] || "")}</code>

<b>>> LINKS <<</b>
${kv["link tls"] ? `VLess TLS : <pre>${esc(kv["link tls"])}</pre>` : ""}
${kv["link none tls"] || kv["link none"] ? `VLess none TLS : <pre>${esc(kv["link none tls"] || kv["link none"])}</pre>` : ""}
${kv["link grpc"] ? `VLess gRPC : <pre>${esc(kv["link grpc"])}</pre>` : ""}
`.trim();
  return html;
}

export function renderTrojan(block) {
  const kv = typeof block === "string" ? kvParse(block) : block;
  const html = `
<b>TROJAN ACCOUNT</b>

<b>>> DETAILS <<</b>
Remarks     : <code>${esc(kv["remarks"] || "")}</code>
Key         : <code>${esc(kv["key"] || kv["password"] || "")}</code>
Expired On  : <code>${esc(kv["expired on"] || kv["expired date"] || kv["expire"] || "")}</code>

<b>>> CONNECTION <<</b>
Host/IP     : <code>${esc(kv["host/ip"] || kv["host"] || kv["domain"] || "")}</code>
Path        : <code>${esc(kv["path"] || "/trojan-ws")}</code>
ServiceName : <code>${esc(kv["servicename"] || kv["service name"] || kv["grpc name"] || "trojan-grpc")}</code>
Port TLS    : <code>${esc(kv["port tls"] || kv["tls"] || "")}</code>
Port none   : <code>${esc(kv["port none tls"] || kv["port none"] || kv["none"] || "")}</code>
Port gRPC   : <code>${esc(kv["port grpc"] || kv["grpc"] || "")}</code>

<b>>> LINKS <<</b>
${kv["link tls"] ? `Trojan TLS : <pre>${esc(kv["link tls"])}</pre>` : ""}
${kv["link none tls"] || kv["link none"] ? `Trojan none TLS : <pre>${esc(kv["link none tls"] || kv["link none"])}</pre>` : ""}
${kv["link grpc"] ? `Trojan gRPC : <pre>${esc(kv["link grpc"])}</pre>` : ""}
`.trim();
  return html;
}

export function renderSSWS(block) {
  const kv = typeof block === "string" ? kvParse(block) : block;
  const html = `
<b>SHADOWSOCKS ACCOUNT</b>

<b>>> DETAILS <<</b>
Remarks     : <code>${esc(kv["remarks"] || "")}</code>
Password    : <code>${esc(kv["password"] || kv["key"] || "")}</code>
Ciphers     : <code>${esc(kv["ciphers"] || kv["cipher"] || kv["method"] || "")}</code>

<b>>> CONNECTION <<</b>
Domain/Host : <code>${esc(kv["domain"] || kv["domain/host"] || kv["host"] || kv["host/ip"] || "")}</code>
Network     : <code>${esc(kv["network"] || "ws/grpc")}</code>
Path        : <code>${esc(kv["path"] || "/ss-ws")}</code>
ServiceName : <code>${esc(kv["servicename"] || kv["service name"] || kv["grpc name"] || "ss-grpc")}</code>
Port TLS    : <code>${esc(kv["port tls"] || kv["tls"] || "")}</code>
Port none   : <code>${esc(kv["port none tls"] || kv["port none"] || kv["none"] || "")}</code>
Port gRPC   : <code>${esc(kv["port grpc"] || kv["grpc"] || "")}</code>

<b>>> LINKS <<</b>
${kv["link tls"] ? `SS TLS : <pre>${esc(kv["link tls"])}</pre>` : ""}
${kv["link none tls"] || kv["link none"] ? `SS none TLS : <pre>${esc(kv["link none tls"] || kv["link none"])}</pre>` : ""}
${kv["link grpc"] ? `SS gRPC : <pre>${esc(kv["link grpc"])}</pre>` : ""}
`.trim();
  return html;
}

/** parser generik dari raw → block → html+kv */
export function parseTrial(raw, type) {
  const block = extractAccountBlock(raw);
  const kv = kvParse(block);
  let html;
  switch (type) {
    case "vmess": html = renderVMess(kv); break;
    case "vless": html = renderVLess(kv); break;
    case "trojan": html = renderTrojan(kv); break;
    case "ssws": html = renderSSWS(kv); break;
    default: html = `<pre>${esc(block)}</pre>`;
  }
  return { kv, block, html };
}

