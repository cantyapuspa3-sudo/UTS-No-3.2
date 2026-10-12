(function () {
    "use strict";

    const config = window.AUDITGUARD_SUPABASE_CONFIG || {};
    const isConfigured = config.url && config.anonKey
        && !config.url.includes("YOUR_PROJECT_ID")
        && !config.anonKey.includes("YOUR_SUPABASE_ANON_KEY");
    const submitButton = document.getElementById("submit-btn");
    let client = null;
    let currentUser = null;
    let currentRole = null;
    const originalTriggerCalculation = window.triggerCalculation;

    function showStatus(message, type) {
        if (typeof window.showAlert === "function") {
            window.showAlert(message, type);
        }
    }

    function addAuthPanel() {
        const header = document.querySelector("header > div");
        if (!header) return;

        const panel = document.createElement("div");
        panel.id = "supabase-auth-panel";
        panel.className = "mt-3 w-full sm:mt-0 sm:w-auto";
        panel.innerHTML = `
            <form id="supabase-login-form" class="flex flex-wrap items-center justify-end gap-2">
                <input id="supabase-email" type="email" required autocomplete="username"
                    placeholder="Email Supabase"
                    class="w-40 rounded-lg border border-slate-600 bg-slate-800 px-2.5 py-2 text-xs text-white placeholder-slate-400">
                <input id="supabase-password" type="password" required autocomplete="current-password"
                    placeholder="Password"
                    class="w-32 rounded-lg border border-slate-600 bg-slate-800 px-2.5 py-2 text-xs text-white placeholder-slate-400">
                <button type="submit"
                    class="rounded-lg bg-blue-600 px-3 py-2 text-xs font-semibold text-white hover:bg-blue-700">
                    Masuk
                </button>
            </form>
            <div id="supabase-user-panel" class="hidden items-center justify-end gap-2 text-xs">
                <span id="supabase-user-label" class="text-slate-200"></span>
                <button id="supabase-logout" type="button"
                    class="rounded-lg border border-slate-600 px-3 py-2 text-slate-200 hover:bg-slate-800">
                    Keluar
                </button>
            </div>`;
        header.appendChild(panel);

        document.getElementById("supabase-login-form").addEventListener("submit", signIn);
        document.getElementById("supabase-logout").addEventListener("click", signOut);
    }

    async function signIn(event) {
        event.preventDefault();
        const email = document.getElementById("supabase-email").value.trim();
        const password = document.getElementById("supabase-password").value;
        const { error } = await client.auth.signInWithPassword({ email, password });
        if (error) {
            showStatus(`Login gagal: ${error.message}`, "error");
        }
    }

    async function signOut() {
        const { error } = await client.auth.signOut();
        if (error) showStatus(`Gagal keluar: ${error.message}`, "error");
    }

    function setAuthDisplay(user, role, displayName) {
        const loginForm = document.getElementById("supabase-login-form");
        const userPanel = document.getElementById("supabase-user-panel");
        const userLabel = document.getElementById("supabase-user-label");
        if (!loginForm || !userPanel) return;

        loginForm.classList.toggle("hidden", Boolean(user));
        userPanel.classList.toggle("hidden", !user);
        userPanel.classList.toggle("flex", Boolean(user));
        userLabel.textContent = user
            ? `${displayName || user.email} (${role || "tanpa peran"})`
            : "";
    }

    function amountInCents(amount) {
        const [whole, fraction = ""] = String(amount || "0").split(".");
        return BigInt(whole) * 100n + BigInt((fraction + "00").slice(0, 2));
    }

    async function loadHistory() {
        const body = document.getElementById("history-rows");
        body.replaceChildren();
        if (!client || !currentUser) {
            body.appendChild(emptyRow("Login untuk melihat riwayat voucher."));
            return;
        }
        const { data, error } = await client
            .from("auditguard_journal_headers")
            .select(
                "id,voucher_no,voucher_date,payee_name,description,posting_status,created_by,created_at,posted_at,reverses_id,auditguard_journal_lines(account_code,debit,credit)"
            )
            .order("created_at", { ascending: false });

        if (error) {
            body.appendChild(emptyRow(`Gagal memuat riwayat: ${error.message}`));
            return;
        }
        if (!data || data.length === 0) {
            body.appendChild(emptyRow("Belum ada voucher pada akun ini."));
            return;
        }

        data.forEach((record) => body.appendChild(historyRow(record)));
    }

    function emptyRow(message) {
        const row = document.createElement("tr");
        const cell = document.createElement("td");
        cell.colSpan = 8;
        cell.className = "p-4 text-center text-slate-400 italic";
        cell.textContent = message;
        row.appendChild(cell);
        return row;
    }

    function historyRow(record) {
        const row = document.createElement("tr");
        row.className = "transition hover:bg-slate-50";
        const totalCents = (record.auditguard_journal_lines || []).reduce(
            (sum, line) => sum + amountInCents(line.debit),
            0n
        );
        const total = (totalCents + 50n) / 100n;
        const createdAt = new Date(record.created_at).toLocaleString("id-ID");
        const values = [
            [record.voucher_no, "p-3 font-semibold text-blue-600"],
            [record.voucher_date, "p-3"],
            [record.payee_name, "p-3 font-medium text-slate-800"],
            [record.description, "p-3 text-slate-600"],
            [
                new Intl.NumberFormat("id-ID", {
                    style: "currency",
                    currency: "IDR",
                    minimumFractionDigits: 0
                }).format(total),
                "p-3 text-right font-mono font-semibold"
            ],
            [record.posting_status, "p-3 text-center font-semibold"],
            [`${record.created_by} (${createdAt})`, "p-3 text-slate-500"]
        ];

        values.forEach(([value, className]) => {
            const cell = document.createElement("td");
            cell.className = className;
            cell.textContent = value;
            row.appendChild(cell);
        });

        const actionCell = document.createElement("td");
        actionCell.className = "p-3";
        if (currentRole === "approver" || currentRole === "admin") {
            if (record.posting_status === "DRAFT") {
                actionCell.appendChild(actionButton("Posting", () => postJournal(record.id)));
            } else {
                actionCell.appendChild(actionButton("Verifikasi", () => verifyJournal(record.id)));
                const reverseButton = actionButton("Balik", () => reverseJournal(record.id));
                reverseButton.classList.add("ml-1");
                actionCell.appendChild(reverseButton);
            }
        } else {
            actionCell.textContent = "—";
        }
        row.appendChild(actionCell);
        return row;
    }

    function actionButton(label, callback) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = label;
        button.className = "rounded border border-slate-300 px-2 py-1 text-[10px] font-semibold hover:bg-slate-100";
        button.addEventListener("click", callback);
        return button;
    }

    async function postJournal(id) {
        const { error } = await client.rpc("auditguard_post_journal", {
            p_journal_id: id
        });
        if (error) {
            showStatus(`Posting ditolak: ${error.message}`, "error");
            return;
        }
        showStatus("Voucher berhasil diposting dan dikunci.", "success");
        await loadHistory();
    }

    async function verifyJournal(id) {
        const { data, error } = await client.rpc("auditguard_verify_journal", {
            p_journal_id: id
        });
        if (error) {
            showStatus(`Verifikasi gagal: ${error.message}`, "error");
            return;
        }
        showStatus(
            data.valid
                ? "Checksum valid; data sesuai dengan saat dicatat."
                : "PERINGATAN: checksum berbeda. Perlu pemeriksaan audit.",
            data.valid ? "success" : "error"
        );
    }

    async function reverseJournal(id) {
        const voucherNo = window.prompt("Masukkan nomor voucher baru untuk jurnal pembalik:");
        if (voucherNo === null) return;
        if (!voucherNo.trim()) {
            showStatus("Nomor voucher pembalik wajib diisi.", "error");
            return;
        }

        const now = new Date();
        const reversalDate = [
            now.getFullYear(),
            String(now.getMonth() + 1).padStart(2, "0"),
            String(now.getDate()).padStart(2, "0")
        ].join("-");
        const { error } = await client.rpc("auditguard_reverse_journal", {
            p_journal_id: id,
            p_reversal_voucher_no: voucherNo.trim(),
            p_reversal_date: reversalDate
        });
        if (error) {
            showStatus(`Pembalikan ditolak: ${error.message}`, "error");
            return;
        }
        showStatus("Jurnal pembalik tersimpan sebagai DRAFT.", "success");
        await loadHistory();
    }

    async function submitVoucher(event) {
        event.preventDefault();
        if (!client || !currentUser) {
            showStatus("Login dan konfigurasi Supabase diperlukan untuk menyimpan voucher.", "error");
            return;
        }

        const totals = window.calculateJournalTotals();
        if (!totals.isEveryRowValid || totals.totalDebit !== totals.totalKredit
            || totals.totalDebit <= 0) {
            showStatus("Jurnal belum seimbang atau terdapat baris yang belum lengkap.", "error");
            return;
        }

        const rows = Array.from(document.querySelectorAll("#journal-rows tr"));
        const lines = rows.map((row) => ({
            account_code: row.querySelector('[id$="-acc"]').value,
            description: row.querySelector('[id$="-desc"]').value,
            debit: row.querySelector('[id$="-debit"]').value || "0",
            credit: row.querySelector('[id$="-kredit"]').value || "0"
        }));
        const { data, error } = await client.rpc("auditguard_create_journal", {
            p_voucher_no: document.getElementById("voucher_no").value.trim(),
            p_voucher_date: document.getElementById("voucher_date").value,
            p_payee_name: document.getElementById("payee_name").value.trim(),
            p_description: document.getElementById("voucher_desc").value.trim(),
            p_lines: lines
        });

        if (error) {
            showStatus(`Voucher gagal disimpan: ${error.message}`, "error");
            return;
        }
        showStatus(
            `Voucher ${data.voucher_no} tersimpan sebagai DRAFT. Posting memerlukan approver.`,
            "success"
        );
        await loadHistory();
        window.resetForm();
    }

    function resetVoucherForm() {
        document.getElementById("voucher_no").value =
            `VCR-KK-${new Date().getFullYear()}-${Date.now()}`;
        document.getElementById("payee_name").value = "";
        document.getElementById("voucher_desc").value = "";
        document.getElementById("journal-rows").replaceChildren();
        window.appendRow("", "", 0, 0);
        window.triggerCalculation();
    }

    async function initializeUser(session) {
        currentUser = session ? session.user : null;
        currentRole = null;
        let displayName = "";

        if (currentUser) {
            const { data: roleData, error } = await client
                .from("auditguard_user_roles")
                .select("role,display_name")
                .eq("user_id", currentUser.id)
                .maybeSingle();
            if (error) {
                showStatus(`Gagal membaca peran pengguna: ${error.message}`, "error");
            } else if (roleData) {
                currentRole = roleData.role;
                displayName = roleData.display_name;
            }
        }

        setAuthDisplay(currentUser, currentRole, displayName);
        document.getElementById("current-user-display").textContent = currentUser
            ? (displayName || currentUser.email)
            : "Belum login";
        window.triggerCalculation();

        if (currentUser && !currentRole) {
            showStatus("Akun ini belum diberi peran AuditGuard oleh administrator.", "error");
        }
        await loadHistory();
    }

    function disableHistoryClear() {
        const button = document.querySelector("button[onclick='clearAuditHistory()']");
        if (button) {
            button.disabled = true;
            button.title = "Arsip database tidak dapat dihapus dari antarmuka.";
            button.innerHTML = '<i class="fa-solid fa-lock mr-1"></i> Arsip Terkunci';
            button.classList.add("cursor-not-allowed", "opacity-50");
        }
    }

    window.handleFormSubmit = submitVoucher;
    window.renderAuditHistory = loadHistory;
    window.resetForm = resetVoucherForm;
    window.triggerCalculation = function () {
        originalTriggerCalculation();
        if (!isConfigured || !currentUser || !currentRole) {
            submitButton.disabled = true;
            submitButton.classList.add("opacity-50", "cursor-not-allowed");
        }
    };
    window.clearAuditHistory = function () {
        showStatus("Arsip audit tersimpan permanen dan tidak dapat dibersihkan dari aplikasi.", "error");
    };

    addAuthPanel();
    disableHistoryClear();
    const modeBadge = document.querySelector("header .bg-emerald-500\\/20");
    if (modeBadge) modeBadge.innerHTML = '<i class="fa-solid fa-shield-halved mr-1"></i> Supabase Auth';

    if (!isConfigured || !window.supabase) {
        if (submitButton) submitButton.disabled = true;
        document.querySelectorAll("#supabase-login-form input, #supabase-login-form button")
            .forEach((element) => {
                element.disabled = true;
            });
        window.setTimeout(() => {
            showStatus(
                "Konfigurasikan Supabase di supabase/config.js, lalu muat ulang halaman.",
                "error"
            );
        }, 100);
        return;
    }

    client = window.supabase.createClient(config.url, config.anonKey);
    client.auth.onAuthStateChange((_event, session) => {
        window.setTimeout(() => initializeUser(session), 0);
    });
    client.auth.getSession().then(({ data, error }) => {
        if (error) {
            showStatus(`Gagal membaca sesi login: ${error.message}`, "error");
            return;
        }
        initializeUser(data.session);
    });
})();
