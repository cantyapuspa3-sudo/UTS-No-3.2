# Desain Keamanan AuditGuard

## Autentikasi dan otorisasi

Frontend memakai Supabase Auth email/password. Token sesi dikelola Supabase JS client. Identitas fungsi database berasal dari `auth.uid()`; browser tidak mengirim `created_by`/`posted_by`. Role aplikasi berada di `auditguard_user_roles` dan hanya dikelola pengelola project melalui Dashboard/SQL Editor.

Peran:

- `maker`: membuat draft dan membaca transaksi sendiri.
- `approver`: membaca transaksi semua pengguna, posting, membalik, dan verifikasi.
- `admin`: hak approver ditambah pengelolaan role oleh operator melalui project.

## Pembatasan mutasi

RLS dan GRANT mencabut DML langsung kepada role API `authenticated`/`anon`. Fungsi RPC memvalidasi role dan pemilik. Trigger menolak modifikasi/penghapusan header `POSTED` dan segala perubahan detail POSTED; perubahan status langsung ke POSTED pun memerlukan role approver dan lulus validasi detail/checksum. Foreign key tidak memakai cascade.

Fungsi `SECURITY DEFINER` mengatur `search_path` kosong, merujuk objek dengan nama schema, dan hak execute dibatasi. Jangan memberikan izin perubahan role kepada pengguna aplikasi.

## Konfigurasi dan secret

`supabase/config.js` memuat Project URL dan anon/public key, yang memang digunakan di frontend dan harus dibatasi oleh RLS. File ini tidak boleh berisi service-role key, password database, atau secret. Supabase CDN memerlukan internet.

## Batas model ancaman

Kontrol melindungi terhadap pengguna aplikasi biasa dan permintaan API langsung dengan JWT pengguna. Kontrol ini tidak melindungi dari pemilik project/database, superuser, service role, atau operator yang dapat menonaktifkan trigger, mengubah fungsi, tabel, role, maupun hash. Hash biasa juga bukan HMAC atau hash chain dan tidak menyediakan non-repudiation. Batasi akses Dashboard, aktifkan MFA untuk admin, gunakan backup/PITR, dan audit tindakan operator.

## Operasional

Migrasi harus ditinjau lalu dijalankan manual di project non-produksi. Siapkan backup sebelum produksi. Tes harus memakai akun/DB khusus, dan selalu periksa bahwa skrip tes mengakhiri operasi dengan rollback.
