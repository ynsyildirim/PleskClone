#!/usr/bin/env bash
set -euo pipefail

# Plesk same-server FULL clone (files + DBs + cron + optional SSL + optional Git)
# Tested on Plesk Obsidian 18.x (Debian/Ubuntu/CentOS/Alma/Rocky)
# Usage:
#   /bin/sh plesk_clone.sh -s SOURCE -t TARGET -o OWNER [--ssl] [--copy-git] [--dry-run]
#
# Examples:
#   /bin/sh plesk_clone.sh -s example.com -t staging.example.com -o admin --ssl --copy-git
#   /bin/sh plesk_clone.sh -s app.com -t test.app.com -o mycustomer
#
# Notes:
# - DB password import uses MySQL admin creds from /etc/psa/.psa.shadow (standard on Plesk)
# - New DB names are suffixed with target label to avoid collision.
# - App config (.env, wp-config.php) is NOT auto-rewritten; print hints at the end.

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
err (){ printf "\033[31m[ERR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

SOURCE=""
TARGET=""
OWNER=""
WITH_SSL=0
COPY_GIT=0
FIX_GIT_ONLY=0
DRYRUN=0

# ---- parse args ----
while (( "$#" )); do
  case "$1" in
    -s|--source) SOURCE="${2:-}"; shift 2 ;;
    -t|--target) TARGET="${2:-}"; shift 2 ;;
    -o|--owner)  OWNER="${2:-}";  shift 2 ;;
    --ssl)       WITH_SSL=1; shift ;;
    --copy-git)  COPY_GIT=1; shift ;;
    --fix-git)   FIX_GIT_ONLY=1; shift ;;
    --dry-run)   DRYRUN=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 -s SOURCE -t TARGET -o OWNER [--ssl] [--copy-git] [--fix-git] [--dry-run]
  --fix-git   Sadece Git entegrasyonunu düzelt (domain zaten var ise)
EOF
      exit 0;;
    *)
      die "Unknown arg: $1"
  esac
done

[[ -z "$SOURCE" || -z "$TARGET" || -z "$OWNER" ]] && die "SOURCE, TARGET, OWNER zorunlu."

[[ -f "./logs/${TARGET}_DB_INFO.txt" ]] && echo " - Yeni DB erişim bilgileri: ./logs/${TARGET}_DB_INFO.txt (600)"
[[ -f "./logs/${TARGET}_SYS_INFO.txt" ]] && echo " - Sistem kullanıcı bilgileri: ./logs/${TARGET}_SYS_INFO.txt (600)"

# ---- sanity checks ----
command -v plesk >/dev/null 2>&1 || die "plesk CLI bulunamadı."
command -v rsync >/dev/null 2>&1 || die "rsync gerekli."
if ! plesk bin domain --info "$SOURCE" >/dev/null 2>&1; then
  die "Kaynak domain bulunamadı: $SOURCE"
fi
if plesk bin domain --info "$TARGET" >/dev/null 2>&1; then
  warn "Hedef domain zaten var: $TARGET (dosya/DB üzerine yazılabilir!)"
fi

get_system_user () {
  local domain="$1"
  plesk db -Ne "SELECT su.login
  FROM sys_users su
  JOIN hosting h ON h.sys_user_id=su.id
  JOIN domains d ON d.id=h.dom_id
  WHERE d.name='${domain}';"
}

get_service_plan_from_source () {
  local domain="$1"
  # Try multiple variations of service plan field names
  local plan
  plan="$(plesk bin domain --info "$domain" | awk -F': ' '/^Service plan/ {print $2; exit}')"
  [[ -n "$plan" ]] && { echo "$plan"; return; }
  
  plan="$(plesk bin domain --info "$domain" | awk -F': ' '/^Plan/ {print $2; exit}')"
  [[ -n "$plan" ]] && { echo "$plan"; return; }
  
  # Try subscription info instead
  plan="$(plesk bin subscription --info "$domain" 2>/dev/null | awk -F': ' '/^Service plan/ {print $2; exit}' || true)"
  [[ -n "$plan" ]] && { echo "$plan"; return; }
  
  # Fallback: get from database
  plan="$(plesk db -Ne "
    SELECT sp.name 
    FROM ServicePlans sp 
    JOIN domains d ON d.plan_id = sp.id 
    WHERE d.name = '$domain' LIMIT 1;
  " 2>/dev/null || true)"
  [[ -n "$plan" ]] && echo "$plan"
}

# helper: get field from "plesk bin domain -i"
get_field () {
  local domain="$1" key="$2"
  plesk bin domain -i "$domain" | awk -F': ' -v k="$key" '$1==k {print $2}'
}

# SQL injection'dan kaçınmak için string'i escape et
sql_escape () {
  local input="$1"
  printf '%s\n' "$input" | sed "s/'/''/g"
}

SYSTEM_USER_SRC="$(get_system_user "$SOURCE")"
[[ -z "$SYSTEM_USER_SRC" ]] && die "Kaynak sistem kullanıcısı okunamadı (PSA DB boş döndü). Domain adı doğru mu? Hosting atanmış mı?"

# Gerçek vhost home dizinini PSA'dan oku (addon/subdomain-as-domain gibi durumlarda
# gerçek yol /var/www/vhosts/<domain>/ kalıbından farklı olabilir)
get_home_dir () {
  local domain="$1"
  plesk db -Ne "
    SELECT su.home
    FROM sys_users su
    JOIN hosting h ON h.sys_user_id = su.id
    JOIN domains d ON d.id = h.dom_id
    WHERE d.name='$(sql_escape "$domain")' LIMIT 1;" 2>/dev/null
}

get_docroot () {
  local domain="$1" home="$2"
  local www_root
  www_root="$(plesk db -Ne "
    SELECT h.www_root
    FROM hosting h
    JOIN domains d ON d.id = h.dom_id
    WHERE d.name='$(sql_escape "$domain")' LIMIT 1;" 2>/dev/null)"
  [[ -z "$www_root" ]] && www_root="httpdocs"
  printf '%s/%s' "${home%/}" "$www_root"
}

HOME_SRC="$(get_home_dir "$SOURCE")"
[[ -z "$HOME_SRC" ]] && HOME_SRC="/var/www/vhosts/$SOURCE"
DOCROOT_SRC="$(get_docroot "$SOURCE" "$HOME_SRC")"
[[ -d "$DOCROOT_SRC" ]] || die "Kaynak doküman kökü bulunamadı: $DOCROOT_SRC (domain bir subdomain/addon domain ise gerçek dosya yolu farklı olabilir, PSA'daki hosting kaydını kontrol edin)"

# Hedef henüz oluşturulmadı; create_target_domain sonrası gerçek değerlerle güncellenecek
HOME_TGT="/var/www/vhosts/$TARGET"
DOCROOT_TGT="$HOME_TGT/httpdocs"

IP_SRC="$(get_field "$SOURCE" "IP address")"
[[ -z "$IP_SRC" ]] && IP_SRC="$(hostname -I | awk '{print $1}')"

SERVICE_PLAN="$(get_service_plan_from_source "$SOURCE" || true)"
if [[ -z "$SERVICE_PLAN" ]]; then
  SERVICE_PLAN="Unlimited"
  warn "Kaynak servis planı tespit edilemedi, '$SERVICE_PLAN' ile devam."
else
  info "Kaynak servis planı: $SERVICE_PLAN"
fi


MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASS="$(cat /etc/psa/.psa.shadow 2>/dev/null || true)"
if [[ -z "$MYSQL_ADMIN_PASS" ]]; then
  warn "/etc/psa/.psa.shadow okunamadı; MySQL dump/import için admin parola gerekir."
fi

# list domain DBs via psa
list_domain_dbs() {
  local domain="$1"
  plesk db -Ne "SELECT d.name FROM data_bases d
    JOIN domains dm ON dm.id=d.dom_id
   WHERE dm.name='$domain';"
}

# create domain if missing
create_target_domain () {
  if plesk bin domain --info "$TARGET" >/dev/null 2>&1; then
    info "Hedef domain mevcut: $TARGET (atla)"
    return
  fi
  info "Hedef domain oluşturuluyor: $TARGET (owner=$OWNER, plan=$SERVICE_PLAN, ip=$IP_SRC)"
  (( DRYRUN )) && return
  
  # Hosting için gerekli sistem kullanıcı bilgilerini oluştur
  local sys_user="${TARGET//./_}"  # domain.com -> domain_com
  local sys_pass; sys_pass="$(openssl rand -base64 16 | tr -d '\n=')"
  
  info "Sistem kullanıcısı: $sys_user"
  
  # Domain'i hosting ile birlikte oluştur
  plesk bin domain --create "$TARGET" \
      -owner "$OWNER" \
      -service-plan "$SERVICE_PLAN" \
      -ip "$IP_SRC" \
      -login "$sys_user" \
      -passwd "$sys_pass" \
      -hosting true
  
  # Sistem kullanıcı bilgilerini kaydet
  mkdir -p "./logs"
  echo "System user: $sys_user ; Password: $sys_pass" >> "./logs/${TARGET}_SYS_INFO.txt"
  chmod 600 "./logs/${TARGET}_SYS_INFO.txt"
}

# copy PHP handler version (best-effort)
copy_php_handler () {
  # Önce sync-subscription seçeneğinin mevcut olup olmadığını kontrol et
  if plesk bin subscription_settings --help 2>&1 | grep -q "sync-subscription"; then
    info "Plan ayarları eşitleniyor (sync-subscription)"
    plesk bin subscription_settings --update "$TARGET" -sync-subscription "$SOURCE" || warn "Plan ayarları eşitlenemedi"
  else
    info "sync-subscription seçeneği mevcut değil, PHP handler manuel olarak kopyalanıyor"
  fi

  # Kaynaktan PHP versiyonu/handler ID'yi PSA'dan oku
  local handler_id_src
  handler_id_src="$(plesk db -Ne "
    SELECT ph.id
    FROM Domains d
    JOIN hosting h ON h.dom_id=d.id
    JOIN php_settings ps ON ps.id=h.php_settings_id
    JOIN php_handlers ph ON ph.id=ps.handler_id
    WHERE d.name='${SOURCE}' LIMIT 1;
  " 2>/dev/null || true)"
  
  if [[ -n "$handler_id_src" ]]; then
    info "PHP handler eşitleniyor: $handler_id_src"
    plesk bin domain --update "$TARGET" -php-handler-id "$handler_id_src" || warn "PHP handler güncellenemedi"
  else
    # Alternatif yöntem: PHP sürümünü direkt okuyup ayarla
    local php_version_src
    php_version_src="$(plesk db -Ne "
      SELECT CONCAT(ph.version, '.', ph.custom_version)
      FROM Domains d
      JOIN hosting h ON h.dom_id=d.id
      JOIN php_settings ps ON ps.id=h.php_settings_id
      JOIN php_handlers ph ON ph.id=ps.handler_id
      WHERE d.name='${SOURCE}' LIMIT 1;
    " 2>/dev/null || true)"
    
    if [[ -n "$php_version_src" ]]; then
      info "PHP versiyonu tespit edildi: $php_version_src"
      plesk bin domain --update "$TARGET" -php-version "$php_version_src" || warn "PHP versiyonu ayarlanamadı"
    else
      warn "PHP handler ve versiyonu DB'den tespit edilemedi; varsayılan plan ayarları kullanılacak."
    fi
  fi
}

# copy SSH access settings
copy_ssh_settings () {
  info "SSH erişim ayarları kopyalanıyor..."
  
  # Kaynaktan SSH shell ayarını al
  local ssh_shell_src
  ssh_shell_src="$(plesk db -Ne "
    SELECT su.shell
    FROM sys_users su
    JOIN hosting h ON h.sys_user_id = su.id
    JOIN domains d ON d.id = h.dom_id
    WHERE d.name='${SOURCE}' LIMIT 1;
  " 2>/dev/null || true)"
  
  if [[ -n "$ssh_shell_src" ]]; then
    info "Kaynak SSH shell: $ssh_shell_src"
    
    # Hedef domain'in mevcut SSH ayarını kontrol et
    local ssh_shell_tgt
    ssh_shell_tgt="$(plesk db -Ne "
      SELECT su.shell
      FROM sys_users su
      JOIN hosting h ON h.sys_user_id = su.id
      JOIN domains d ON d.id = h.dom_id
      WHERE d.name='${TARGET}' LIMIT 1;
    " 2>/dev/null || true)"
    
    if [[ "$ssh_shell_src" != "$ssh_shell_tgt" ]]; then
      info "SSH ayarı güncelleniyor: $ssh_shell_tgt -> $ssh_shell_src"
      (( DRYRUN )) && return
      
      # SSH ayarını güncelle
      if [[ "$ssh_shell_src" == "/bin/false" ]]; then
        plesk bin domain --update "$TARGET" -shell false || warn "SSH deaktivasyonu başarısız"
      else
        plesk bin domain --update "$TARGET" -shell "$ssh_shell_src" || warn "SSH aktivasyonu başarısız"
      fi
      
      info "✓ SSH ayarı başarıyla güncellendi"
    else
      info "SSH ayarı zaten uyumlu: $ssh_shell_src"
    fi
  else
    warn "Kaynak SSH ayarı okunamadı"
  fi
}

# rsync files
sync_files () {
  info "Dosyalar kopyalanıyor (rsync): $DOCROOT_SRC -> $DOCROOT_TGT"
  (( DRYRUN )) && return
  
  # Hedef dizini oluştur ve temel izinleri ayarla
  mkdir -p "$DOCROOT_TGT"
  
  # Hedef sistem kullanıcısını al ve dizin sahipliğini ayarla
  local sys_tgt; sys_tgt="$(get_system_user "$TARGET")"
  if [[ -n "$sys_tgt" ]]; then
    info "Hedef dizin sahipliği ayarlanıyor: $sys_tgt"
    chown "$sys_tgt":psacln "$HOME_TGT" || true
    chown "$sys_tgt":psacln "$DOCROOT_TGT" || true
    chmod 755 "$HOME_TGT" || true
    chmod 755 "$DOCROOT_TGT" || true
  fi
  
  # rsync ile dosyaları kopyala
  rsync -a --delete "$DOCROOT_SRC"/ "$DOCROOT_TGT"/
}

# domain replacement in files (critical for config files)
replace_domain_in_files () {
  info "Dosyalarda domain replacement yapılıyor: $SOURCE -> $TARGET"
  (( DRYRUN )) && return
  
  # Common config files to search and replace
  local config_files=(
    ".env"
    ".env.local" 
    ".env.production"
    "wp-config.php"
    "config.php"
    "settings.php"
    "app.config"
    "web.config"
    "composer.json"
    "package.json"
  )
  
  local files_modified=0
  
  # Search in httpdocs for config files
  for config_file in "${config_files[@]}"; do
    find "$DOCROOT_TGT" -name "$config_file" -type f 2>/dev/null | while read -r file; do
      if grep -q "$SOURCE" "$file" 2>/dev/null; then
        info "  Domain replacement: $(basename "$file")"
        # Create backup
        cp "$file" "${file}.backup.$(date +%s)" || true
        # Replace domain (case insensitive)
        sed -i.tmp "s|$SOURCE|$TARGET|gi" "$file" 2>/dev/null || true
        rm -f "${file}.tmp" 2>/dev/null || true
        files_modified=$((files_modified + 1))
      fi
    done
  done
  
  # Also search for common database URLs and paths
  find "$DOCROOT_TGT" -type f \( -name "*.php" -o -name "*.js" -o -name "*.json" -o -name "*.xml" -o -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | while read -r file; do
    if grep -q "://.*$SOURCE\|https\?://[^/]*$SOURCE\|$SOURCE/\|@$SOURCE" "$file" 2>/dev/null; then
      info "  URL replacement: $(basename "$file")"
      cp "$file" "${file}.backup.$(date +%s)" || true
      sed -i.tmp -E "s|(['\"])([^'\"]*$SOURCE[^'\"]*)\1|\1$(echo "\2" | sed "s|$SOURCE|$TARGET|g")\1|g" "$file" 2>/dev/null || true
      rm -f "${file}.tmp" 2>/dev/null || true
      files_modified=$((files_modified + 1))
    fi
  done
  
  if [[ $files_modified -gt 0 ]]; then
    info "✓ $files_modified dosyada domain replacement tamamlandı"
  else
    info "Domain replacement için uygun dosya bulunamadı"
  fi
}

# copy composer directory and cache (optional)
copy_composer () {
  local src_composer="$HOME_SRC/.composer"
  local tgt_composer="$HOME_TGT/.composer"
  
  if [[ -d "$src_composer" ]]; then
    info "Composer klasörü kopyalanıyor: $src_composer -> $tgt_composer"
    (( DRYRUN )) && return
    
    # .composer klasörünü kopyala
    rsync -a "$src_composer"/ "$tgt_composer"/
    
    # Sahiplik düzelt
    local sys_tgt; sys_tgt="$(get_system_user "$TARGET")"
    if [[ -n "$sys_tgt" ]]; then
      chown -R "$sys_tgt":psacln "$tgt_composer" || true
      chmod -R 755 "$tgt_composer" || true
    fi
    
    # Composer cache temizle (opsiyonel - yeni environment için)
    if [[ -d "$tgt_composer/cache" ]]; then
      info "  Composer cache temizleniyor"
      rm -rf "$tgt_composer/cache"/* 2>/dev/null || true
    fi
    
    info "✓ Composer klasörü başarıyla kopyalandı"
  else
    info "Kaynak domain'de .composer klasörü bulunamadı, atlanıyor"
  fi
}

# git copy (optional)
copy_git () {
  [[ $COPY_GIT -eq 1 ]] || return
  
  local git_src_plesk="$HOME_SRC/git"
  local git_tgt_plesk="$HOME_TGT/git"
  local git_repos_found=0
  
  # Önce Plesk Git entegrasyonu kontrol et (birden fazla repo olabilir)
  if [[ -d "$git_src_plesk" ]]; then
    info "Plesk Git klasörü bulundu: $git_src_plesk"
    
    # Git klasöründeki tüm repo'ları listele
    local repos
    repos=($(find "$git_src_plesk" -maxdepth 2 -name "*.git" -type d 2>/dev/null || true))
    
    if [[ ${#repos[@]} -gt 0 ]]; then
      info "Toplam ${#repos[@]} Git deposu bulundu"
      (( DRYRUN )) || mkdir -p "$git_tgt_plesk"
      
      for repo in "${repos[@]}"; do
        local repo_name=$(basename "$repo")
        local repo_path=$(dirname "$repo")
        local relative_path=${repo_path#$git_src_plesk}
        # Remove leading slash if present
        relative_path=${relative_path#/}
        
        info "Git deposu kopyalanıyor: $repo_name (path: $relative_path)"
        
        if (( DRYRUN )); then
          continue
        fi
        
        # Hedef klasör yapısını oluştur - her repo kendi klasörünü korur
        local target_repo_dir="$git_tgt_plesk"
        if [[ -n "$relative_path" ]]; then
          target_repo_dir="$git_tgt_plesk/$relative_path"
          mkdir -p "$target_repo_dir"
        else
          # Ana klasördeyse, repo adıyla klasör oluştur
          mkdir -p "$git_tgt_plesk"
        fi
        
        # Repo'yu tam yol yapısıyla kopyala (.git uzantılı olarak)
        if [[ -n "$relative_path" ]]; then
          rsync -a "$repo" "$target_repo_dir/"
        else
          # Ana klasördeki repo'ları doğrudan kopyala
          rsync -a "$repo" "$git_tgt_plesk/"
        fi
        
        # Git working directory ayarlama (ana repo için)
        local git_dir_path
        if [[ -n "$relative_path" ]]; then
          git_dir_path="$target_repo_dir/$repo_name"
        else
          git_dir_path="$git_tgt_plesk/$repo_name"
        fi
        
        # Ana dizindeki ana repo için working tree ayarla (sadece non-bare repository'ler için)
        if [[ -z "$relative_path" && -f "$git_dir_path/config" ]]; then
          # Bare repository kontrolü
          local is_bare
          is_bare=$(git --git-dir="$git_dir_path" config --get core.bare 2>/dev/null || echo "false")
          
          if [[ "$is_bare" != "true" ]]; then
            info "Ana repository için çalışma dizini ayarlanıyor: $repo_name"
            cd "$HOME_TGT" || warn "Hedef dizine geçilemedi"
            git --git-dir="$git_dir_path" --work-tree="$DOCROOT_TGT" reset --hard HEAD 2>/dev/null || warn "Git reset uyarı verdi: $repo_name"
            git --git-dir="$git_dir_path" --work-tree="$DOCROOT_TGT" clean -fd 2>/dev/null || warn "Git clean uyarı verdi: $repo_name"
          else
            info "Bare repository tespit edildi, working tree ayarlanmıyor: $repo_name"
          fi
        fi
        
        git_repos_found=$((git_repos_found + 1))
      done
      
      # Plesk Git klasörünün tamamını kopyala (config dosyaları vs için)
      info "Plesk Git yapılandırma dosyları kopyalanıyor"
      rsync -a --exclude="*.git" "$git_src_plesk"/ "$git_tgt_plesk"/
      
      # Git dosyalarının sahipliğini düzelt
      local sys_tgt; sys_tgt="$(get_system_user "$TARGET")"
      if [[ -n "$sys_tgt" ]]; then
        info "Git klasörü sahipliği düzeltiliyor: $sys_tgt"
        chown -R "$sys_tgt":psacln "$git_tgt_plesk" || warn "Git sahiplik düzeltmesi başarısız"
      fi
      
      # Plesk Git Extension için sanal klasörler oluştur
      create_git_symlinks
      
      # Git klasörü hazır
      
    else
      # Git klasörü var ama repo yok, tüm klasörü kopyala
      info "Git klasöründe .git bulunamadı, tüm klasör kopyalanıyor"
      if (( DRYRUN )); then
        git_repos_found=1
      else
        rsync -a "$git_src_plesk"/ "$git_tgt_plesk"/
        
        # Sahiplik düzelt
        local sys_tgt; sys_tgt="$(get_system_user "$TARGET")"
        if [[ -n "$sys_tgt" ]]; then
          info "Git klasörü sahipliği düzeltiliyor: $sys_tgt"
          chown -R "$sys_tgt":psacln "$git_tgt_plesk" || warn "Git sahiplik düzeltmesi başarısız"
        fi
        git_repos_found=1
      fi
    fi
  fi
  
  if [[ $git_repos_found -eq 0 ]]; then
    warn "Hiçbir Git deposu bulunamadı (Plesk: $git_src_plesk)"
  else
    info "Toplam $git_repos_found Git deposu kopyalandı"
    
    # Git SQLite ayarlarını senkronize et (profesyonel tek sorgu yaklaşımı)
    sync_git_database_settings
  fi
}

# Git repository'leri için sanal klasörler (symlink'ler) oluştur
create_git_symlinks () {
  local git_dir="$HOME_TGT/git"
  
  if [[ ! -d "$git_dir" ]]; then
    return
  fi
  
  # Eksik sanal klasörleri kontrol et ve sadece eksikleri oluştur
  local symlinks_created=0
  local total_repos=0
  
  for repo_path in "$git_dir"/*.git; do
    if [[ -d "$repo_path" ]]; then
      total_repos=$((total_repos + 1))
      local repo_name=$(basename "$repo_path")
      local base_name="${repo_name%.git}"
      local symlink_path="$git_dir/$base_name"
      
      # Sanal klasör yoksa oluştur (varsa es geç)
      if [[ ! -e "$symlink_path" ]]; then
        if ln -sf "$repo_name" "$symlink_path"; then
          symlinks_created=$((symlinks_created + 1))
          info "  ✓ Sanal klasör oluşturuldu: $base_name -> $repo_name"
        else
          warn "  ✗ Sanal klasör oluşturulamadı: $base_name"
        fi
      fi
    fi
  done
  
  # Sonuç raporu
  if [[ $symlinks_created -gt 0 ]]; then
    info "✓ Git sanal klasörler: $symlinks_created oluşturuldu ($total_repos toplam)"
  else
    info "Git sanal klasörler: Tümü zaten mevcut ($total_repos toplam)"
  fi
}

# Git SQLite ayarlarını senkronize et (--copy-git için)
sync_git_database_settings () {
  info "Git Extension SQLite veritabanı ayarları senkronize ediliyor..."
  
  # Kaynak ve hedef domain ID'lerini al
  local src_domain_id tgt_domain_id
  src_domain_id="$(plesk db -Ne "SELECT id FROM domains WHERE name = '$SOURCE' LIMIT 1;" 2>/dev/null || true)"
  tgt_domain_id="$(plesk db -Ne "SELECT id FROM domains WHERE name = '$TARGET' LIMIT 1;" 2>/dev/null || true)"
  
  if [[ -z "$src_domain_id" || -z "$tgt_domain_id" ]]; then
    warn "Kaynak veya hedef domain ID'si bulunamadı, Git SQLite senkronizasyonu atlanıyor"
    return
  fi
  
  # Git extension'ının SQLite veritabanı yolu
  local git_db_path="/usr/local/psa/var/modules/git/git_db.db"
  
  if [[ ! -f "$git_db_path" ]]; then
    warn "Git Extension SQLite veritabanı bulunamadı: $git_db_path"
    return
  fi
  
  # TEK SQL komutu ile UPSERT (INSERT yada UPDATE) - sadece yeni veya değişen repolar işlenir
  info "Git repository ayarları UPSERT ile senkronize ediliyor..."
  
  local copy_result
  copy_result=$(sqlite3 "$git_db_path" "
    INSERT OR REPLACE INTO Repositories 
    (domainId, name, type, deploymentMode, branch, deploymentPath, fetchUrl, uuid, 
     skipSslVerification, postDeploymentActionsEnabled, deploymentsCounter, 
     deployKeyUuid, postDeploymentActions, httpUser, httpPassword, smbUserIds)
    SELECT 
      $tgt_domain_id AS domainId,
      CASE WHEN s.name LIKE '%.git' THEN SUBSTR(s.name, 1, LENGTH(s.name)-4) ELSE s.name END AS name,
      s.type,
      s.deploymentMode,
      s.branch,
      REPLACE(s.deploymentPath, '$SOURCE', '$TARGET') AS deploymentPath,
      s.fetchUrl,
      COALESCE(t.uuid, LOWER(HEX(RANDOMBLOB(4)) || '-' || HEX(RANDOMBLOB(2)) || '-4' || SUBSTR(HEX(RANDOMBLOB(2)), 2) || '-' || 
               CASE (ABS(RANDOM()) % 4) WHEN 0 THEN '8' WHEN 1 THEN '9' WHEN 2 THEN 'a' ELSE 'b' END || 
               SUBSTR(HEX(RANDOMBLOB(2)), 2) || '-' || HEX(RANDOMBLOB(6)))) AS uuid,
      s.skipSslVerification,
      s.postDeploymentActionsEnabled,
      s.deploymentsCounter,
      COALESCE(t.deployKeyUuid, LOWER(HEX(RANDOMBLOB(4)) || '-' || HEX(RANDOMBLOB(2)) || '-4' || SUBSTR(HEX(RANDOMBLOB(2)), 2) || '-' || 
               CASE (ABS(RANDOM()) % 4) WHEN 0 THEN '8' WHEN 1 THEN '9' WHEN 2 THEN 'a' ELSE 'b' END || 
               SUBSTR(HEX(RANDOMBLOB(2)), 2) || '-' || HEX(RANDOMBLOB(6)))) AS deployKeyUuid,
      CASE WHEN s.postDeploymentActions IS NULL THEN NULL 
           ELSE REPLACE(s.postDeploymentActions, '$SOURCE', '$TARGET') END AS postDeploymentActions,
      NULL, NULL, NULL
    FROM Repositories s
    LEFT JOIN Repositories t ON (t.domainId = $tgt_domain_id AND t.name = CASE WHEN s.name LIKE '%.git' THEN SUBSTR(s.name, 1, LENGTH(s.name)-4) ELSE s.name END)
    WHERE s.domainId = $src_domain_id
      AND (t.uuid IS NULL OR 
           t.deploymentPath != REPLACE(s.deploymentPath, '$SOURCE', '$TARGET') OR
           t.type != s.type OR 
           t.branch != s.branch OR
           t.fetchUrl != s.fetchUrl);
  " 2>&1)
  
  if [[ $? -eq 0 ]]; then
    # Kopyalanan repository sayısını öğren
    local repo_count
    repo_count=$(sqlite3 "$git_db_path" "SELECT COUNT(*) FROM Repositories WHERE domainId = $tgt_domain_id;" 2>/dev/null || echo "0")
    info "✓ Toplam $repo_count repository SQLite'da senkronize edildi"
    
    # Deploy key'ler ve SSH anahtarları oluştur
    info "Deploy key'ler ve SSH anahtarları oluşturuluyor..."
    
    # Hedef domain GUID'ini al
    local domain_guid
    domain_guid="$(plesk db -Ne "SELECT guid FROM domains WHERE id = $tgt_domain_id;" 2>/dev/null || true)"
    
    # Her repository için deploy key işlemleri
    sqlite3 "$git_db_path" "SELECT name, uuid, deployKeyUuid, deploymentPath, postDeploymentActionsEnabled FROM Repositories WHERE domainId = $tgt_domain_id;" 2>/dev/null | while IFS='|' read -r repo_name repo_uuid deploy_key_uuid repo_path actions_enabled; do
      info "  Repository: $repo_name"
      info "    - Deployment Path: $repo_path"
      info "    - Actions Enabled: $actions_enabled"
      
      # SSH key dosya yolları
      local git_keys_dir="/usr/local/psa/var/modules/git/keys"
      mkdir -p "$git_keys_dir" 2>/dev/null || true
      local key_path="$git_keys_dir/$deploy_key_uuid"
      
      # SSH key çifti oluştur
      if [[ ! -f "$key_path" ]]; then
        info "    - SSH key oluşturuluyor: $deploy_key_uuid"
        ssh-keygen -t rsa -b 4096 -f "$key_path" -N "" -C "plesk-git-$repo_name@$TARGET" 2>/dev/null || {
          warn "    - SSH key oluşturulamadı: $repo_name"
          continue
        }
        
        # Anahtar dosyalarının sahipliğini ve izinlerini düzelt
        chown root:root "$key_path" "$key_path.pub" 2>/dev/null || true
        chmod 600 "$key_path" 2>/dev/null || true
        chmod 644 "$key_path.pub" 2>/dev/null || true
        
        info "    - SSH key başarıyla oluşturuldu"
      else
        info "    - SSH key zaten mevcut"
      fi
      
      # DeployKeys tablosuna kayıt ekle (Plesk UI için gerekli)
      if [[ -n "$domain_guid" ]]; then
        sqlite3 "$git_db_path" "INSERT OR REPLACE INTO DeployKeys (uuid, domainUuid, name, isDefault) VALUES ('$deploy_key_uuid', '$domain_guid', '$repo_name', 1);" 2>/dev/null && {
          info "    - DeployKeys tablosuna kayıt eklendi"
        } || {
          warn "    - DeployKeys kaydı eklenemedi: $repo_name"
        }
      fi
      
      # RepositoryDeploymentInfo tablosuna kayıt ekle (deployment tracking için)
      sqlite3 "$git_db_path" "INSERT OR REPLACE INTO RepositoryDeploymentInfo (repoUuid, lastCommitHash, deployedCommitHash, deployedCommitAuthor, deployedCommitDate, deployedCommitMessage) VALUES ('$repo_uuid', NULL, NULL, NULL, NULL, NULL);" 2>/dev/null && {
        info "    - RepositoryDeploymentInfo tablosuna kayıt eklendi"
      } || {
        warn "    - RepositoryDeploymentInfo kaydı eklenemedi: $repo_name"
      }
      
      # Public key'i göster (kullanıcı için)
      if [[ -f "$key_path.pub" ]]; then
        local pub_key_content
        pub_key_content=$(cat "$key_path.pub" 2>/dev/null || echo "Okunamadı")
        info "    - Public Key: ${pub_key_content:0:50}..."
      fi
    done
    
    info "✓ Git Extension SQLite - Toplam $repo_count repository senkronize edildi"
  else
    warn "Git SQLite senkronizasyon başarısız: $copy_result"
  fi
}





# clone DBs (MySQL/MariaDB) using admin creds
clone_dbs () {
  local dbs newdb label db_count=0
  dbs="$(list_domain_dbs "$SOURCE" || true)"
  
  if [[ -z "$dbs" ]]; then
    info "Kaynak domain'de MySQL veritabanı bulunamadı, atlanıyor."
    return
  fi

  # Toplam veritabanı sayısını hesapla
  local total_dbs
  total_dbs=$(echo "$dbs" | wc -w)
  info "Kaynak domain'de $total_dbs MySQL veritabanı bulundu, kopyalanacak..."

  # label: target domain dots -> underscores
  label="${TARGET//./_}"

  for DB in $dbs; do
    db_count=$((db_count + 1))
    newdb="${DB}_${label}"
    info "[$db_count/$total_dbs] MySQL veritabanı kopyalanıyor: $DB -> $newdb"

    if (( DRYRUN )); then
      continue
    fi

    # dump
    mysqldump -u"$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" --single-transaction --routines --triggers "$DB" | gzip > "/tmp/${DB}.sql.gz"

    # create db + user (random pass)
    local dbuser="u_${label}_$(openssl rand -hex 3)"
    local dbpass; dbpass="$(openssl rand -base64 18 | tr -d '\n=')"

    plesk bin database --create "$newdb" -domain "$TARGET" -type mysql -server localhost
    plesk bin database --create-dbuser "$dbuser" -passwd "$dbpass" -database "$newdb" -domain "$TARGET" -type mysql -server localhost

    # import
    gunzip -c "/tmp/${DB}.sql.gz" | mysql -u"$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" "$newdb"

    # secure cleanup
    shred -u "/tmp/${DB}.sql.gz" || rm -f "/tmp/${DB}.sql.gz"

    echo "DB created: $newdb ; USER: $dbuser ; PASS: $dbpass" >> "./logs/${TARGET}_DB_INFO.txt"
    info "  ✓ Veritabanı başarıyla oluşturuldu ve import edildi"
  done
  
  [[ -f "./logs/${TARGET}_DB_INFO.txt" ]] && chmod 600 "./logs/${TARGET}_DB_INFO.txt"
  info "✓ Toplam $db_count MySQL veritabanı başarıyla kopyalandı"
}

# copy scheduled tasks (crontab) from source system user to target system user
copy_cron () {
  local sys_src="$SYSTEM_USER_SRC"
  local sys_tgt
  sys_tgt="$(get_system_user "$TARGET")"
  if [[ -z "$sys_tgt" ]]; then
    warn "Hedef sistem kullanıcısı okunamadı, cron atlanıyor."
    return
  fi

  info "Cron kopyalanıyor: $sys_src -> $sys_tgt"
  if (( DRYRUN )); then
    return
  fi
  if crontab -l -u "$sys_src" >/dev/null 2>&1; then
    crontab -l -u "$sys_src" | crontab -u "$sys_tgt" - || warn "crontab aktarımında sorun."
  else
    info "Kaynakta kullanıcı cron’u yok, atlanıyor."
  fi
}

# permissions
fix_perms () {
  local sys_tgt; sys_tgt="$(get_system_user "$TARGET")"
  [[ -z "$sys_tgt" ]] && { warn "Hedef sistem kullanıcısı bulunamadı; izin düzeltme atlandı."; return; }
  info "İzinler düzeltiliyor (owner=$sys_tgt, group=psacln)"
  (( DRYRUN )) && return
  
  # Ana domain klasörünün izinlerini düzelt
  local domain_root="$HOME_TGT"
  if [[ -d "$domain_root" ]]; then
    chown "$sys_tgt":psacln "$domain_root" || true
    chmod 755 "$domain_root" || true
  fi
  
  # httpdocs ve alt klasörlerin izinlerini düzelt
  if [[ -d "$DOCROOT_TGT" ]]; then
    chown -R "$sys_tgt":psacln "$DOCROOT_TGT" || true
    find "$DOCROOT_TGT" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$DOCROOT_TGT" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  
  # Özel Plesk klasörlerini de düzelt (logs hariç - Plesk otomatik yönetir)
  for dir in "cgi-bin" "error_docs" "private" "statistics" "tmp"; do
    if [[ -d "$domain_root/$dir" ]]; then
      chown -R "$sys_tgt":psacln "$domain_root/$dir" || true
      chmod -R 755 "$domain_root/$dir" || true
    fi
  done
  
  # Git klasörünü özel olarak kontrol et
  if [[ -d "$domain_root/git" ]]; then
    info "Git klasörü sahipliği son kontrol: $domain_root/git"
    chown -R "$sys_tgt":psacln "$domain_root/git" || true
    chmod -R 755 "$domain_root/git" || true
  fi
  
  info "İzin düzeltmesi tamamlandı"
}

# Plesk disk usage kaydını oluştur/düzelt
ensure_disk_usage_record () {
  local domain="$1"
  info "Disk usage kaydı kontrol ediliyor: $domain"
  
  local domain_id
  domain_id="$(plesk db -Ne "SELECT id FROM domains WHERE name='$domain';" 2>/dev/null || true)"
  
  if [[ -z "$domain_id" ]]; then
    warn "Domain ID bulunamadı: $domain"
    return
  fi
  
  (( DRYRUN )) && {
    info "DRY-RUN: Disk usage işlemleri atlanıyor"
    return
  }
  
  # disk_usage kaydı var mı kontrol et
  local existing_record
  existing_record="$(plesk db -Ne "SELECT dom_id FROM disk_usage WHERE dom_id=$domain_id;" 2>/dev/null || true)"
  
  if [[ -z "$existing_record" ]]; then
    info "Disk usage kaydı oluşturuluyor: $domain (ID: $domain_id)"
    
    # Gerçek dosya boyutlarını hesapla
    local httpdocs_size logs_size
    local domain_root="/var/www/vhosts/$domain"
    
    if [[ -d "$domain_root/httpdocs" ]]; then
      httpdocs_size=$(du -s "$domain_root/httpdocs" | awk '{print $1}')
      httpdocs_size=$((httpdocs_size * 1024))  # KB to Bytes
    else
      httpdocs_size=0
    fi
    
    if [[ -d "$domain_root/logs" ]]; then
      logs_size=$(du -s "$domain_root/logs" | awk '{print $1}')  
      logs_size=$((logs_size * 1024))  # KB to Bytes
    else
      logs_size=0
    fi
    
    info "  httpdocs: $(($httpdocs_size / 1024))KB"
    info "  logs: $(($logs_size / 1024))KB"
    
    # disk_usage tablosuna kayıt ekle
    plesk db -Ne "INSERT INTO disk_usage (dom_id, httpdocs, httpsdocs, subdomains, web_users, anonftp, logs, mysql_dbases, mssql_dbases, mailboxes, maillists, domaindumps, www_root, dbases, configs, chroot, pgsql_dbases) VALUES ($domain_id, $httpdocs_size, 0, 0, 0, 0, $logs_size, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);" || warn "Disk usage kaydı eklenemedi"
    
    info "✓ Disk usage kaydı başarıyla oluşturuldu"
  else
    info "✓ Disk usage kaydı zaten mevcut: $domain"
  fi
  
  # Plesk native statistics calculation (en güvenilir yöntem)
  info "Plesk statistics hesaplanıyor..."
  
  if plesk sbin statistics --calculate-one --domain-name="$domain" >/dev/null 2>&1; then
    info "  ✓ Statistics başarıyla hesaplandı"
  else
    warn "  Statistics hesaplama uyarısı (arka planda devam ediyor olabilir)"
    # Fallback: DB trigger
    plesk db -Ne "UPDATE disk_usage SET httpdocs=httpdocs WHERE dom_id=$domain_id;" 2>/dev/null || true
  fi
  
  info "✓ Statistics recalculate tamamlandı"
}

# SSL (Let's Encrypt via extension)
issue_ssl () {
  [[ $WITH_SSL -eq 1 ]] || return
  info "SSL (Let's Encrypt) çıkarılıyor: $TARGET"
  (( DRYRUN )) && return
  local email="admin@$(hostname -d 2>/dev/null || echo example.com)"
  plesk bin extension --exec letsencrypt cli.php -d "$TARGET" -m "$email" --agree-tos || warn "LE sertifika çıkarılamadı."
}

# nginx/apache extra notes (best-effort)
copy_webserver_notes () {
  warn "Not: Nginx/Apache 'ek direktifler' servis planıyla taşınır; özel direktifler varsa GUI/CLI ile kontrol edin."
}

# ---- run ----
if [[ $FIX_GIT_ONLY -eq 1 ]]; then
  bold "[$TARGET] Git entegrasyonu düzeltiliyor"
  info "Sadece Git entegrasyonu düzeltme modu"
  
  # Kaynak ve hedef domain ID'lerini al
  src_domain_id="$(plesk db -Ne "SELECT id FROM domains WHERE name = '$SOURCE' LIMIT 1;" 2>/dev/null || true)"
  tgt_domain_id="$(plesk db -Ne "SELECT id FROM domains WHERE name = '$TARGET' LIMIT 1;" 2>/dev/null || true)"
  
  if [[ -z "$src_domain_id" || -z "$tgt_domain_id" ]]; then
    die "Kaynak veya hedef domain ID'si bulunamadı"
  fi
  
  info "Domain ID'ler: Kaynak=$src_domain_id, Hedef=$tgt_domain_id"
  
  # Git extension'ının SQLite veritabanı yolu
  git_db_path="/usr/local/psa/var/modules/git/git_db.db"
  
  if [[ ! -f "$git_db_path" ]]; then
    die "Git SQLite veritabanı bulunamadı: $git_db_path"
  fi
  
  # Git sanal klasörleri düzelt
  create_git_symlinks
  
  # Disk usage kaydını kontrol et
  ensure_disk_usage_record "$TARGET"
  
  # Kaynak domain'deki repository'leri al
  info "Kaynak domain'deki Git repository'ler alınıyor..."
  
  # Ortak Git SQLite senkronizasyon fonksiyonunu çağır
  sync_git_database_settings
else
  bold "[$SOURCE] → [$TARGET] tam klon başlıyor"
  info "Owner: $OWNER | Plan: $SERVICE_PLAN | IP: $IP_SRC"
  (( WITH_SSL )) && info "SSL: ON"
  (( COPY_GIT )) && info "Copy Git: ON"
  (( DRYRUN )) && warn "DRY-RUN aktif (değişiklik yapılmayacak)"

  create_target_domain
  HOME_TGT="$(get_home_dir "$TARGET")"
  [[ -z "$HOME_TGT" ]] && HOME_TGT="/var/www/vhosts/$TARGET"
  DOCROOT_TGT="$(get_docroot "$TARGET" "$HOME_TGT")"
  copy_php_handler
  copy_ssh_settings
  sync_files
  copy_composer  # Composer klasörü ve cache
  replace_domain_in_files  # 🔥 KRITIK: Dosyalarda domain replacement
  fix_perms
  ensure_disk_usage_record "$TARGET"  # Plesk disk usage kaydı oluştur
  copy_git  # Git dosyaları + Git Extension SQLite veritabanı
  clone_dbs  # MySQL/MariaDB veritabanları
  copy_cron
  issue_ssl
  copy_webserver_notes
fi

bold "Tamam! Yeni site: https://${TARGET}"
echo
echo "Uyarılar:"
echo " - Uygulama config’inde (örn. .env, wp-config.php) yeni DB adı/kullanıcı/parolayı güncelleyin."
echo " - Eğer webhook/token’lar kullanıyorsanız Git origin/webhook ayarlarını hedefte yeniden doğrulayın."
[[ -f "./logs/${TARGET}_DB_INFO.txt" ]] && echo " - Yeni DB erişim bilgileri: ./logs/${TARGET}_DB_INFO.txt (600)"
