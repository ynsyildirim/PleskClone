#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 90-run.sh — Bileşen yönetimi, ana akış, agent dağıtımı ve rapor
# ---------------------------------------------------------------------------

ALL_COMPONENTS="domain php shell files composer subdomains aliases db configrewrite git worktree cron dns mail ftp certs ssl perms diskusage"

# Tek çıkış kancası: ssh soketi, hedefteki agent dizini ve yerel geçici dosyalar
cleanup_all() {
  local rc=$?
  transport_close 2>/dev/null || true
  agent_cleanup   2>/dev/null || true
  _tmp_cleanup    2>/dev/null || true
  return $rc
}

install_cleanup_hook() {
  CLEANUP_HOOK_INSTALLED=1
  trap cleanup_all EXIT INT TERM
}

# Varsayılan açık bileşenler (orijinal script'in davranışı)
COMPONENTS_ON="${COMPONENTS_ON:-domain,php,shell,files,composer,db,configrewrite,cron,perms,diskusage}"
COMPONENTS_SKIP="${COMPONENTS_SKIP:-}"
ONLY_MODE="${ONLY_MODE:-0}"
ENGINE="${ENGINE:-granular}"

comp_on()  { csv_contains "$COMPONENTS_ON" "$1"; }
comp_off() { csv_contains "$COMPONENTS_SKIP" "$1"; }

comp_enabled() {
  comp_off "$1" && return 1
  comp_on "$1"
}

comp_add() { COMPONENTS_ON="${COMPONENTS_ON},$1"; }

# --full / --move için: 'ssl' ve 'worktree' hariç her şey.
#
# ssl      : Let's Encrypt, DNS henüz hedefe yönlenmediği için başarısız olur.
#            Taşımada doğrusu mevcut sertifikayı kopyalamaktır ('certs').
# worktree : hedef document root'ta 'git reset --hard' (+ istenirse 'git clean')
#            çalıştırır. Bu, git'te olmayan dosyaları (.env, yüklenen medya)
#            etkileyebilir. Veri kaybı riski taşıdığı için açıkça istenmelidir:
#            --git-worktree
all_components_csv() {
  local c out=""
  for c in $ALL_COMPONENTS; do
    [[ "$c" == "ssl" || "$c" == "worktree" ]] && continue
    out+="${out:+,}$c"
  done
  printf '%s' "$out"
}

active_components() {
  local c
  for c in $ALL_COMPONENTS; do
    comp_enabled "$c" && printf '%s\n' "$c"
  done
}

# component <ad> <başlık> <fonksiyon...>
component() {
  local name="$1" title="$2"; shift 2
  if ! comp_enabled "$name"; then
    skipmsg "$title (bileşen kapalı: $name)"
    return 0
  fi
  step "$title"
  "$@" || warn "'$name' aşaması hatayla tamamlandı — akış sürüyor."
  return 0
}

# ===========================================================================
# KAYNAK BİLGİLERİ
# ===========================================================================
gather_source_info() {
  plesk_available || die "Bu sunucuda plesk CLI bulunamadı."
  require_cmd rsync mysqldump gzip

  domain_exists "$SOURCE" || die "Kaynak domain bulunamadı: $SOURCE"

  SYS_USER_SRC="$(domain_system_user "$SOURCE")"
  [[ -z "$SYS_USER_SRC" ]] && die "Kaynak sistem kullanıcısı okunamadı. Domain'e hosting atanmış mı?"

  VHOST_SRC="$(domain_vhost_dir "$SOURCE")"
  DOCROOT_SRC="$(domain_docroot "$SOURCE")"
  [[ -d "$DOCROOT_SRC" ]] || warn "Kaynak document root bulunamadı: $DOCROOT_SRC"

  IP_SRC="$(domain_ip "$SOURCE")"
  [[ -z "$IP_SRC" ]] && IP_SRC="$(server_primary_ip)"

  if [[ -z "$SERVICE_PLAN" ]]; then
    SERVICE_PLAN="$(domain_service_plan "$SOURCE")"
    if [[ -z "$SERVICE_PLAN" ]]; then
      warn "Kaynak servis planı tespit edilemedi; hedefteki varsayılan plan kullanılacak."
    else
      info "Kaynak servis planı: $SERVICE_PLAN"
    fi
  fi

  [[ -z "$OWNER" ]] && OWNER="$(domain_owner "$SOURCE")"
  [[ -z "$OWNER" ]] && OWNER="admin"

  # Hedef sistem kullanıcısı: birebir taşımada kaynakla aynı tutulur
  if [[ -z "$SYS_USER" ]]; then
    if [[ "$SOURCE" == "$TARGET" ]]; then SYS_USER="$SYS_USER_SRC"
    else SYS_USER="$(slugify "$TARGET")"; fi
  fi
  SYS_USER="${SYS_USER:0:32}"
  [[ -z "$SYS_PASS" ]] && SYS_PASS="$(strong_pass)"

  # Varsayılan hedef yolları (domain oluşturulduktan sonra kesinleştirilir)
  VHOST_TGT="$VHOST_ROOT/$TARGET"
  DOCROOT_TGT="$VHOST_TGT/httpdocs"

  info "Kaynak: $SOURCE (sys=$SYS_USER_SRC, ip=$IP_SRC)"
  info "Document root: $DOCROOT_SRC"
}

resolve_target_paths() {
  local dr
  dr="$(agent get-docroot "$TARGET" 2>/dev/null || true)"
  if [[ -n "$dr" && "$dr" == /* ]]; then
    DOCROOT_TGT="$dr"
    VHOST_TGT="$VHOST_ROOT/$TARGET"
    debug "Hedef document root: $DOCROOT_TGT"
    write_ctx; agent_push_ctx "$CTX_FILE"
  fi
}

# ===========================================================================
# AGENT BAĞLAMI
# ===========================================================================
CTX_FILE=""

write_ctx() {
  init_tmp
  CTX_FILE="${CTX_FILE:-$CLONE_TMP/ctx.env}"
  cat >"$CTX_FILE" <<EOF
SOURCE=$(shq "$SOURCE")
TARGET=$(shq "$TARGET")
OWNER=$(shq "$OWNER")
SERVICE_PLAN=$(shq "$SERVICE_PLAN")
SYS_USER=$(shq "$SYS_USER")
IP_SRC=$(shq "$IP_SRC")
TARGET_IP=$(shq "${TARGET_IP:-}")
VHOST_ROOT=$(shq "$VHOST_ROOT")
PSA_SHADOW_FILE=$(shq "$PSA_SHADOW_FILE")
VHOST_TGT=$(shq "$VHOST_TGT")
DOCROOT_TGT=$(shq "$DOCROOT_TGT")
DRYRUN=$DRYRUN
VERBOSE=$VERBOSE
LOG_PREFIX=$(shq "  [hedef] ")
GIT_DB_PATH=$(shq "$GIT_DB_PATH")
GIT_KEYS_DIR=$(shq "$GIT_KEYS_DIR")
GIT_CLEAN=${GIT_CLEAN:-0}
MAILNAMES_DIR=$(shq "$MAILNAMES_DIR")
EOF
  chmod 600 "$CTX_FILE"
}

# ===========================================================================
# ÖN KONTROLLER
# ===========================================================================
preflight() {
  step "Ön kontroller"
  local out
  out="$(agent preflight "$TARGET" || true)"
  printf '%s\n' "$out" | sed 's/^/  /' >&2

  if [[ "$out" == *"PLESK=0"* ]]; then
    die "Hedef sunucuda Plesk bulunamadı."
  fi
  if [[ "$out" == *"MYSQL=0"* ]] && comp_enabled db; then
    warn "Hedef sunucuda mysql istemcisi yok; veritabanı aşaması başarısız olabilir."
  fi
  if [[ "$out" == *"DOMAIN_EXISTS=1"* ]]; then
    warn "Hedef domain zaten mevcut: $TARGET — dosyalar ve veritabanları üzerine yazılabilir!"
    confirm "Devam edilsin mi?" "h" || die "İşlem iptal edildi."
  fi

  # Güvenlik: "uzak" sunucu aslında bu makineyse, aynı dizini kendi üstüne
  # rsync'lemek (--delete ile) veri kaybına yol açabilir.
  if is_remote; then
    local rid; rid="$(printf '%s\n' "$out" | sed -n 's/^MACHINE_ID=//p' | head -n1)"
    if [[ -n "$rid" && "$rid" == "$(machine_id)" ]]; then
      warn "DİKKAT: Hedef sunucu bu makinenin ta kendisi görünüyor (aynı makine kimliği)."
      warn "Aynı domain adıyla devam etmek dosyaların kendi üzerine kopyalanmasına yol açar."
      [[ "$SOURCE" == "$TARGET" ]] && die "Kaynak ve hedef hem aynı makinede hem aynı isimde — işlem durduruldu."
      confirm "Yine de devam edilsin mi?" "h" || die "İşlem iptal edildi."
    fi
  fi

  TARGET_IP="$(printf '%s\n' "$out" | sed -n 's/^PRIMARY_IP=//p' | head -n1)"
  [[ -z "$TARGET_IP" ]] && TARGET_IP="$IP_SRC"
  is_remote || TARGET_IP="$IP_SRC"
  info "Hedef IP: $TARGET_IP"
  write_ctx; agent_push_ctx "$CTX_FILE"
  ok "Ön kontroller tamam"
}

agent_preflight() {
  local domain="$1"
  plesk_available && printf 'PLESK=1\n' || printf 'PLESK=0\n'
  has_cmd mysql && printf 'MYSQL=1\n' || printf 'MYSQL=0\n'
  has_cmd rsync && printf 'RSYNC=1\n' || printf 'RSYNC=0\n'
  has_cmd sqlite3 && printf 'SQLITE=1\n' || printf 'SQLITE=0\n'
  domain_exists "$domain" && printf 'DOMAIN_EXISTS=1\n' || printf 'DOMAIN_EXISTS=0\n'
  printf 'PRIMARY_IP=%s\n' "$(server_primary_ip)"
  printf 'MACHINE_ID=%s\n' "$(machine_id)"
  printf 'PLESK_VERSION=%s\n' "$(plesk_version)"
  printf 'FREE_SPACE=%s\n' "$(df -Pk "$VHOST_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
}

# ===========================================================================
# ANA AKIŞ
# ===========================================================================
do_clone() {
  gather_source_info
  wizard_transport
  wizard_db_policy
  wizard_extras
  validate_plan

  transport_init
  write_ctx
  agent_deploy "$CTX_FILE"
  preflight

  print_plan
  confirm "Bu planla devam edilsin mi?" "e" || die "İşlem iptal edildi."

  local t0; t0="$(date +%s)"

  if [[ "$ENGINE" == "native" ]]; then
    native_migrate
    finish_report "$t0"
    return 0
  fi

  component domain     "Hedef domain hazırlanıyor"          create_domain
  resolve_target_paths
  component php        "PHP ayarları eşitleniyor"           sync_php
  component shell      "SSH erişim ayarları eşitleniyor"    sync_shell
  component files      "Site dosyaları kopyalanıyor"        sync_files
  component composer   "Composer dizini kopyalanıyor"       sync_composer
  component subdomains "Alt alan adları taşınıyor"          sync_subdomains
  component aliases    "Domain alias'ları taşınıyor"        sync_aliases
  component db         "Veritabanları kopyalanıyor"         clone_databases
  component configrewrite "Uygulama config'leri güncelleniyor" rewrite_configs
  component git        "Git entegrasyonu taşınıyor"         git_sync
  component worktree   "Git çalışma dizini yeniden kuruluyor" agent_worktree
  component cron       "Zamanlanmış görevler taşınıyor"     sync_cron
  component dns        "DNS kayıtları taşınıyor"            sync_dns
  component mail       "Mail hesapları taşınıyor"           sync_mail
  component ftp        "FTP alt hesapları taşınıyor"        sync_ftp_users
  component certs      "SSL sertifikası taşınıyor"          copy_certificate
  component ssl        "Let's Encrypt sertifikası alınıyor" issue_ssl
  component perms      "Dosya izinleri düzeltiliyor"        run_fix_perms
  component diskusage  "Disk kullanımı ve istatistikler"    run_disk_usage

  finish_report "$t0"
}

run_fix_perms()   { agent fix-perms; }
run_disk_usage()  { agent disk-usage; }
agent_worktree()  { agent git-reset-worktree; }

# Sadece Git entegrasyonunu onar (eski --fix-git modu)
do_fix_git() {
  gather_source_info
  wizard_transport
  validate_plan
  transport_init
  write_ctx
  agent_deploy "$CTX_FILE"
  resolve_target_paths

  bold "[$SOURCE] -> [$TARGET] Git entegrasyonu onarılıyor"
  local exists; exists="$(agent domain-exists "$TARGET" || printf '0')"
  [[ "$exists" == "1" ]] || die "Hedef domain bulunamadı: $TARGET"

  git_sync
  agent disk-usage || true
  ok "Git onarımı tamamlandı"
}

# ===========================================================================
# RAPOR
# ===========================================================================
finish_report() {
  local t0="$1" t1; t1="$(date +%s)"
  local dur=$(( t1 - t0 ))
  init_logdir
  local rep="$LOG_DIR/${TARGET}_CLONE_REPORT.txt"

  {
    printf '=== Plesk Clone Raporu ===\n'
    printf 'Tarih          : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Motor          : %s\n' "$ENGINE"
    printf 'Kaynak domain  : %s\n' "$SOURCE"
    printf 'Hedef domain   : %s\n' "$TARGET"
    printf 'Hedef sunucu   : %s\n' "$(remote_label)"
    printf 'Sahip          : %s\n' "$OWNER"
    printf 'Sistem kullanıcı: %s\n' "$SYS_USER"
    printf 'Süre           : %s sn\n' "$dur"
    printf 'Bileşenler     : %s\n' "$(active_components | comma_join)"
    printf 'DB politikası  : ad=%s kullanıcı=%s parola=%s\n' "$DB_MODE" "$DB_USER_MODE" "$DB_PASS_MODE"
    printf '\n--- Manuel kontrol edilmesi önerilenler ---\n'
    printf '* Nginx/Apache ek direktifleri (servis planı dışındaki özel direktifler)\n'
    printf '* Korumalı dizinler (protected directories) ve kullanıcıları\n'
    printf '* Plesk arayüzündeki "Zamanlanmış Görevler" listesi (crontab taşındı)\n'
    printf '* Git webhook ve deploy key tanımları (yeni deploy key üretildi)\n'
    printf '* DNS delegasyonu / nameserver kayıtları\n'
    if [[ -n "${MANUAL_NOTES_FILE:-}" && -s "$MANUAL_NOTES_FILE" ]]; then
      printf '\n--- BU KLON İÇİN ÖZEL, MUTLAKA YAPILMASI GEREKENLER ---\n'
      sed 's/^/! /' "$MANUAL_NOTES_FILE"
    fi
  } >"$rep"
  chmod 600 "$rep" 2>/dev/null || true

  _log ""
  bold "================== TAMAMLANDI (${dur}sn) =================="
  _log "  Site       : https://${TARGET}"
  _log "  Rapor      : $rep"
  [[ -f "$LOG_DIR/${TARGET}_DB_INFO.txt" ]]   && _log "  DB bilgileri   : $LOG_DIR/${TARGET}_DB_INFO.txt (600)"
  [[ -f "$LOG_DIR/${TARGET}_SYS_INFO.txt" ]]  && _log "  Sistem kullanıcı: $LOG_DIR/${TARGET}_SYS_INFO.txt (600)"
  [[ -f "$LOG_DIR/${TARGET}_MAIL_INFO.txt" ]] && _log "  Mail parolaları : $LOG_DIR/${TARGET}_MAIL_INFO.txt (600)"
  [[ -f "$LOG_DIR/${TARGET}_FTP_INFO.txt" ]]  && _log "  FTP parolaları  : $LOG_DIR/${TARGET}_FTP_INFO.txt (600)"
  bold "======================================================="

  if [[ "$DB_MODE" == "keep" && "$DB_USER_MODE" == "keep" && "$DB_PASS_MODE" == "keep" ]]; then
    ok "Veritabanı bilgileri birebir korundu — uygulama config'lerinde değişiklik gerekmez."
  else
    warn "Veritabanı bilgileri değişti. Config'ler otomatik güncellendiyse de (.env, wp-config.php) doğrulayın."
  fi
}

# ===========================================================================
# AGENT DAĞITIMI (hedef sunucuda çalışan taraf)
# ===========================================================================
agent_dispatch() {
  local op="$1"; shift

  # Bağlam dosyasını yükle (agent dizininde, script ile yan yana durur)
  local ctx="$SELF_DIR/ctx.env"
  # shellcheck source=/dev/null
  [[ -f "$ctx" ]] && . "$ctx"

  # Hedef yolları psa'dan kesinleştir (domain oluşturulmuşsa)
  if [[ -n "${TARGET:-}" ]] && plesk_available && domain_exists "$TARGET"; then
    VHOST_TGT="$(domain_vhost_dir "$TARGET")"
    DOCROOT_TGT="$(domain_docroot "$TARGET")"
  fi

  case "$op" in
    preflight)          agent_preflight "$@" ;;
    domain-exists)      agent_domain_exists "$@" ;;
    create-domain)      agent_create_domain "$@" ;;
    get-docroot)        domain_docroot "$1" ;;
    primary-ip)         server_primary_ip ;;
    ensure-dir)         agent_ensure_dir "$@" ;;
    set-php)            agent_set_php "$@" ;;
    set-shell)          agent_set_shell "$@" ;;
    db-exists)          agent_db_exists "$@" ;;
    db-create)          agent_db_create "$@" ;;
    db-drop)            agent_db_drop "$@" ;;
    db-user-create)     agent_db_user_create "$@" ;;
    db-user-set-hash)   agent_db_user_set_hash "$@" ;;
    db-user-grant)      agent_db_user_grant "$@" ;;
    db-import)          agent_db_import "$@" ;;
    rewrite-configs)    agent_rewrite_configs "$@" ;;
    fix-perms)          agent_fix_perms "$@" ;;
    disk-usage)         agent_disk_usage "$@" ;;
    git-import)         agent_git_import "$@" ;;
    git-finalize)       agent_git_finalize "$@" ;;
    git-reset-worktree) agent_git_reset_worktree "$@" ;;
    cron-install)       agent_cron_install "$@" ;;
    ssl-letsencrypt)    agent_ssl_letsencrypt "$@" ;;
    cert-install)       agent_cert_install "$@" ;;
    dns-add)            agent_dns_add "$@" ;;
    subdomain-create)   agent_subdomain_create "$@" ;;
    alias-create)       agent_alias_create "$@" ;;
    mail-create)        agent_mail_create "$@" ;;
    mail-fix-perms)     agent_mail_fix_perms "$@" ;;
    ftp-create)         agent_ftp_create "$@" ;;
    native-restore)     agent_native_restore "$@" ;;
    *) err "Bilinmeyen agent işlemi: $op"; return 64 ;;
  esac
}
