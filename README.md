# Plesk Clone Tool

Plesk sunucularında aynı sunucu üzerinde domain'leri tam kopyalayan güçlü bir bash scripti.

## 🚀 Özellikler

- **Tam Kopyalama**: Dosyalar, MySQL veritabanları, cron işleri
- **SSL Desteği**: Let's Encrypt otomatik kurulum
- **Git Entegrasyonu**: Git repository'ler ve Plesk Git Extension ayarları
- **Otomatik Replacement**: Config dosyalarında domain adı değiştirme
- **Güvenli**: MySQL admin yetkilerini kullanır, geçici dosyaları temizler

## 📋 Gereksinimler

- Plesk Obsidian 18.x+ (Debian/Ubuntu/CentOS/Alma/Rocky)
- Root veya sudo yetkisi
- `rsync`, `mysql`, `mysqldump` komutları

## ⚡ Hızlı Kullanım

```bash
# GitHub'dan direkt çek ve çalıştır
curl -s https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/plesk_clone.sh | bash -s -- -s example.com -t staging.example.com -o admin --ssl --copy-git
```

## 🔧 Manuel Kullanım

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

## 🐛 Sorun Giderme

Script çalıştıktan sonra `./logs/` klasöründe detaylı bilgiler:
- `{domain}_DB_INFO.txt` - Yeni veritabanı bilgileri
- `{domain}_SYS_INFO.txt` - Sistem kullanıcı bilgileri

## 📄 Lisans

MIT License - Özgürce kullanabilir, değiştirebilir ve dağıtabilirsiniz.