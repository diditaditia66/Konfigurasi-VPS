(() => {
  const $ = sel => document.querySelector(sel);
  const output = $("#output");
  const loginCard = $("#loginCard");
  const appArea = $("#appArea");
  const whoami = $("#whoami");
  const loader = $("#loader");
  const toastEl = $("#appToast");
  const toast = new bootstrap.Toast(toastEl);
  const toastMsg = $("#toastMsg");
  const modalPwdEl = $("#modalPwd");
  const modalPwd = new bootstrap.Modal(modalPwdEl);

  // helpers
  const setLoading = v => loader.classList.toggle("d-none", !v);
  const showToast = (msg) => { toastMsg.textContent = msg; toast.show(); };
  const appendOut = (txt) => { output.textContent += (txt.endsWith("\n") ? txt : txt + "\n"); output.scrollTop = output.scrollHeight; };
  const setToken = (t) => t ? localStorage.setItem("token", t) : localStorage.removeItem("token");
  const getToken = () => localStorage.getItem("token");

  const authHeaders = () => {
    const h = { "Content-Type": "application/json" };
    const t = getToken();
    if (t) h["Authorization"] = "Bearer " + t;
    return h;
  };

  const call = async (path, body = {}) => {
    setLoading(true);
    try {
      const res = await fetch(path, {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify(body)
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data?.error || res.statusText);
      return data;
    } finally {
      setLoading(false);
    }
  };

  const toLoggedIn = (user) => {
    loginCard.classList.add("d-none");
    appArea.classList.remove("d-none");
    $("#btnLogout").classList.remove("d-none");
    $("#btnChangePwd").classList.remove("d-none");
    whoami.classList.remove("d-none");
    whoami.textContent = `login sebagai: ${user}`;
  };
  const toLoggedOut = () => {
    loginCard.classList.remove("d-none");
    appArea.classList.add("d-none");
    $("#btnLogout").classList.add("d-none");
    $("#btnChangePwd").classList.add("d-none");
    whoami.classList.add("d-none");
    whoami.textContent = "";
    setToken(null);
  };

  // auto restore session (ping /api/me)
  (async () => {
    if (!getToken()) return;
    try {
      const res = await fetch("/api/me", { headers: authHeaders() });
      if (!res.ok) throw 0;
      const me = await res.json();
      toLoggedIn(me.username || "admin");
    } catch { toLoggedOut(); }
  })();

  // login
  $("#loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const username = $("#username").value.trim();
    const password = $("#password").value;
    try {
      const data = await call("/api/login", { username, password });
      setToken(data.token);
      toLoggedIn(username);
      showToast("Login sukses");
    } catch (err) {
      showToast("Gagal login: " + err.message);
    }
  });

  // logout
  $("#btnLogout").addEventListener("click", async () => {
    try { await call("/api/logout", {}); } catch {}
    toLoggedOut();
  });

  // change password
  $("#btnChangePwd").addEventListener("click", () => modalPwd.show());
  $("#pwdForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const p1 = $("#newPwd").value;
    const p2 = $("#newPwd2").value;
    if (p1 !== p2) { showToast("Password tidak sama"); return; }
    try {
      await call("/api/change-password", { newPassword: p1 });
      modalPwd.hide(); showToast("Password diganti");
      $("#newPwd").value = ""; $("#newPwd2").value = "";
    } catch (err) { showToast("Gagal ganti password: " + err.message); }
  });

  // buttons Trial
  document.querySelectorAll("[data-action^='trial-']").forEach(btn => {
    btn.addEventListener("click", async () => {
      const type = btn.dataset.action.replace("trial-", ""); // ssh|vmess|vless|trojan|ss
      appendOut(`$ trial ${type} ...`);
      try {
        const res = await call(`/api/trial/${type}`, {});
        appendOut(res.output || "(no output)");
        showToast(`Trial ${type} selesai`);
      } catch (err) {
        appendOut("ERROR: " + err.message);
        showToast(`Trial ${type} gagal`);
      }
    });
  });

  // Add VMess/VLess/Trojan/SS
  document.querySelectorAll("[data-action^='add-']").forEach(btn => {
    if (btn.dataset.action === "add-ss") return; // ditangani sama ini juga
    btn.addEventListener("click", async (e) => {
      e.preventDefault();
      const type = btn.dataset.action.replace("add-", ""); // vmess|vless|trojan
      const remarks = $("#remarks").value.trim();
      const days = parseInt($("#days").value || "30", 10);
      if (!remarks) return showToast("Remarks tidak boleh kosong");
      appendOut(`$ add ${type} ${remarks} ${days}d ...`);
      try {
        const res = await call(`/api/add/${type}`, { remarks, days });
        appendOut(res.output || "(no output)");
        showToast(`Add ${type} OK`);
      } catch (err) {
        appendOut("ERROR: " + err.message);
        showToast(`Add ${type} gagal`);
      }
    });
  });

  // Add SSH
  $("#btnAddSsh").addEventListener("click", async (e) => {
    e.preventDefault();
    const username = $("#sshUser").value.trim();
    const password = $("#sshPass").value;
    const days = parseInt($("#sshDays").value || "30", 10);
    if (!username || !password) return showToast("Username/password SSH kosong");
    appendOut(`$ add ssh ${username} ${days}d ...`);
    try {
      const res = await call(`/api/add/ssh`, { username, password, days });
      appendOut(res.output || "(no output)");
      showToast(`Add SSH OK`);
    } catch (err) {
      appendOut("ERROR: " + err.message);
      showToast(`Add SSH gagal`);
    }
  });

  // utilities UI
  $("#btnCopy").addEventListener("click", async () => {
    await navigator.clipboard.writeText(output.textContent || "");
    showToast("Disalin ke clipboard");
  });
  $("#btnClear").addEventListener("click", () => { output.textContent = ""; });

  // toggles
  $("#togglePass").addEventListener("click", () => {
    const inp = $("#password"); const t = inp.type === "password" ? "text" : "password"; inp.type = t;
  });
  $("#toggleSshPass").addEventListener("click", () => {
    const inp = $("#sshPass"); inp.type = inp.type === "password" ? "text" : "password";
  });
})();

