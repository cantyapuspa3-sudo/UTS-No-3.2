# Rencana dan Hasil Pengujian

Status di bawah merekam kondisi saat implementasi dibuat. **NOT RUN** berarti pengujian belum dilakukan; bukan hasil `PASS`.

| ID | Skenario / langkah | Hasil yang diharapkan | Hasil aktual | Status | Bukti |
|---|---|---|---|---|---|
| T00 | Jalankan `node --check` untuk JS frontend dan parse blok script HTML dengan `vm.Script` | Sintaks JS tidak menghasilkan error | Lolos: dua file JS dan dua blok script HTML lolos pemeriksaan sintaks | PASS | Output PowerShell: `Inline HTML script syntax OK (2 script blocks).` |
| T0B | Buka HTML tanpa konfigurasi Supabase di browser | Form submit dan login nonaktif; pesan konfigurasi tampil, halaman tetap termuat | Lolos: browser lokal menampilkan pesan konfigurasi; login dan submit disabled | PASS | Pemeriksaan browser pada `file:///D:/UTS_no3/web_app_utk_UTS.html` |
| T0C | Hubungi Auth endpoint dan baca sesi tanpa login | Endpoint merespons; tidak mengubah data | Lolos: Auth settings HTTP 200; `getSession()` tanpa error dan tidak ada sesi | PASS | GET `/auth/v1/settings` dan pembacaan sesi Supabase JS |
| T0D | Query read-only tabel `auditguard_journal_headers` | Tabel dapat dibaca setelah migrasi | Belum siap: API mengembalikan PGRST205, tabel belum ada di schema cache | BLOCKED | Respons `Could not find the table 'public.auditguard_journal_headers'` |
| T01 | Buat draft seimbang menggunakan maker melalui `auditguard_create_journal` | Header/detail tercatat; `created_by` cocok `auth.uid()`; waktu dari DB; hash 64 hex | Belum dijalankan; migrasi belum diterapkan | NOT RUN | Jalankan smoke test dan simpan output SQL Editor |
| T02 | Kirim jurnal tidak seimbang melalui RPC | RPC menolak dan tidak meninggalkan header/detail | Belum dijalankan | NOT RUN | SQL error dan query verifikasi tidak menemukan voucher |
| T03 | Kirim kode akun yang tidak terdaftar | RPC menolak transaksi | Belum dijalankan | NOT RUN | SQL error COA |
| T04 | Maker mencoba mem-posting draft | RPC menolak otorisasi | Belum dijalankan | NOT RUN | Output error pada smoke test |
| T05 | Approver mem-posting draft seimbang | Status berubah atomik menjadi POSTED; posted_by/time tercatat | Belum dijalankan | NOT RUN | Hasil RPC post |
| T06 | UPDATE/DELETE header POSTED | Trigger menolak, jurnal tetap utuh | Belum dijalankan | NOT RUN | SQL error trigger |
| T07 | INSERT/UPDATE/DELETE detail POSTED | Trigger menolak, jurnal tetap utuh | Belum dijalankan | NOT RUN | SQL error trigger |
| T08 | Buat reversal dari POSTED | Draft baru menukar debit/kredit dan mengisi reverses_id | Belum dijalankan | NOT RUN | Hasil RPC dan pembacaan dua jurnal |
| T09 | Membalik satu jurnal asal untuk kedua kalinya | RPC/unique index menolak | Belum dijalankan | NOT RUN | Error pada percobaan kedua |
| T10 | Ubah detail DRAFT melalui SQL Editor lalu panggil verify | `valid=false` karena hash tersimpan tidak cocok | Belum dijalankan | NOT RUN | JSON respons verify |
| T11 | Pengguna membaca voucher pengguna lain | RLS tidak menampilkan data | Belum dijalankan | NOT RUN | Query sebagai authenticated maker |
| T12 | Konfigurasi Supabase terisi di frontend | Client dibuat; login dapat dilakukan | Client dan Auth endpoint berhasil diakses, tetapi login belum diuji karena akun belum disiapkan | PARTIAL | Tes `getSession()` read-only; buat akun staging untuk tes login |
| T13 | Login maker dan submit form | Draft muncul pada riwayat permanen setelah refresh | Belum dijalankan di browser | NOT RUN | Screenshot dan record staging |
| T14 | Login approver, post/reverse/verify dari tabel | Action sesuai role dan respons server tercermin | Belum dijalankan di browser | NOT RUN | Screenshot dan respons RPC |

## Menjalankan smoke test

1. Buat project Supabase khusus pengujian.
2. Terapkan migrasi secara manual.
3. Buat akun Auth, lalu atur satu role `maker` dan satu `approver`.
4. Jalankan [audit_trail_smoke_test.sql](../supabase/tests/audit_trail_smoke_test.sql) melalui SQL Editor.
5. Pastikan hasil berisi notice `PASS` dan eksekusi berhasil. Skrip melakukan `ROLLBACK`, sehingga record pengujian tidak disimpan.
6. Lengkapi T02, T03, T07 insert/update, RLS, serta tes browser secara terpisah dan dokumentasikan error/output atau screenshot.

Auth read-only sudah terverifikasi pada project yang dikonfigurasi. Migrasi dan alur transaksi belum diuji karena tabel belum ada; tidak ada perubahan data database yang dilakukan.
