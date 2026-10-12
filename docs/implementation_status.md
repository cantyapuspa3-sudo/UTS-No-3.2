# Status Implementasi

## Sudah ditulis di repository

- Integrasi frontend dengan Supabase Auth dan RPC; tidak ada service-role key.
- Migrasi SQL ber-prefiks `auditguard_`: tabel, constraints, RLS, RPC create/update/post/reverse/verify, checksum SHA-256, dan trigger proteksi.
- Test smoke SQL transaksional yang melakukan rollback.
- README serta dokumentasi desain, keamanan, dan test plan.

## Sudah berhasil diuji

- `node --check` pada `supabase/auditguard.js` dan `supabase/config.js`.
- Parser Node `vm.Script` untuk dua blok JavaScript inline pada HTML.
- Browser lokal tanpa config: form/login nonaktif, pesan konfigurasi Supabase tampil, tabel/halaman tetap dimuat.
- Project Supabase yang dikonfigurasi merespons HTTP 200 dari Auth endpoint; pembacaan sesi tanpa login berhasil.
- Query read-only ke `auditguard_journal_headers` mengembalikan PGRST205 karena tabel belum ada pada schema cache.
- Belum ada tes transaksi/integritas pada Supabase.

## Belum diuji

- Eksekusi sintaks migrasi pada versi PostgreSQL project Supabase aktual.
- RPC dan trigger terhadap JWT serta role Supabase Auth.
- RLS untuk maker, approver, admin, serta akses anon.
- Login/transaksi frontend dengan akun Supabase aktif.
- Uji race/reversal bersamaan, permission lintas project, dan deployment.

## Tindakan yang masih diperlukan

1. Pastikan project Supabase terhubung adalah project development/staging yang dimaksud.
2. Tinjau dan terapkan migrasi secara manual setelah konfirmasi.
3. Buat akun Auth dan tetapkan peran melalui Dashboard/SQL Editor.
4. Jalankan smoke test dan rencana test; catat hasil aktual.
5. Periksa aturan security advisor Supabase dan setting Auth sebelum deploy.

## Fitur/rancangan terbatas

- Belum ada UI untuk membuat/mengubah akun atau mengatur role.
- Form submit membuat DRAFT; tindakan posting tersedia bagi approver/admin.
- `auditguard_update_draft` tersedia di database, tetapi belum ada tombol edit draft pada UI.
- Hanya satu reversal per jurnal asal.
- Belum ada hash chain, notifikasi, deployment pipeline, atau environment terpisah yang terkonfigurasi.
- Pemilik database/service role tetap dapat melewati kontrol database.
