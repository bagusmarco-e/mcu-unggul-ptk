-- =====================================================================
-- Annual MCU 2026 · PT Unggul Dinamika Utama Site PTK
-- Struktur database + aturan akses (Row Level Security)
-- Jalankan sekali di Supabase › SQL Editor
-- =====================================================================

-- ---------- Tabel ----------
create table if not exists public.departemen (
  nama   text primary key,
  target int  not null default 0,
  urut   int  not null default 0
);

create table if not exists public.pengaturan (
  id     int primary key default 1 check (id = 1),
  kuota  int not null default 24,
  target int not null default 373
);

create table if not exists public.profil (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  nama       text,
  peran      text not null default 'menunggu' check (peran in ('menunggu','admin','hr')),
  dept       text references public.departemen(nama) on update cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.peserta (
  nik            text primary key,
  nik_lama       text,
  nama           text not null,
  tgl_lahir      date,
  dept           text not null references public.departemen(nama) on update cascade,
  jabatan        text default '',
  paket          text not null check (paket in ('GW','MC','OP')),
  paket_intibios text default '',
  usia           int  not null check (usia between 15 and 80),
  sumber         text not null default 'Tambahan' check (sumber in ('Data MCU','Tambahan')),
  status         text not null default 'Terdaftar' check (status in ('Terdaftar','Hadir','Selesai','Tidak hadir')),
  hari           text check (hari in ('2','3','4','5')),
  gel            text check (gel in ('1','2','3','4')),
  catatan        text default '',
  check_in_at    timestamptz,
  check_out_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  constraint jadwal_lengkap check ((hari is null) = (gel is null))
);
create index if not exists peserta_dept_idx on public.peserta(dept);
create index if not exists peserta_jadwal_idx on public.peserta(hari, gel);
create index if not exists peserta_nik_lama_idx on public.peserta(nik_lama);

create table if not exists public.log_scan (
  id      bigint generated always as identity primary key,
  nik     text not null,
  aksi    text not null check (aksi in ('check-in','check-out')),
  at      timestamptz not null default now(),
  oleh    uuid default auth.uid()
);

-- ---------- Fungsi bantu ----------
create or replace function public.peran_saya() returns text
language sql stable security definer set search_path = public as
$$ select peran from public.profil where user_id = auth.uid() $$;

create or replace function public.dept_saya() returns text
language sql stable security definer set search_path = public as
$$ select dept from public.profil where user_id = auth.uid() $$;

create or replace function public.is_hr() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select peran = 'hr' from public.profil where user_id = auth.uid()), false) $$;

-- updated_at otomatis
create or replace function public.set_updated() returns trigger
language plpgsql as $$ begin new.updated_at = now(); new.updated_by = auth.uid(); return new; end $$;
drop trigger if exists peserta_updated on public.peserta;
create trigger peserta_updated before update on public.peserta for each row execute function public.set_updated();

-- Kuota gelombang dijaga di database (bukan hanya di tampilan)
create or replace function public.cek_kuota() returns trigger
language plpgsql security definer set search_path = public as $$
declare k int; n int;
begin
  if new.hari is null or (tg_op = 'UPDATE' and old.hari is not distinct from new.hari and old.gel is not distinct from new.gel) then
    return new;
  end if;
  select kuota into k from public.pengaturan where id = 1;
  select count(*) into n from public.peserta
   where hari = new.hari and gel = new.gel and nik <> new.nik and status <> 'Tidak hadir';
  if n >= coalesce(k, 24) then
    raise exception 'Kuota gelombang % hari % sudah penuh (% orang)', new.gel, new.hari, k;
  end if;
  return new;
end $$;
drop trigger if exists peserta_kuota on public.peserta;
create trigger peserta_kuota before insert or update on public.peserta for each row execute function public.cek_kuota();

-- Admin departemen tidak boleh mengubah kehadiran / sumber data
create or replace function public.jaga_kolom() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_hr() or auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then
    new.status := old.status; new.check_in_at := old.check_in_at; new.check_out_at := old.check_out_at;
    new.sumber := old.sumber; new.nik := old.nik;
  else
    new.status := 'Terdaftar'; new.check_in_at := null; new.check_out_at := null; new.sumber := 'Tambahan';
  end if;
  return new;
end $$;
drop trigger if exists peserta_jaga on public.peserta;
create trigger peserta_jaga before insert or update on public.peserta for each row execute function public.jaga_kolom();

-- Profil dibuat otomatis saat akun baru mendaftar (peran: menunggu persetujuan HR)
create or replace function public.akun_baru() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profil(user_id, email, nama)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'nama', split_part(new.email,'@',1)))
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.akun_baru();

-- ---------- Cek jadwal publik (tanpa login): NIK + tanggal lahir ----------
create or replace function public.cek_jadwal(p_nik text, p_tgl date)
returns table (nik text, nama text, dept text, jabatan text, paket text, usia int, hari text, gel text,
               status text, check_in_at timestamptz, check_out_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.nik, p.nama, p.dept, p.jabatan, p.paket, p.usia, p.hari, p.gel, p.status, p.check_in_at, p.check_out_at
    from public.peserta p
   where (p.nik = trim(p_nik) or p.nik_lama = trim(p_nik)) and p.tgl_lahir = p_tgl
   limit 1
$$;

-- ---------- Scan QR (HR): check-in / check-out dalam satu langkah ----------
create or replace function public.scan(p_kode text, p_aksi text)
returns table (hasil text, nik text, nama text, dept text, paket text, usia int, hari text, gel text,
               check_in_at timestamptz, check_out_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare r public.peserta%rowtype; k text;
begin
  if not public.is_hr() then raise exception 'Hanya HR yang dapat mencatat absensi'; end if;
  k := trim(regexp_replace(p_kode, '^MCU26[:|]', '', 'i'));
  select * into r from public.peserta pp where pp.nik = k or pp.nik_lama = k limit 1;
  if not found then
    return query select 'tidak_ditemukan'::text, k, null::text, null::text, null::text, null::int, null::text, null::text, null::timestamptz, null::timestamptz;
    return;
  end if;
  if p_aksi = 'check-in' then
    if r.check_in_at is not null then
      return query select 'sudah'::text, r.nik, r.nama, r.dept, r.paket, r.usia, r.hari, r.gel, r.check_in_at, r.check_out_at; return;
    end if;
    update public.peserta set check_in_at = now(), status = 'Hadir' where peserta.nik = r.nik returning * into r;
  elsif p_aksi = 'check-out' then
    if r.check_in_at is null then
      return query select 'belum_masuk'::text, r.nik, r.nama, r.dept, r.paket, r.usia, r.hari, r.gel, r.check_in_at, r.check_out_at; return;
    end if;
    if r.check_out_at is not null then
      return query select 'sudah'::text, r.nik, r.nama, r.dept, r.paket, r.usia, r.hari, r.gel, r.check_in_at, r.check_out_at; return;
    end if;
    update public.peserta set check_out_at = now(), status = 'Selesai' where peserta.nik = r.nik returning * into r;
  else
    raise exception 'Aksi tidak dikenal';
  end if;
  insert into public.log_scan(nik, aksi) values (r.nik, p_aksi);
  return query select 'ok'::text, r.nik, r.nama, r.dept, r.paket, r.usia, r.hari, r.gel, r.check_in_at, r.check_out_at;
end $$;

-- ---------- Row Level Security ----------
alter table public.departemen enable row level security;
alter table public.pengaturan enable row level security;
alter table public.profil     enable row level security;
alter table public.peserta    enable row level security;
alter table public.log_scan   enable row level security;

drop policy if exists dept_baca on public.departemen;
create policy dept_baca on public.departemen for select to anon, authenticated using (true);
drop policy if exists dept_tulis on public.departemen;
create policy dept_tulis on public.departemen for all to authenticated using (public.is_hr()) with check (public.is_hr());

drop policy if exists atur_baca on public.pengaturan;
create policy atur_baca on public.pengaturan for select to anon, authenticated using (true);
drop policy if exists atur_tulis on public.pengaturan;
create policy atur_tulis on public.pengaturan for all to authenticated using (public.is_hr()) with check (public.is_hr());

drop policy if exists profil_baca on public.profil;
create policy profil_baca on public.profil for select to authenticated using (user_id = auth.uid() or public.is_hr());
drop policy if exists profil_hr on public.profil;
create policy profil_hr on public.profil for update to authenticated using (public.is_hr()) with check (public.is_hr());
drop policy if exists profil_hapus on public.profil;
create policy profil_hapus on public.profil for delete to authenticated using (public.is_hr());

drop policy if exists peserta_baca on public.peserta;
create policy peserta_baca on public.peserta for select to authenticated
  using (public.is_hr() or (public.peran_saya() = 'admin' and dept = public.dept_saya()));
drop policy if exists peserta_tambah on public.peserta;
create policy peserta_tambah on public.peserta for insert to authenticated
  with check (public.is_hr() or (public.peran_saya() = 'admin' and dept = public.dept_saya()));
drop policy if exists peserta_ubah on public.peserta;
create policy peserta_ubah on public.peserta for update to authenticated
  using (public.is_hr() or (public.peran_saya() = 'admin' and dept = public.dept_saya()))
  with check (public.is_hr() or (public.peran_saya() = 'admin' and dept = public.dept_saya()));
drop policy if exists peserta_hapus on public.peserta;
create policy peserta_hapus on public.peserta for delete to authenticated
  using (public.is_hr() or (public.peran_saya() = 'admin' and dept = public.dept_saya() and sumber = 'Tambahan'));

drop policy if exists log_baca on public.log_scan;
create policy log_baca on public.log_scan for select to authenticated using (public.is_hr());

-- Hak akses API (Data API)
grant usage on schema public to anon, authenticated;
grant select on public.departemen, public.pengaturan to anon, authenticated;
grant insert, update, delete on public.departemen, public.pengaturan to authenticated;
grant select, insert, update, delete on public.peserta to authenticated;
grant select, update, delete on public.profil to authenticated;
grant select on public.log_scan to authenticated;
revoke all on function public.cek_jadwal(text, date) from public;
grant execute on function public.cek_jadwal(text, date) to anon, authenticated;
revoke all on function public.scan(text, text) from public;
grant execute on function public.scan(text, text) to authenticated;
grant execute on function public.peran_saya(), public.dept_saya(), public.is_hr() to authenticated;

-- Realtime: perubahan peserta langsung tampil di layar admin/HR
do $$ begin
  alter publication supabase_realtime add table public.peserta;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- Data awal ----------
insert into public.pengaturan(id, kuota, target) values (1, 24, 373) on conflict (id) do nothing;
insert into public.departemen(nama, target, urut) values
  ('Operation', 265, 1), ('Maintenance', 86, 2), ('Engineering', 20, 3), ('MSDI', 1, 4), ('Supply Chain Management', 1, 5)
on conflict (nama) do nothing;
