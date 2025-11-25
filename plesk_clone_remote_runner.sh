#!/usr/bin/env bash
set -euo pipefail

# Plesk Remote Clone Runner
# Uzak sunucuda çalışır, gelen paketleri açar ve domain'i oluşturur

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[BİLGİ] %s\n" "$*"; }
warn(){ printf "\033[33m[UYARI]\033[0m %s\n" "$*"; }
err (){ printf "\033[31m[HATA]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

bold "=== Plesk Remote Clone Runner ==="
info "Uzak sunucuda klonlama başlıyor..."

# Sanity checks
command -v plesk >/dev/null 2>&1 || die "Plesk CLI bulunamadı"
command -v mysql >/dev/null 2>&1 || die "MySQL CLI bulunamadı"

# domain_info.json'dan bilgileri oku
if [[ ! -f "domain_info.json" ]]; then
  die "domain_info.json bulunamadı"
fi

SOURCE=$(grep -oP '"source":\s*"\K[^"]+' domain_info.json)
TARGET=$(grep -oP '"target":\s*"\K[^"]+' domain_info.json)
OWNER=$(grep -oP '"owner":\s*"\K[^"]+' domain_info.json)
WITH_SSL=$(grep -oP '"with_ssl":\s*\K[^,}]+' domain_info.json)
COPY_GIT=$(grep -oP '"copy_git":\s*\K[^,}]+' domain_info.json)

info "Kaynak: $SOURCE"
info "Hedef: $TARGET"
info "Owner: $OWNER"

# Hedef domain kontrolü
if plesk bin domain --info "$TARGET" >/dev/null 2>&1; then
  warn "Hedef domain zaten mevcut: $TARGET"
  read -p "Üzerine yazmak istiyor musunuz? (e/H): " overwrite
  [[ "$overwrite" != "e" && "$overwrite" != "E" ]] && die "İşlem iptal edildi"
fi

# 1. Domain oluştur
info "1/5 Hedef domain oluşturuluyor: $TARGET"

# Sistem kullanıcı bilgileri
SYS_USER="${TARGET//./_}"
SYS_PASS="$(openssl rand -base64 16 | tr -d '\n=')"

# Sunucunun IP'sini al
SERVER_IP=$(hostname -I | awk '{print $1}')

# Default servis planı
SERVICE_PLAN="Unlimited"

info "  Sistem kullanıcısı: $SYS_USER"
info "  IP: $SERVER_IP"

plesk bin domain --create "$TARGET" \
    -owner "$OWNER" \
    -service-plan "$SERVICE_PLAN" \
    -ip "$SERVER_IP" \
    -login "$SYS_USER" \
    -passwd "$SYS_PASS" \
    -hosting true || die "Domain oluşturma başarısız"

info "  ✓ Domain oluşturuldu"

# 2. Dosyaları aç ve yerleştir
info "2/5 Site dosyaları yerleştiriliyor..."

DOCROOT_TGT="/var/www/vhosts/$TARGET/httpdocs"

if [[ -f "files/httpdocs.tar.gz" ]]; then
  # Docroot'u temizle ve yeni dosyaları aç
  rm -rf "$DOCROOT_TGT"/* 2>/dev/null || true
  tar -xzf "files/httpdocs.tar.gz" -C "$DOCROOT_TGT" || die "Dosya açma başarısız"
  
  info "  ✓ Dosyalar yerleştirildi: $(du -sh "$DOCROOT_TGT" | cut -f1)"
else
  warn "  httpdocs.tar.gz bulunamadı"
fi

# Git dosyalarını yerleştir
if [[ "$COPY_GIT" == "1" && -f "files/git.tar.gz" ]]; then
  info "  Git dosyaları yerleştiriliyor..."
  GIT_DIR="/var/www/vhosts/$TARGET/git"
  mkdir -p "$GIT_DIR"
  tar -xzf "files/git.tar.gz" -C "$GIT_DIR" || warn "Git açma başarısız"
  info "  ✓ Git dosyaları yerleştirildi"
fi

# 3. Veritabanlarını oluştur ve import et
info "3/5 Veritabanları oluşturuluyor..."

MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASS="$(cat /etc/psa/.psa.shadow 2>/dev/null || true)"

if [[ -z "$MYSQL_ADMIN_PASS" ]]; then
  warn "MySQL admin şifresi okunamadı, DB import atlanıyor"
elif [[ -f "dbs/db_list.txt" ]]; then
  DB_LIST=$(cat dbs/db_list.txt)
  LABEL="${TARGET//./_}"
  
  mkdir -p "./logs"
  
  for OLD_DB in $DB_LIST; do
    NEW_DB="${OLD_DB}_${LABEL}"
    info "  Oluşturuluyor: $OLD_DB → $NEW_DB"
    
    # Yeni DB ve user oluştur
    DB_USER="u_${LABEL}_$(openssl rand -hex 3)"
    DB_PASS="$(openssl rand -base64 18 | tr -d '\n=')"
    
    plesk bin database --create "$NEW_DB" -domain "$TARGET" -type mysql -server localhost
    plesk bin database --create-dbuser "$DB_USER" -passwd "$DB_PASS" -database "$NEW_DB" -domain "$TARGET" -type mysql -server localhost
    
    # Dump dosyasını import et
    if [[ -f "dbs/${OLD_DB}.sql.gz" ]]; then
      gunzip -c "dbs/${OLD_DB}.sql.gz" | mysql -u"$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" "$NEW_DB" || warn "Import hatası: $OLD_DB"
      info "    ✓ Import edildi"
    fi
    
    # Erişim bilgilerini kaydet
    echo "DB: $NEW_DB | User: $DB_USER | Pass: $DB_PASS" >> "./logs/${TARGET}_DB_INFO.txt"
  done
  
  [[ -f "./logs/${TARGET}_DB_INFO.txt" ]] && chmod 600 "./logs/${TARGET}_DB_INFO.txt"
  
  info "  ✓ Veritabanları oluşturuldu"
  info "  DB bilgileri: ./logs/${TARGET}_DB_INFO.txt"
else
  info "  Veritabanı dump'ı bulunamadı, atlanıyor"
fi

# 4. Sahiplik ve izinleri düzelt
info "4/5 İzinler düzeltiliyor..."

chown -R "$SYS_USER":psacln "/var/www/vhosts/$TARGET" || true
find "$DOCROOT_TGT" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "$DOCROOT_TGT" -type f -exec chmod 644 {} \; 2>/dev/null || true

info "  ✓ İzinler düzeltildi"

# 5. SSL (opsiyonel)
if [[ "$WITH_SSL" == "1" ]]; then
  info "5/5 Let's Encrypt SSL sertifikası oluşturuluyor..."
  
  EMAIL="admin@$(hostname -d 2>/dev/null || echo example.com)"
  plesk bin extension --exec letsencrypt cli.php -d "$TARGET" -m "$EMAIL" --agree-tos || warn "SSL oluşturulamadı"
  
  info "  ✓ SSL sertifikası oluşturuldu"
else
  info "5/5 SSL atlandı"
fi

bold "=== Uzak Klonlama Tamamlandı ==="
info "Yeni site: https://${TARGET}"
info ""
info "Yapılması gerekenler:"
info " - Uygulama config dosyalarını güncelleyin (.env, wp-config.php, vb.)"
info " - Yeni veritabanı bilgilerini kontrol edin: ./logs/${TARGET}_DB_INFO.txt"
info " - DNS ayarlarını güncelleyin"
info " - Site'yi test edin"
