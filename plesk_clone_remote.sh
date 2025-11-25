#!/usr/bin/env bash
set -euo pipefail

# Plesk Remote Clone Wrapper
# Aynı sunucuda veya farklı sunucuda domain klonlama
# Kullanım: ./plesk_clone_remote.sh -s SOURCE -t TARGET -o OWNER [opsiyonlar]

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[BİLGİ] %s\n" "$*"; }
warn(){ printf "\033[33m[UYARI]\033[0m %s\n" "$*"; }
err (){ printf "\033[31m[HATA]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

SOURCE=""
TARGET=""
OWNER=""
WITH_SSL=0
COPY_GIT=0
DRYRUN=0
REMOTE_MODE=""
REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PORT="22"

# Argüman parse
while (( "$#" )); do
  case "$1" in
    -s|--source) SOURCE="${2:-}"; shift 2 ;;
    -t|--target) TARGET="${2:-}"; shift 2 ;;
    -o|--owner)  OWNER="${2:-}";  shift 2 ;;
    --ssl)       WITH_SSL=1; shift ;;
    --copy-git)  COPY_GIT=1; shift ;;
    --dry-run)   DRYRUN=1; shift ;;
    -h|--help)
      cat <<EOF
Kullanım: $0 -s SOURCE -t TARGET -o OWNER [opsiyonlar]

Opsiyonlar:
  -s, --source    Kaynak domain
  -t, --target    Hedef domain
  -o, --owner     Hedef domain sahibi (Plesk kullanıcı)
  --ssl           Let's Encrypt SSL sertifikası oluştur
  --copy-git      Git repository'leri kopyala
  --dry-run       Test modu (değişiklik yapmaz)
  -h, --help      Bu yardımı göster

Örnekler:
  # Aynı sunucuda
  $0 -s demo.com -t staging.demo.com -o admin --ssl --copy-git

  # Farklı sunucuda
  $0 -s demo.com -t production.demo.com -o admin --ssl
EOF
      exit 0;;
    *)
      die "Bilinmeyen argüman: $1"
  esac
done

[[ -z "$SOURCE" || -z "$TARGET" || -z "$OWNER" ]] && die "SOURCE, TARGET ve OWNER zorunludur."

# Log dizini oluştur
mkdir -p ./logs

bold "=== Plesk Remote Clone Wrapper ==="
info "Kaynak: $SOURCE"
info "Hedef: $TARGET"
info "Owner: $OWNER"
(( WITH_SSL )) && info "SSL: AÇIK"
(( COPY_GIT )) && info "Git Kopyalama: AÇIK"
(( DRYRUN )) && warn "DRY-RUN modu aktif"

echo ""
echo "Hedef domain nerede oluşturulacak?"
echo "1) Bu sunucuda (local)"
echo "2) Farklı bir sunucuda (remote)"
read -p "Seçiminiz (1/2): " choice

case "$choice" in
  1)
    REMOTE_MODE="local"
    info "Yerel sunucu seçildi"
    ;;
  2)
    REMOTE_MODE="remote"
    info "Uzak sunucu seçildi"
    
    # SSH bilgilerini topla
    read -p "Uzak sunucu IP/hostname: " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && die "Uzak sunucu adresi gerekli"
    
    read -p "SSH kullanıcısı [root]: " input_user
    [[ -n "$input_user" ]] && REMOTE_USER="$input_user"
    
    read -p "SSH portu [22]: " input_port
    [[ -n "$input_port" ]] && REMOTE_PORT="$input_port"
    
    # SSH bağlantısını test et
    info "SSH bağlantısı test ediliyor: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
    if ! ssh -p "$REMOTE_PORT" -o ConnectTimeout=5 -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "exit" 2>/dev/null; then
      warn "SSH bağlantısı kurulamadı. SSH key authentication yapılandırılmış mı?"
      read -p "Devam etmek istiyor musunuz? (e/H): " continue_anyway
      [[ "$continue_anyway" != "e" && "$continue_anyway" != "E" ]] && die "İşlem iptal edildi"
    else
      info "✓ SSH bağlantısı başarılı"
    fi
    
    # Uzak sunucuda Plesk kontrolü
    info "Uzak sunucuda Plesk kontrolü yapılıyor..."
    if ! ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "command -v plesk >/dev/null 2>&1"; then
      die "Uzak sunucuda Plesk bulunamadı"
    fi
    info "✓ Uzak sunucuda Plesk tespit edildi"
    ;;
  *)
    die "Geçersiz seçim: $choice"
    ;;
esac

echo ""
bold "=== İşlem Özeti ==="
info "Mod: $REMOTE_MODE"
[[ "$REMOTE_MODE" == "remote" ]] && info "Hedef Sunucu: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
info "Kaynak Domain: $SOURCE"
info "Hedef Domain: $TARGET"
info "Owner: $OWNER"
echo ""

read -p "İşleme devam edilsin mi? (e/H): " confirm
[[ "$confirm" != "e" && "$confirm" != "E" ]] && die "İşlem iptal edildi"

# Local mode - mevcut script'i çalıştır
if [[ "$REMOTE_MODE" == "local" ]]; then
  info "Yerel klonlama başlatılıyor..."
  
  args="-s $SOURCE -t $TARGET -o $OWNER"
  (( WITH_SSL )) && args="$args --ssl"
  (( COPY_GIT )) && args="$args --copy-git"
  (( DRYRUN )) && args="$args --dry-run"
  
  exec ./plesk_clone_local.sh $args
fi

# Remote mode - paketleme ve transfer
if [[ "$REMOTE_MODE" == "remote" ]]; then
  bold "=== Remote Klonlama Başlıyor ==="
  
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  WORK_DIR="./remote_clone_${TIMESTAMP}"
  REMOTE_WORK_DIR="/tmp/plesk_clone_${TIMESTAMP}"
  
  info "Çalışma dizini: $WORK_DIR"
  mkdir -p "$WORK_DIR"/{files,dbs,scripts}
  
  # 1. Kaynak domain bilgilerini topla
  info "1/7 Kaynak domain bilgileri toplanıyor..."
  
  if ! plesk bin domain --info "$SOURCE" >/dev/null 2>&1; then
    die "Kaynak domain bulunamadı: $SOURCE"
  fi
  
  DOCROOT_SRC="/var/www/vhosts/$SOURCE/httpdocs"
  [[ ! -d "$DOCROOT_SRC" ]] && die "Kaynak docroot bulunamadı: $DOCROOT_SRC"
  
  # Domain bilgilerini JSON'a aktar
  cat > "$WORK_DIR/domain_info.json" <<EOF
{
  "source": "$SOURCE",
  "target": "$TARGET",
  "owner": "$OWNER",
  "with_ssl": $WITH_SSL,
  "copy_git": $COPY_GIT,
  "timestamp": "$TIMESTAMP"
}
EOF
  
  # 2. Dosyaları paketle
  info "2/7 Site dosyaları paketleniyor: $DOCROOT_SRC"
  (( DRYRUN )) || {
    tar -czf "$WORK_DIR/files/httpdocs.tar.gz" -C "$DOCROOT_SRC" . 2>/dev/null || die "Dosya paketleme başarısız"
    info "  ✓ Dosyalar paketlendi: $(du -h "$WORK_DIR/files/httpdocs.tar.gz" | cut -f1)"
  }
  
  # 3. Git dosyalarını paketle (opsiyonel)
  if (( COPY_GIT )); then
    info "3/7 Git dosyaları paketleniyor..."
    GIT_SRC="/var/www/vhosts/$SOURCE/git"
    if [[ -d "$GIT_SRC" ]]; then
      (( DRYRUN )) || {
        tar -czf "$WORK_DIR/files/git.tar.gz" -C "$GIT_SRC" . 2>/dev/null || warn "Git paketleme başarısız"
        [[ -f "$WORK_DIR/files/git.tar.gz" ]] && info "  ✓ Git paketlendi: $(du -h "$WORK_DIR/files/git.tar.gz" | cut -f1)"
      }
    else
      info "  Git klasörü bulunamadı, atlanıyor"
    fi
  else
    info "3/7 Git kopyalama kapalı, atlanıyor"
  fi
  
  # 4. Veritabanlarını dumpla
  info "4/7 Veritabanları dökülüyor..."
  MYSQL_ADMIN_USER="admin"
  MYSQL_ADMIN_PASS="$(cat /etc/psa/.psa.shadow 2>/dev/null || true)"
  
  if [[ -z "$MYSQL_ADMIN_PASS" ]]; then
    warn "MySQL admin şifresi okunamadı, DB atlanıyor"
  else
    DBS=$(plesk db -Ne "SELECT d.name FROM data_bases d JOIN domains dm ON dm.id=d.dom_id WHERE dm.name='$SOURCE';")
    
    if [[ -n "$DBS" ]]; then
      DB_COUNT=0
      for DB in $DBS; do
        (( DRYRUN )) || {
          info "  Dökülüyor: $DB"
          mysqldump -u"$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" --single-transaction --routines --triggers "$DB" | gzip > "$WORK_DIR/dbs/${DB}.sql.gz"
          DB_COUNT=$((DB_COUNT + 1))
        }
      done
      info "  ✓ $DB_COUNT veritabanı döküldü"
      
      # DB listesini kaydet
      echo "$DBS" > "$WORK_DIR/dbs/db_list.txt"
    else
      info "  Veritabanı bulunamadı"
    fi
  fi
  
  # 5. Remote runner script'i kopyala
  info "5/7 Remote runner script hazırlanıyor..."
  cp ./plesk_clone_remote_runner.sh "$WORK_DIR/scripts/" 2>/dev/null || {
    warn "plesk_clone_remote_runner.sh bulunamadı, oluşturuluyor..."
    # Script'i oluştur (bir sonraki adımda)
  }
  
  # 6. Dosyaları uzak sunucuya transfer et
  info "6/7 Dosyalar uzak sunucuya transfer ediliyor..."
  (( DRYRUN )) || {
    ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p $REMOTE_WORK_DIR"
    
    info "  rsync başlatılıyor..."
    rsync -avz --progress -e "ssh -p $REMOTE_PORT" \
      "$WORK_DIR/" \
      "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_WORK_DIR/" || die "Transfer başarısız"
    
    info "  ✓ Transfer tamamlandı"
  }
  
  # 7. Uzak sunucuda runner'ı çalıştır
  info "7/7 Uzak sunucuda klonlama başlatılıyor..."
  (( DRYRUN )) || {
    ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
      "cd $REMOTE_WORK_DIR && bash scripts/plesk_clone_remote_runner.sh" | tee "./logs/${TARGET}_remote_install.log"
    
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
      info "✓ Uzak klonlama başarılı"
    else
      warn "Uzak klonlama sırasında hatalar oluştu, logları kontrol edin"
    fi
    
    # Temizlik
    read -p "Uzak sunucudaki geçici dosyalar silinsin mi? (e/H): " cleanup
    if [[ "$cleanup" == "e" || "$cleanup" == "E" ]]; then
      ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "rm -rf $REMOTE_WORK_DIR"
      info "✓ Uzak sunucuda temizlik yapıldı"
    fi
  }
  
  # Yerel temizlik
  info "Yerel geçici dosyalar temizleniyor: $WORK_DIR"
  (( DRYRUN )) || rm -rf "$WORK_DIR"
  
  bold "=== İşlem Tamamlandı ==="
  info "Hedef site: https://${TARGET}"
  info "Log dosyası: ./logs/${TARGET}_remote_install.log"
fi
