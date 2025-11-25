# Plesk Clone Tool

Plesk sunucularında domain'leri tam kopyalayan güçlü bir bash scripti. Hem aynı sunucuda hem de farklı sunucular arası klonlama desteği.

## 🚀 Özellikler

- **Tam Kopyalama**: Dosyalar, MySQL veritabanları, cron işleri
- **Remote Klonlama**: Farklı sunucular arası otomatik transfer
- **SSL Desteği**: Let's Encrypt otomatik kurulum
- **Git Entegrasyonu**: Git repository'ler ve Plesk Git Extension ayarları
- **Otomatik Replacement**: Config dosyalarında domain adı değiştirme
- **Güvenli**: MySQL admin yetkilerini kullanır, geçici dosyaları temizler

## 📋 Gereksinimler

### Yerel Klonlama
- Plesk Obsidian 18.x+ (Debian/Ubuntu/CentOS/Alma/Rocky)
- Root veya sudo yetkisi
- `rsync`, `mysql`, `mysqldump` komutları

### Uzak Klonlama (Ek Gereksinimler)
- SSH key-based authentication (password-less)
- Kaynak sunucuda: `tar`, `gzip`, `rsync`
- Hedef sunucuda: Plesk kurulu, `mysql` erişimi
- Firewall: SSH portu (22 veya özel) açık

## ⚡ Hızlı Kullanım

### Aynı Sunucuda (Local Clone)

```bash
# GitHub'dan direkt çek ve çalıştır
curl -s https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/plesk_clone.sh | bash -s -- -s example.com -t staging.example.com -o admin --ssl --copy-git
```

### Farklı Sunucular Arası (Remote Clone)

```bash
# Remote clone wrapper'ı kullan - interaktif mod
./plesk_clone_remote.sh -s demo.com -t production.demo.com -o admin --ssl --copy-git

# Script size şunları soracak:
# 1. Hedef aynı mı farklı sunucuda mı?
# 2. Farklı sunucuysa: IP, SSH user, port
# 3. Onay
```

## 🔧 Manuel Kullanım

### Yerel Klonlama

```bash
# Script'i indir
wget https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/plesk_clone.sh
chmod +x plesk_clone.sh

# Temel kullanım
./plesk_clone.sh -s kaynak.com -t hedef.com -o admin

# SSL ve Git ile tam kopyalama
./plesk_clone.sh -s example.com -t staging.example.com -o admin --ssl --copy-git

# Sadece test (değişiklik yapmaz)
./plesk_clone.sh -s example.com -t test.example.com -o admin --dry-run
```

### Uzak Sunucuya Klonlama

```bash
# Remote wrapper'ı indir
wget https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/plesk_clone_remote.sh
wget https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/plesk_clone_remote_runner.sh
chmod +x plesk_clone_remote.sh plesk_clone_remote_runner.sh

# İnteraktif mod - size seçenekleri sorar
./plesk_clone_remote.sh -s kaynak.com -t hedef.com -o admin --ssl

# Örnek akış:
# → "Hedef nerede?" → "2) Farklı sunucuda"
# → SSH bilgileri gir
# → Onay ver
# → Otomatik paketleme, transfer, kurulum
```

## 📝 Parametreler

| Parametre | Açıklama |
|-----------|----------|
| `-s, --source` | Kaynak domain adı |
| `-t, --target` | Hedef domain adı |
| `-o, --owner` | Domain sahibi (Plesk kullanıcısı) |
| `--ssl` | Let's Encrypt SSL sertifikası kur |
| `--copy-git` | Git repository'lerini kopyala |
| `--fix-git` | Sadece Git entegrasyonunu düzelt |
| `--dry-run` | Test modu (değişiklik yapmaz) |

## 📊 Kopyalanan Öğeler

✅ **Dosyalar**: httpdocs klasörü (rsync)  
✅ **Veritabanları**: MySQL/MariaDB (dump/import)  
✅ **Cron İşleri**: Sistem kullanıcısı crontab'ı  
✅ **PHP Ayarları**: Handler ve versiyon  
✅ **SSH Ayarları**: Shell erişim durumu  
✅ **Git Repository**: Plesk Git Extension entegrasyonu  
✅ **Config Replacement**: .env, wp-config.php gibi dosyalarda domain değiştirme  

## 🔐 Güvenlik

- MySQL admin şifresini `/etc/psa/.psa.shadow` dosyasından okur
- Geçici SQL dump dosyaları `shred` ile güvenli silinir
- Veritabanı şifreleri rastgele oluşturulur
- Log dosyaları sadece owner okuyabilir (600)

## 📋 Notlar

- Uygulama config dosyalarında (.env, wp-config.php) yeni DB bilgilerini manuel güncelleyin
- Git webhook/token ayarlarını hedefte yeniden doğrulayın
- Nginx/Apache özel direktifler servis planıyla taşınır

## 🔑 SSH Key Authentication Kurulumu (Remote Clone İçin)

Uzak sunucuya klonlama yaparken SSH key authentication gereklidir:

```bash
# 1. Kaynak sunucuda SSH key oluştur (yoksa)
ssh-keygen -t rsa -b 4096 -C "plesk-clone@$(hostname)"

# 2. Public key'i hedef sunucuya kopyala
ssh-copy-id root@HEDEF_SUNUCU_IP

# 3. Bağlantıyı test et
ssh root@HEDEF_SUNUCU_IP "exit"

# Başarılıysa password sormadan bağlanacaktır
```

## 🐛 Sorun Giderme

Script çalıştıktan sonra `./logs/` klasöründe detaylı bilgiler:
- `{domain}_DB_INFO.txt` - Yeni veritabanı bilgileri
- `{domain}_SYS_INFO.txt` - Sistem kullanıcı bilgileri
- `{domain}_remote_install.log` - Uzak kurulum logları (remote clone)

## 📄 Lisans

MIT License - Özgürce kullanabilir, değiştirebilir ve dağıtabilirsiniz.