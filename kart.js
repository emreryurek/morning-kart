/* Ortak: Supabase RPC çağrısı + yardımcılar */
(function () {
  var K = window.KART;
  document.documentElement.style.setProperty('--c1', K.renk);
  document.documentElement.style.setProperty('--c2', K.renk2);
  K.rpc = function (fn, args) {
    var h = { 'Content-Type': 'application/json', apikey: K.supabaseKey };
    if (/^eyJ/.test(K.supabaseKey)) h.Authorization = 'Bearer ' + K.supabaseKey;
    return fetch(K.supabaseUrl + '/rest/v1/rpc/' + fn, { method: 'POST', headers: h, body: JSON.stringify(args) })
      .then(function (r) { return r.json().catch(function () { return null; }).then(function (j) {
        if (!r.ok) throw new Error((j && j.message) || 'BAGLANTI');
        if (j && j.hata) throw new Error(j.hata);
        return j;
      }); });
  };
  K.mesaj = function (kod) {
    return ({
      GECERSIZ_TELEFON: 'Telefon numarasını 05XX XXX XX XX şeklinde yaz.',
      KVKK_ONAYI_GEREKLI: 'Devam etmek için onay kutusunu işaretle.',
      BUGUN_ALINDI: 'Bugünkü damganı zaten aldın. Yarın görüşmek üzere! ☀️',
      COK_FAZLA_TALEP: 'Şu an yoğunuz, birazdan tekrar dener misin?',
      PIN_HATALI: 'PIN yanlış.', PIN_KILITLI: 'Çok fazla yanlış deneme. 10 dakika sonra tekrar dene.',
      HEDIYE_HAKKI_YOK: 'Bu müşterinin hediye hakkı yok.', TALEP_YOK: 'Bu talep zaten işlenmiş.',
      BAGLANTI: 'Bağlantı sorunu. İnterneti kontrol edip tekrar dene.'
    })[kod] || 'Bir sorun oldu, tekrar dene.';
  };
  K.tel = function (t) { var d = String(t || '').replace(/\D/g, '').slice(-10); return d; };
  K.telGoster = function (d, gizli) { d = K.tel(d); return gizli ? '0' + d.slice(0, 3) + ' *** ' + d.slice(6, 8) + ' ' + d.slice(8) : '0' + d.slice(0, 3) + ' ' + d.slice(3, 6) + ' ' + d.slice(6, 8) + ' ' + d.slice(8); };
  K.store = function (k, v) { try { if (v === undefined) return localStorage.getItem(k); if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) { return null; } };
  K.sun = function (s, c) { var r = ''; for (var a = 0; a < 360; a += 30) r += '<line x1="20" y1="4" x2="20" y2="10" transform="rotate(' + a + ' 20 20)"/>';
    return '<svg viewBox="0 0 40 40" width="' + s + '" height="' + s + '" aria-hidden="true"><g stroke="' + (c || 'var(--c1)') + '" stroke-width="3.2" stroke-linecap="round">' + r + '</g><circle cx="20" cy="20" r="6.5" fill="none" stroke="' + (c || 'var(--c1)') + '" stroke-width="3"/></svg>'; };
})();
