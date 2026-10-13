# AuditGuard - Kas Keluar

Link Demo Web App:https://cantyapuspa3-sudo.github.io/UTS-No-3.2/web_app_utk_UTS.html

## Akun Demo Aplikasi

Gunakan akun berikut untuk login dan menguji aplikasi **AuditGuard – Kas Keluar**.

| Role | Email | Password |
|---|---|---|
| Approver | `cantyapuspa3@gmail.com` | `inicumaujian` |
| Maker | `clafiee@gmail.com` | `inicumaujian` |
- **Maker:** Membuat draft jurnal transaksi.
- **Approver:** Memeriksa dan melakukan posting jurnal sesuai kewenangan.

AuditGuard adalah aplikasi entri voucher kas keluar untuk latihan pemeriksaan auditor internal. Frontend HTML mengirim transaksi ke Supabase; PostgreSQL memvalidasi jurnal, mencatat metadata, membatasi akses, mengunci transaksi yang telah diposting, dan menyediakan reversing entry serta pemeriksaan checksum.

## Fitur

- Formulir voucher, akun, detail debit/kredit, dan pemeriksaan keseimbangan di browser.
- Penyimpanan permanen voucher berstatus `DRAFT` di PostgreSQL.
- Posting hanya oleh pengguna dengan peran `approver` atau `admin`.
- Trigger yang melindungi header dan detail `POSTED`.
- Reversing entry baru dengan tautan ke jurnal asal; satu pembalikan per jurnal asal.
- `created_by` dari Supabase Auth, `created_at` dari waktu database, dan checksum SHA-256.
- Verifikasi checksum dan riwayat yang dibatasi RLS.

## Arsitektur dan Teknologi

- Frontend: HTML, Tailwind CDN, JavaScript, Supabase JavaScript client v2.
- Backend: fungsi RPC PostgreSQL `SECURITY DEFINER`, trigger, constraint, dan Row Level Security.
- Identitas: Supabase Auth email/password.
- Database: PostgreSQL di Supabase.
- Tidak ada service-role key di browser. `anon key` bersifat publik dan dibatasi RLS.

## Struktur Folder

```text
.
|-- web_app_utk_UTS.html
|-- README.md
|-- supabase
|   |-- auditguard.js
|   |-- config.example.js
|   |-- config.js
|   |-- migrations
|   |   `-- 001_auditguard_schema_and_controls.sql
|   `-- tests
|       `-- audit_trail_smoke_test.sql
`-- docs
    |-- 03_2_audit_trail_immutability.md
    |-- database_design.md
    |-- implementation_status.md
    |-- security_design.md
    `-- test_plan.md
```

## Prasyarat

- Project Supabase yang dapat dibuang/dipakai untuk pengujian, bukan database produksi.
- Python 3 untuk server file statis lokal (atau web server lokal lain).
- Koneksi internet untuk CDN Supabase JS, Tailwind, ikon, dan font.
- Akun pengguna yang dibuat melalui Supabase Auth.

## Menyiapkan Supabase

1. Frontend repository ini telah dikonfigurasi ke project Supabase yang diberikan. Pastikan project tersebut memang project development/pengujian sebelum menerapkan skema.
2. Tinjau SQL di [001_auditguard_schema_and_controls.sql](./supabase/migrations/001_auditguard_schema_and_controls.sql). Migrasi membuat tabel dengan prefix `auditguard_`, tidak menghapus tabel/data lama, dan tidak dijalankan otomatis.
3. Jalankan SQL tersebut secara manual pada SQL Editor project pengujian atau gunakan Supabase CLI setelah project ditautkan. Jangan jalankan pada project produksi tanpa backup dan pemeriksaan.
4. Buat akun melalui **Authentication → Users**. Salin UUID pengguna ke SQL Editor lalu tetapkan perannya. Contoh:

   ```sql
   INSERT INTO public.auditguard_user_roles (user_id, role, display_name)
   VALUES ('00000000-0000-4000-8000-000000000000', 'maker', 'Nama Pengguna')
   ON CONFLICT (user_id) DO UPDATE
   SET role = EXCLUDED.role, display_name = EXCLUDED.display_name;
   ```

   Pilihan peran: `maker`, `approver`, atau `admin`. Pembuatan/penetapan admin sebaiknya dilakukan terbatas melalui Dashboard/SQL Editor oleh pengelola project.
5. `supabase/config.js` sudah berisi URL project dan publishable key yang diberikan. Nilai ini bersifat publik dan dipakai di browser. Untuk menghubungkan project lain, salin `supabase/config.example.js` dan isi Project URL serta **anon/public key** dari **Project Settings → API**:

   ```js
   window.AUDITGUARD_SUPABASE_CONFIG = {
       url: "https://YOUR_PROJECT_ID.supabase.co",
       anonKey: "YOUR_SUPABASE_ANON_KEY"
   };
   ```

   `config.js` hanya berisi nilai publik. Jangan masukkan `service_role`, password database, atau secret lain.

## Menjalankan Frontend

Dari folder proyek:

```powershell
python -m http.server 8000
```

Buka `http://localhost:8000/web_app_utk_UTS.html`, lalu masuk memakai akun Supabase Auth yang sudah diberi peran. Halaman HTML tidak sebaiknya dibuka langsung dengan `file://` karena pemuatan konfigurasi dan CDN perlu berjalan melalui web server.

Form submit membuat voucher `DRAFT`. Approver/admin dapat mem-posting; setelah `POSTED`, header dan detail terkunci. Approver/admin juga dapat memverifikasi checksum atau membuat satu reversing entry baru berstatus `DRAFT`.

## Pengujian

- Test integrasi SQL tersedia di [audit_trail_smoke_test.sql](./supabase/tests/audit_trail_smoke_test.sql). Jalankan hanya di project pengujian setelah ada akun berperan maker dan approver/admin. Skrip menggunakan transaksi lalu `ROLLBACK`.
- Test cases, status aktual, dan langkah manual ada di [test_plan.md](./docs/test_plan.md).
- Dokumentasi rancangan: [03_2_audit_trail_immutability.md](./docs/03_2_audit_trail_immutability.md), [database_design.md](./docs/database_design.md), [security_design.md](./docs/security_design.md), dan [implementation_status.md](./docs/implementation_status.md).

## Status dan Batasan

Frontend sudah dikonfigurasi ke project Supabase yang diberikan. Auth endpoint merespons HTTP 200 dan pembacaan sesi tanpa login berhasil. Query read-only menemukan tabel `auditguard_journal_headers` belum ada pada schema cache (PGRST205), sehingga migrasi belum diterapkan dan penyimpanan voucher belum dapat dipakai. Penerapan migrasi tetap manual setelah peninjauan, lalu akun/role perlu dibuat dan pengujian staging dijalankan.

Hash SHA-256 mendeteksi perubahan data yang dicakup checksum, tetapi bukan tanda tangan yang tahan terhadap pemilik database berhak istimewa yang dapat mengubah tabel dan checksum sekaligus. Hak pemilik/Supabase service role berada di luar perlindungan trigger dan RLS.

## Informasi Akademik

README awal tidak memuat NIM, kelas, atau dosen pengampu. Informasi tersebut tidak ditambahkan agar tidak mengarang data.
