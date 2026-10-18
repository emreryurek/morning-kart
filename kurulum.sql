-- =====================================================================
-- ERY Sadakat Kartı — Supabase kurulumu
-- Supabase > SQL Editor > New query > bu dosyanın TAMAMINI yapıştır > Run
-- Tablolara tarayıcıdan doğrudan erişim YOK. Her şey aşağıdaki
-- fonksiyonlardan geçer, kasa işlemleri PIN ister.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tablolar ----------
create table if not exists isletmeler (
  slug        text primary key,
  ad          text not null,
  hedef       int  not null default 4,
  odul        text not null,
  pin_hash    text not null,
  olusturma   timestamptz not null default now()
);

create table if not exists musteriler (
  isletme     text not null references isletmeler(slug) on delete cascade,
  telefon     text not null,
  damga       int  not null default 0,
  toplam      int  not null default 0,
  hediye      int  not null default 0,
  kvkk_onay   timestamptz,
  ilk_ziyaret timestamptz not null default now(),
  son_ziyaret timestamptz,
  primary key (isletme, telefon)
);

create table if not exists talepler (
  id          bigint generated always as identity primary key,
  isletme     text not null references isletmeler(slug) on delete cascade,
  telefon     text not null,
  durum       text not null default 'bekliyor',  -- bekliyor / onay / red
  olusturma   timestamptz not null default now(),
  islem       timestamptz
);
create index if not exists talepler_bekleyen on talepler (isletme, durum, olusturma);

create table if not exists pin_denemeleri (
  isletme text not null,
  zaman   timestamptz not null default now()
);

alter table isletmeler     enable row level security;
alter table musteriler     enable row level security;
alter table talepler       enable row level security;
alter table pin_denemeleri enable row level security;
revoke all on isletmeler, musteriler, talepler, pin_denemeleri from anon, authenticated;

-- ---------- Yardımcılar ----------
-- Telefonu 5XXXXXXXXX (10 hane) biçimine getirir, geçersizse hata verir
create or replace function _tel(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p,''), '\D', '', 'g');
begin
  d := right(d, 10);
  if d !~ '^5\d{9}$' then raise exception 'GECERSIZ_TELEFON'; end if;
  return d;
end $$;

-- PIN kontrolü: 10 dakikada 8 yanlış denemeden sonra kilitler
create or replace function _pin(p_isletme text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  -- Hata durumunda exception atmıyoruz ki yanlış deneme kaydı geri alınmasın
  if (select count(*) from pin_denemeleri where isletme = p_isletme and zaman > now() - interval '10 minutes') >= 8 then
    return 'PIN_KILITLI';
  end if;
  select pin_hash into h from isletmeler where slug = p_isletme;
  if h is null or h <> crypt(coalesce(p_pin,''), h) then
    insert into pin_denemeleri(isletme) values (p_isletme);
    return 'PIN_HATALI';
  end if;
  return null;
end $$;

-- ---------- Müşteri fonksiyonları ----------
create or replace function kart_bilgi(p_isletme text) returns json
language sql security definer set search_path = public, extensions stable as $$
  select json_build_object('ad', ad, 'hedef', hedef, 'odul', odul) from isletmeler where slug = p_isletme;
$$;

create or replace function kart_durum(p_isletme text, p_tel text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t text := _tel(p_tel); m musteriler; b text;
begin
  select * into m from musteriler where isletme = p_isletme and telefon = t;
  select durum into b from talepler where isletme = p_isletme and telefon = t
    and olusturma > now() - interval '2 hours' order by id desc limit 1;
  return json_build_object(
    'kayitli', m.telefon is not null,
    'damga', coalesce(m.damga, 0),
    'son_talep', b);
end $$;

create or replace function damga_iste(p_isletme text, p_tel text, p_kvkk boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t text := _tel(p_tel); m musteriler;
begin
  if not exists (select 1 from isletmeler where slug = p_isletme) then raise exception 'ISLETME_YOK'; end if;
  select * into m from musteriler where isletme = p_isletme and telefon = t;
  if m.telefon is null then
    if not coalesce(p_kvkk, false) then raise exception 'KVKK_ONAYI_GEREKLI'; end if;
    insert into musteriler(isletme, telefon, kvkk_onay) values (p_isletme, t, now());
  end if;
  if exists (select 1 from talepler where isletme = p_isletme and telefon = t and durum = 'bekliyor'
             and olusturma > now() - interval '30 minutes') then
    return json_build_object('ok', true, 'zaten', true);
  end if;
  if exists (select 1 from talepler where isletme = p_isletme and telefon = t and durum = 'onay'
             and islem > now() - interval '12 hours') then
    raise exception 'BUGUN_ALINDI';
  end if;
  if (select count(*) from talepler where isletme = p_isletme and durum = 'bekliyor'
      and olusturma > now() - interval '30 minutes') >= 30 then
    raise exception 'COK_FAZLA_TALEP';
  end if;
  insert into talepler(isletme, telefon) values (p_isletme, t);
  return json_build_object('ok', true);
end $$;

-- ---------- Kasa fonksiyonları (PIN ister) ----------
create or replace function kasa_giris(p_isletme text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e text;
begin
  e := _pin(p_isletme, p_pin);
  if e is not null then return json_build_object('hata', e); end if;
  return kart_bilgi(p_isletme);
end $$;

create or replace function kasa_bekleyen(p_isletme text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e text;
begin
  e := _pin(p_isletme, p_pin);
  if e is not null then return json_build_object('hata', e); end if;
  return coalesce((select json_agg(x order by x.id) from (
    select t.id, t.telefon, t.olusturma, coalesce(m.damga,0) damga, coalesce(m.toplam,0) toplam
    from talepler t left join musteriler m on m.isletme = t.isletme and m.telefon = t.telefon
    where t.isletme = p_isletme and t.durum = 'bekliyor' and t.olusturma > now() - interval '30 minutes') x), '[]'::json);
end $$;

create or replace function kasa_onayla(p_isletme text, p_pin text, p_id bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e text; t talepler; m musteriler; h int;
begin
  e := _pin(p_isletme, p_pin);
  if e is not null then return json_build_object('hata', e); end if;
  update talepler set durum = 'onay', islem = now()
    where id = p_id and isletme = p_isletme and durum = 'bekliyor' returning * into t;
  if t.id is null then raise exception 'TALEP_YOK'; end if;
  select hedef into h from isletmeler where slug = p_isletme;
  update musteriler set damga = least(damga + 1, h), toplam = toplam + 1, son_ziyaret = now()
    where isletme = p_isletme and telefon = t.telefon returning * into m;
  return json_build_object('telefon', m.telefon, 'damga', m.damga, 'hedef', h, 'doldu', m.damga >= h);
end $$;

create or replace function kasa_reddet(p_isletme text, p_pin text, p_id bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e text;
begin
  e := _pin(p_isletme, p_pin);
  if e is not null then return json_build_object('hata', e); end if;
  update talepler set durum = 'red', islem = now() where id = p_id and isletme = p_isletme and durum = 'bekliyor';
  return json_build_object('ok', true);
end $$;

create or replace function kasa_hediye(p_isletme text, p_pin text, p_tel text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e text; t text := _tel(p_tel); h int; m musteriler;
begin
  e := _pin(p_isletme, p_pin);
  if e is not null then return json_build_object('hata', e); end if;
  select hedef into h from isletmeler where slug = p_isletme;
  update musteriler set damga = 0, hediye = hediye + 1
    where isletme = p_isletme and telefon = t and damga >= h returning * into m;
  if m.telefon is null then raise exception 'HEDIYE_HAKKI_YOK'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function kasa_ozet(p_isletme text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e text; h int;
begin
  e := _pin(p_isletme, p_pin);
  if e is not null then return json_build_object('hata', e); end if;
  select hedef into h from isletmeler where slug = p_isletme;
  return json_build_object(
    'musteri', (select count(*) from musteriler where isletme = p_isletme),
    'bugun', (select count(*) from talepler where isletme = p_isletme and durum = 'onay'
              and islem >= date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul'),
    'ay_hediye', (select coalesce(sum(hediye),0) from musteriler where isletme = p_isletme),
    'hazir', coalesce((select json_agg(telefon) from musteriler where isletme = p_isletme and damga >= h), '[]'::json),
    'liste', coalesce((select json_agg(x) from (
       select telefon, damga, toplam, hediye, son_ziyaret from musteriler where isletme = p_isletme
       order by son_ziyaret desc nulls last limit 50) x), '[]'::json));
end $$;

-- Tarayıcı sadece bu fonksiyonları çağırabilir
revoke execute on all functions in schema public from anon, authenticated, public;
grant execute on function kart_bilgi(text), kart_durum(text,text), damga_iste(text,text,boolean),
  kasa_giris(text,text), kasa_bekleyen(text,text), kasa_onayla(text,text,bigint),
  kasa_reddet(text,text,bigint), kasa_hediye(text,text,text), kasa_ozet(text,text) to anon;

-- ---------- İşletmeler ----------
-- Morning & More. ÇALIŞTIRMADAN ÖNCE: 'PIN_BURAYA' yazısını kendi 6 haneli PIN'inle değiştir.
insert into isletmeler(slug, ad, hedef, odul, pin_hash)
values ('morning', 'Morning & More', 4, 'Çay & tatlı bizden', extensions.crypt('PIN_BURAYA', extensions.gen_salt('bf')))
on conflict (slug) do nothing;

-- PIN değiştirmek için (ileride):
-- update isletmeler set pin_hash = extensions.crypt('YENI_PIN', extensions.gen_salt('bf')) where slug = 'morning';
