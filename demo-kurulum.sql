-- ERY Studio sitesindeki herkese açık DEMO (erystudio.com/sadakat)
-- Demo işletmenin PIN'i bilerek herkese açık: 123456
insert into isletmeler(slug, ad, hedef, odul, pin_hash)
values ('demo', 'Örnek Kafe', 4, 'Beşinci kahve bizden',
        extensions.crypt('123456', extensions.gen_salt('bf')))
on conflict (slug) do nothing;

-- Demo için: aynı gün tekrar damga alınabilsin, 1 günden eski demo kayıtları silinsin
create or replace function damga_iste(p_isletme text, p_tel text, p_kvkk boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t text := _tel(p_tel); m musteriler;
begin
  if not exists (select 1 from isletmeler where slug = p_isletme) then raise exception 'ISLETME_YOK'; end if;
  if p_isletme = 'demo' then
    delete from talepler where isletme = 'demo' and olusturma < now() - interval '1 day';
    delete from musteriler where isletme = 'demo' and ilk_ziyaret < now() - interval '1 day';
  end if;
  select * into m from musteriler where isletme = p_isletme and telefon = t;
  if m.telefon is null then
    if not coalesce(p_kvkk, false) then raise exception 'KVKK_ONAYI_GEREKLI'; end if;
    insert into musteriler(isletme, telefon, kvkk_onay) values (p_isletme, t, now());
  end if;
  if exists (select 1 from talepler where isletme = p_isletme and telefon = t and durum = 'bekliyor'
             and olusturma > now() - interval '30 minutes') then
    return json_build_object('ok', true, 'zaten', true);
  end if;
  if p_isletme <> 'demo' and exists (select 1 from talepler where isletme = p_isletme and telefon = t and durum = 'onay'
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

-- Demo PIN'i herkese açık olduğu için demo kilitlenmesin
create or replace function _pin(p_isletme text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  if p_isletme <> 'demo' and (select count(*) from pin_denemeleri where isletme = p_isletme and zaman > now() - interval '10 minutes') >= 8 then
    return 'PIN_KILITLI';
  end if;
  select pin_hash into h from isletmeler where slug = p_isletme;
  if h is null or h <> crypt(coalesce(p_pin,''), h) then
    if p_isletme <> 'demo' then insert into pin_denemeleri(isletme) values (p_isletme); end if;
    return 'PIN_HATALI';
  end if;
  return null;
end $$;

revoke execute on function damga_iste(text,text,boolean), _pin(text,text) from public, anon, authenticated;
grant execute on function damga_iste(text,text,boolean) to anon;
