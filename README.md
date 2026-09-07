# Plesk Clone / Migrate

Plesk sunucularında bir domain'i **tüm detaylarıyla** klonlayan ya da **başka bir sunucuya birebir taşıyan** bash aracı.

Tek giriş noktası (`plesk_clone.sh`), tek kod yolu: aynı sunucuda klonlama ile farklı sunucuya taşıma arasında mantık farkı yoktur.

---

## Kurulum

Tek satır — indirir, derler, `pleskclone` komutunu kurar:

```bash
curl -fsSL https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/install.sh | bash
```

Sonrasında:

```bash
pleskclone --help       # kullanım
pleskclone --where      # kurulum dizini ve sürüm
pleskclone --update     # depodaki son sürüme güncelle (build otomatik)
pleskclone --uninstall  # kaldır
```

Kurulum yeri varsayılan olarak `/usr/local/lib/pleskclone`, komut `/usr/local/bin/pleskclone`.
`--update` ve loglar yeniden başlatmadan sağ çıksın diye kalıcı bir dizin seçilmiştir. Geçici dizine kurmak isterseniz:

```bash
PLESKCLONE_HOME=/tmp/pleskclone curl -fsSL https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/install.sh | bash
```

Diğer ortam değişkenleri: `PLESKCLONE_BIN`, `PLESKCLONE_REPO`, `PLESKCLONE_REF`, `PLESKCLONE_SRC` (internetsiz kurulum için yerel dizin/arşiv).

Depoyu elle kullanmak isterseniz `git clone` edip `./plesk_clone.sh` de çalışır.

---

## İki temel senaryo

| Senaryo | Komut | Veritabanı |
|---------|-------|------------|
| **Aynı sunucuda staging klonu** | `pleskclone -s site.com -t staging.site.com` | Ad/kullanıcı/parola yenilenir (çakışma olmasın diye) |
| **Başka sunucuya birebir taşıma** | `pleskclone -s site.com --move --to-host 1.2.3.4` | **Hiçbir şey değişmez** — config dosyalarına dokunulmaz |

### Aynı sunucuda klon

```bash
pleskclone -s example.com -t staging.example.com --copy-git --ssl
```

Script size sorar:

```
Veritabanı bilgileri nasıl işlensin?
  1) Sadece veritabanı ADI değişsin (kullanıcı ve parola aynı kalsın)
  2) Ad, kullanıcı ve parola — hepsi yeniden üretilsin
  3) Tek tek seçmek istiyorum
  4) Veritabanlarını hiç kopyalama
```

### Başka sunucuya birebir taşıma

```bash
pleskclone -s example.com --move --to-host 203.0.113.10
```

`--move`: hedef domain = kaynak domain, **veritabanı adı/kullanıcı/parola birebir korunur**, tüm vhost dizini kopyalanır, bileşenlerin tamamı açılır. Uygulama config'lerinde (`.env`, `wp-config.php`) hiçbir değişiklik gerekmez.

### Farklı isimle taşıma, DB bilgileri korunarak

```bash
pleskclone -s example.com -t yeni.com --to-host 203.0.113.10 --keep-db --full
```

### Ne olacağını önce gör

```bash
pleskclone -s example.com -t test.example.com --dry-run
```

---

## Veritabanı politikası

Üç şey birbirinden bağımsız seçilebilir: **ad**, **kullanıcı adı**, **parola**.

| Seçenek | Ad | Kullanıcı | Parola |
|---------|-----|-----------|--------|
| `--keep-db` | aynı | aynı | aynı |
| `--new-db` | `_hedef_domain` soneki | yeni rastgele | yeni güçlü parola |
| `--db-mode suffix --db-user-mode keep --db-pass-mode keep` | sonek | aynı | aynı |

```
--db-mode        keep | suffix | prefix | map
--db-suffix STR  --db-prefix STR  --db-map "eski=yeni,eski2=yeni2"
--db-user-mode   keep | new | map        --db-user-map "eski=yeni"
--db-pass-mode   keep | new | map        --db-pass-map "kullanici=parola"
--db-overwrite   hedefte aynı adlı DB varsa VERİYİ de üzerine yaz
--no-db          veritabanlarını hiç kopyalama
```

**Parola nasıl korunuyor?** İki kademe:

1. Plesk parolayı düz metin saklıyorsa (`accounts.type='plain'`) doğrudan aynı parolayla oluşturulur.
2. Saklamıyorsa MySQL'deki parola **hash'i** kaynaktan kopyalanır (`ALTER USER ... IDENTIFIED WITH/VIA ...`, gerekirse `SET PASSWORD`). Uygulama config'i değişmeden çalışmaya devam eder; Plesk arayüzünün gösterdiği parola farklı olur ve log'a yazılır.

Eski parola hiçbir şekilde okunamazsa metin değişimi yapılamaz; bu durum **sessiz geçilmez**, uyarı verilir ve rapor dosyasına "elle yapılması gerekenler" olarak yazılır.

**Hedefte veritabanı zaten varsa** yalnızca veri aktarımı atlanır; kullanıcı ve yetkiler yine de doğrulanır. Böylece aynı komutu tekrar çalıştırmak hedefi çalışır durumda bırakır.

**Aynı sunucuda `keep` kullanılamaz** (veritabanı adları ve MySQL kullanıcıları sunucu genelinde tekildir). Script bunu tespit edip sonek moduna geçer ve uyarır.

### Değişen değerler config dosyalarına yazılır

Ad/kullanıcı/parola veya domain değiştiyse hedefteki metin dosyalarında eski değerler yenileriyle değiştirilir. Uzantı beyaz listesi yoktur — `deploy.sh` gibi kabuk betikleri ve uzantısız dosyalar da taranır; ikili dosyalar elenir, `node_modules`, `vendor`, `.git` hariç tutulur. Değiştirilen her dosyanın yedeği `vhost/.plesk-clone-backup/<zaman-damgası>/` altına alınır. Kapatmak için `--no-config-rewrite`.

---

## Bileşenler

```
domain  php  shell  files  composer  subdomains  aliases  db  configrewrite
git  worktree  cron  dns  mail  ftp  certs  ssl  perms  diskusage
```

```bash
--full            ssl ve worktree hariç hepsini aç
--only db,files   sadece bunları çalıştır
--skip mail,dns   bunları atla
--copy-git        git bileşenini aç
--ssl             Let's Encrypt bileşenini aç
--fix-git         sadece Git entegrasyonunu onar
```

| Bileşen | Ne yapar |
|---------|----------|
| `domain` | Hedef domain'i owner/plan/IP/sistem kullanıcısı ile oluşturur (plan hedefte yoksa uygun bir plana düşer) |
| `php` | PHP handler ve sürümünü eşitler; handler hedefte yoksa sürüme göre eşleştirir |
| `shell` | SSH shell erişim ayarını taşır |
| `files` | Document root veya (`--full-vhost` ile) tüm vhost dizinini rsync'ler |
| `composer` | `.composer` dizinini taşır, cache'i hariç tutar |
| `subdomains` / `aliases` | Alt alan adlarını ve domain alias'larını oluşturur, dosyalarını taşır |
| `db` | Veritabanlarını, kullanıcılarını ve parolalarını politikaya göre taşır |
| `configrewrite` | Değişen değerleri uygulama config'lerine yazar (yedekleyerek) |
| `git` | Git depolarını + Plesk Git Extension SQLite kayıtlarını + deploy key'leri taşır |
| `worktree` | Bare olmayan depolarda çalışma dizinini yeniden kurar (opt-in, aşağıya bakın) |
| `cron` | Sistem kullanıcısının crontab'ını taşır (domain adını düzelterek) |
| `dns` | DNS kayıtlarını taşır; kaynak sunucu IP'sini hedef IP ile değiştirir |
| `mail` | Mail hesaplarını ve maildir'leri taşır (parola korunabiliyorsa korunur) |
| `ftp` | FTP alt hesaplarını taşır |
| `certs` | Mevcut SSL sertifikasını (özel anahtar dahil) taşır ve domaine atar |
| `ssl` | Let's Encrypt sertifikası çıkarır |
| `perms` | Sahiplik/izinleri düzeltir, mümkünse `plesk repair fs` çalıştırır |
| `diskusage` | `disk_usage` kaydını oluşturur ve Plesk istatistiklerini hesaplatır |

### worktree bileşeni neden opt-in

`worktree`, hedef document root'ta `git reset --hard` çalıştırır. Bu, git'te izlenmeyen dosyaları (`.env`, yüklenen medya) etkileyebileceği için `--full` ve `--move` tarafından **açılmaz**; açıkça istenmelidir:

```bash
--git-worktree    çalışma dizinini yeniden kur (izlenmeyen dosyalar korunur)
--git-clean       ek olarak 'git clean -fd' — izlenmeyen dosyaları SİLER
```

`--ssl` de `--full` ile açılmaz: taşımada doğrusu mevcut sertifikayı kopyalamaktır (`certs`); DNS henüz hedefe yönlenmediği için Let's Encrypt başarısız olur.

---

## İki motor

**`--engine granular`** (varsayılan) — bileşenler tek tek çalışır. Yeniden adlandırma yapabilir, seçmeli çalıştırılabilir, `--dry-run` destekler.

**`--engine native`** — Plesk'in kendi `pleskbackup` / `pleskrestore` araçlarını kullanır. Aynı isimle farklı sunucuya taşımanın en eksiksiz yolu, ama yeniden adlandırma yapamaz.

```bash
pleskclone -s example.com --move --to-host 203.0.113.10 --engine native
```

---

## Mimari

```
plesk_clone.sh          Tek giriş noktası (orkestratör + agent dağıtımı)
install.sh              Kurulum / güncelleme
lib/00-core.sh          Loglama, dry-run, etkileşim, kabuk escape
lib/10-plesk.sh         Plesk CLI / psa veritabanı sarmalayıcıları
lib/20-transport.sh     local & remote soyutlaması (ssh multiplexing, rsync)
lib/30-db.sh            Veritabanı politikaları, dump/import, parola taşıma
lib/40-files.sh         Dosya senkronu, config yeniden yazımı, izinler
lib/50-git.sh           Git depoları + Git Extension SQLite taşıma
lib/60-extras.sh        Domain, PHP, SSH, cron, DNS, mail, FTP, SSL, istatistik
lib/70-native.sh        pleskbackup / pleskrestore motoru
lib/80-wizard.sh        Etkileşimli plan sihirbazı ve doğrulama
lib/90-run.sh           Bileşen yönetimi, ana akış, agent dağıtımı, rapor
lib/95-selfupdate.sh    --update / --where / --uninstall
build.sh                lib/ içeriğini gömüp tek dosya üretir (dist/)
test/                   İki düğümlü docker test ortamı ve senaryolar
```

**Agent modeli.** Hedef sunucuda yapılacak her iş `plesk_clone.sh --agent <işlem>` olarak çalışır. Orkestratör kendi tek-dosyalık kopyasını hedefe gönderir ve tüm adımları bu kopya üzerinden çağırır:

- `TRANSPORT=local` -> agent aynı makinede `bash` ile çalışır
- `TRANSPORT=remote` -> agent `ssh` üzerinden hedef sunucuda çalışır

Böylece "aynı sunucu" ve "farklı sunucu" akışları **aynı kodu** kullanır. SSH bağlantıları ControlMaster ile çoğullanır: kimlik doğrulama bir kez yapılır.

### Tek dosyalık dağıtım

```bash
./build.sh                 # dist/plesk-clone.sh üretir
```

`dist/plesk-clone.sh` bağımsız çalışır (`lib/` gerekmez). `install.sh` bunu otomatik üretir.

---

## Test ortamı

`test/` altında docker-compose ile iki düğümlü bir ortam var. Ayrıntılar: [test/README.md](test/README.md)

```bash
cd test
./run.sh all          # kur + tohumla + 22 senaryo / 170 kontrol
./run.sh logs         # özet ve loglar
./run.sh down
```

---

## Gereksinimler

**Kaynak sunucu:** Plesk Obsidian 18.x+, root erişimi, `rsync`, `mysqldump`, `gzip`, `bash 4+`
**Hedef sunucu:** Plesk kurulu, `mysql`, `rsync`
**Git bileşeni için:** iki tarafta da `sqlite3`
**Uzak taşıma için:** SSH erişimi (anahtar tabanlı kimlik doğrulama önerilir)

```bash
ssh-keygen -t ed25519 -C "plesk-clone@$(hostname)"
ssh-copy-id root@HEDEF_SUNUCU
```

---

## Güvenlik

- MySQL admin parolası `/etc/psa/.psa.shadow`'dan okunur; komut satırına **yazılmaz** (`MYSQL_PWD` kullanılır, `ps` çıktısında görünmez)
- Üretilen parolalar `openssl rand` ile oluşturulur
- Log ve kimlik bilgisi dosyaları `600`, `logs/` dizini `700`
- Geçici dizinler ve hedefteki agent dizini çıkışta silinir (`trap`)
- Veritabanı dökümleri diske yazılmaz; doğrudan hedefe akıtılır
- "Uzak" sunucu aslında aynı makineyse tespit edilir; aynı isimle işlem durdurulur
- Yıkıcı olabilecek adımlar (`git clean`, DB üzerine yazma) açıkça istenmedikçe çalışmaz

---

## Çıktılar

`./logs/` altında:

| Dosya | İçerik |
|-------|--------|
| `{domain}_clone_{zaman}.log` | Tam oturum logu |
| `{domain}_CLONE_REPORT.txt` | Özet + manuel kontrol listesi |
| `{domain}_DB_INFO.txt` | Veritabanı erişim bilgileri |
| `{domain}_SYS_INFO.txt` | Sistem kullanıcısı ve parolası |
| `{domain}_MAIL_INFO.txt` | Yeni üretilen mail parolaları |
| `{domain}_FTP_INFO.txt` | Yeni üretilen FTP parolaları |

---

## Otomatik taşınmayanlar

Rapor dosyasında da listelenir:

- Nginx/Apache **ek direktifleri** (servis planı dışındaki özel direktifler)
- **Korumalı dizinler** (protected directories) ve kullanıcıları
- Özel `php.ini` direktifleri (tespit edilir ve uyarı verilir, uygulanmaz)
- Plesk arayüzündeki **Zamanlanmış Görevler** listesi (crontab taşınır ve görevler çalışır; arayüz listesinde görünmeleri için bir kez kaydedilmeleri gerekebilir)
- Git **webhook** tanımları (deploy key'ler yeniden üretilir — uzak depoya yeni public key'i eklemeniz gerekir)
- DNS delegasyonu / nameserver kayıtları

Bunların tamamı için `--engine native` alternatif bir yoldur.

---

## Lisans

MIT
