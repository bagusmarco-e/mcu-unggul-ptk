# Website Annual MCU 2026 · PT Unggul Dinamika Utama Site PTK

Website pendaftaran, penjadwalan, absensi scan QR, dan report Annual MCU 2026.

- **Karyawan**: cek jadwal & QR pribadi dengan NIK + tanggal lahir (tanpa login).
- **Admin departemen**: menjadwalkan peserta departemennya, menambah peserta tambahan, mengunduh kartu QR.
- **HR**: scan QR check-in/check-out, kelola akun admin, report PDF & Excel.

Data disimpan di Supabase (PostgreSQL) dengan Row Level Security. Data peserta **tidak** disimpan di repository ini.

- `index.html` – aplikasi web (GitHub Pages)
- `supabase/schema.sql` – struktur database dan aturan akses
