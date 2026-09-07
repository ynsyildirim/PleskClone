# Test ortamı

İki düğümlü (kaynak + hedef) docker-compose ortamı ve senaryo paketi.

```bash
cd test
./run.sh all       # kur + tohumla + tüm senaryoları çalıştır
./run.sh logs      # özet ve log listesi
./run.sh sh a      # kaynak düğüme kabuk
./run.sh down      # kaldır
```

---

## İki profil

### `sim` (varsayılan)

Native mimaride çalışır, lisans gerektirmez, hızlıdır.

Gerçek olanlar: **MariaDB, OpenSSH, rsync, git, sqlite3, cron, PHP, tar/gzip, dosya sistemi, sistem kullanıcıları, izinler, psa şeması.**
Uyumluluk katmanı: yalnızca `plesk` CLI komut yüzeyi (`sim/plesk`), gerçek psa şeması üzerinde çalışır.

`plesk_clone.sh` Plesk'e yalnızca `plesk` CLI + psa SQL + dosya sistemi üzerinden dokunduğu için, test edilen zincirin geri kalanı (ssh, rsync, mysqldump/mysql, sqlite3, git, crontab, chown/chmod) gerçektir.

```bash
./run.sh all sim
```

### `real`

Gerçek Plesk Obsidian imajı + panel UI.

```bash
./run.sh up real
./run.sh ui real     # panel giriş linkleri
```

| Düğüm | Panel |
|-------|-------|
| plesk-a (kaynak) | https://localhost:8443 |
| plesk-b (hedef)  | https://localhost:8444 |

**Ön koşullar:**

1. **x86_64 Linux host**, veya Apple Silicon'da Docker Desktop ayarlarında
   *Use Rosetta for x86_64/amd64 emulation* açık olmalı.
   QEMU emülasyonunda iki sorun çıkar:
   - Plesk lisansı sanallaştırma doğrulamasından geçmez (`key_vz: 1`; x86 hypervisor CPUID biti emülasyonda yok) -> `plesk bin domain --create` "The license key is invalid" verir.
   - Panel sunucusu `sw-cp-server` LuaJIT VM'ini başlatamaz (`failed to initialize Lua VM`) -> 8443 açılmaz.

2. **Birden fazla domain'e izin veren geçerli bir Plesk lisansı.** İmajla gelen anahtar `lim_dom: 1` (tek domain) sınırlıdır; aynı sunucuda klonlama senaryoları için yetmez.

   ```bash
   docker exec plesk-a plesk bin license --install <ANAHTAR-DOSYASI|AKTİVASYON-KODU>
   docker exec plesk-b plesk bin license --install <ANAHTAR-DOSYASI|AKTİVASYON-KODU>
   ```

3. Apple Silicon'da amd64 emülasyonu bir kez kaydedilmeli (run.sh otomatik yapar):

   ```bash
   docker run --privileged --rm tonistiigi/binfmt --install amd64
   ```

---

## Tohumlanan demo veri (`seed.sh`)

Kaynak düğümde `demo.test` domaini ve gerçekçi bir kurulum oluşturulur:

- Hosting, sistem kullanıcısı (`demouser`), `/bin/bash` shell, PHP handler
- `httpdocs`: `index.php`, `.env`, `wp-config.php`, `health.php`, `deploy.sh`
- 2 veritabanı + kullanıcıları: `shopdb`/`shopuser`, `blogdb`/`bloguser` (tablo, view, procedure ve veri ile)
- `.composer` dizini (cache dahil — kopyalamada hariç tutulması test edilir)
- **Bare** git deposu (`app.git`) + Plesk Git Extension kaydı + post-deployment action
- **Bare olmayan** git deposu (`site.git`) — `worktree` bileşenini kapsamak için
- 2 crontab görevi, alt alan adı, domain alias, mail hesabı, ek DNS kayıtları, SSL sertifikası, FTP alt hesabı

`health.php` `.env`'i okuyup **gerçekten veritabanına bağlanır**. Klonlamadan sonra hedefte çalıştırılması, DB adı/kullanıcı/parola politikası ve config yeniden yazımı zincirinin tamamını tek kontrolde doğrular.

---

## Senaryolar

| ID | Ne test eder |
|----|--------------|
| S01 | Aynı sunucuda klon, DB bilgileri tamamen yenilenir (31 kontrol: dosyalar, DB, cron, PHP, shell, composer, git, deploy script) |
| S02 | Aynı sunucuda `keep` istenirse güvenlik düşürmesi ve uyarılar |
| S03 | DB adı önek politikası |
| S04 | Elle DB adı eşlemesi (`--db-map`) |
| S05 | `--only` ile seçmeli bileşen |
| S06 | `--no-db` ile config'e dokunulmaması |
| S07 | `--dry-run` hiçbir şey değiştirmemeli |
| S08 | `--fix-git` ile Git entegrasyonu onarımı |
| S09 | Güvenlik: aynı sunucuda aynı isim reddedilmeli |
| S10 | Uzak sunucuya farklı isimle, DB bilgileri birebir korunarak (17 kontrol) |
| S11 | Uzak sunucuya `--move` ile birebir taşıma; `.env` ve `wp-config.php` byte-byte aynı |
| S12 | Uzak: DB adı değişir, kullanıcı/parola korunur |
| S13 | Kurulum ve güncelleme akışı |
| S14 | `--full-vhost` ve `--no-config-rewrite` |
| S15 | Parola düz metin okunamadığında MySQL hash'inin kopyalanması |
| S16 | Gerçek deploy döngüsü: kaynakta yeni commit -> hedefte deploy -> `.env` korunur -> uygulama çalışır -> post-deployment komutu DB'ye bağlanır |
| S17 | Aynı klonu iki kez çalıştırmak (idempotenslik) |
| S18 | `--db-overwrite` ile veriyi üzerine yazma |
| S19 | `--engine native` (pleskbackup/pleskrestore) |
| S20 | `--update` gerçekten dosyaları değiştiriyor mu (sürüm 2.0.0 -> 2.0.1-test -> geri) |
| S21 | `--no-delete` ile hedefe özel dosyanın korunması |
| S22 | Tüm senaryolardan sonra kaynağın bozulmamış olması |
| S23 | `worktree` bileşeni: izlenmeyen dosyalar (`.env`) silinmemeli |

Toplam **170 kontrol**. Loglar `test/logs/` altında; özet `test/logs/SUMMARY.txt`.

---

## Dosyalar

```
docker-compose.yml     iki profil (sim / real)
run.sh                 host tarafı sürücü
prepare.sh             sshd + anahtar + pleskclone kurulumu
seed.sh                kaynak düğümü demo veriyle doldurur
scenarios.sh           S01-S14 + çerçeve (check/scenario/özet)
scenarios_extra.sh     S15-S23
sim/                   lisanssız düğüm imajı (Dockerfile, plesk CLI, psa şeması)
plesk/                 gerçek Plesk imajı üzerine sshd + git ekleyen katman
logs/                  test çıktıları
```
