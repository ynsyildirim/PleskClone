#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 60-extras.sh — Domain oluşturma, PHP, SSH, cron, DNS, mail, alias,
# subdomain, FTP, SSL/sertifika, disk kullanımı ve istatistikler
# ---------------------------------------------------------------------------

# ===========================================================================
# DOMAIN
# ===========================================================================
create_domain() {
  local exists; exists="$(agent domain-exists "$TARGET" || printf '0')"
  if [[ "$exists" == "1" ]]; then
    info "Hedef domain zaten mevcut: $TARGET (oluşturma atlandı)"
    return 0
  fi
  info "Hedef domain oluşturuluyor: $TARGET"
  info "  owner=$OWNER  plan=$SERVICE_PLAN  ip=$TARGET_IP  sys-user=$SYS_USER"
  agent create-domain "$TARGET" "$OWNER" "$SERVICE_PLAN" "$TARGET_IP" "$SYS_USER" "$SYS_PASS" \
    || die "Hedef domain oluşturulamadı: $TARGET"
  secret_write "${TARGET}_SYS_INFO.txt" "Sistem kullanıcısı: $SYS_USER | Parola: $SYS_PASS"
  ok "Domain oluşturuldu — sistem kullanıcı bilgileri: $LOG_DIR/${TARGET}_SYS_INFO.txt"
}

agent_domain_exists() {
  domain_exists "$1" && printf '1' || printf '0'
}

agent_create_domain() {
  local domain="$1" owner="$2" plan="$3" ip="$4" sysuser="$5" syspass="$6"

  # Servis planı hedefte var mı?
  if [[ -n "$plan" ]] && ! service_plan_exists "$plan"; then
    warn "'$plan' servis planı bu sunucuda yok."
    local fallback
    fallback="$(default_service_plan)"
    if [[ -n "$fallback" ]]; then
      warn "'$fallback' planı ile devam ediliyor — plan limitlerini sonradan kontrol edin."
      plan="$fallback"
    else
      warn "Hiçbir servis planı bulunamadı; plan parametresi olmadan denenecek."
      plan=""
    fi
  fi

  # IP hedefte tanımlı mı?
  local ip_ok
  ip_ok="$(psa1 "SELECT id FROM IP_Addresses WHERE ip_address='$(sql_escape "$ip")' LIMIT 1;")"
  if [[ -z "$ip_ok" ]]; then
    local newip; newip="$(server_primary_ip)"
    warn "'$ip' bu sunucuda tanımlı değil; '$newip' kullanılacak."
    ip="$newip"
  fi

  if (( DRYRUN )); then
    info "DRY: domain --create $domain (owner=$owner plan=$plan ip=$ip login=$sysuser)"
    return 0
  fi

  local -a args=(bin domain --create "$domain" -owner "$owner" -ip "$ip"
                 -login "$sysuser" -passwd "$syspass" -hosting true)
  [[ -n "$plan" ]] && args+=(-service-plan "$plan")

  "$PLESK_BIN" "${args[@]}"
}

# ===========================================================================
# PHP
# ===========================================================================
sync_php() {
  local handler ver
  handler="$(domain_php_handler_id "$SOURCE")"
  ver="$(domain_php_version "$SOURCE")"
  info "Kaynak PHP: handler='${handler:-?}' sürüm='${ver:-?}'"
  agent set-php "$TARGET" "$handler" "$ver" || warn "PHP ayarları uygulanamadı"

  # Özel php.ini direktifleri
  local custom; custom="$(domain_php_custom_settings "$SOURCE")"
  if [[ -n "$custom" ]]; then
    local n; n="$(printf '%s\n' "$custom" | grep -c . || true)"
    warn "Kaynakta $n özel PHP direktifi var — Plesk arayüzünden kontrol edin (otomatik taşınmaz):"
    printf '%s\n' "$custom" | sed 's/^/        /' >&2
  fi
}

agent_set_php() {
  local domain="$1" handler="$2" ver="$3"

  # Plesk sürümü destekliyorsa abonelik ayarlarını topluca eşitle
  if "$PLESK_BIN" bin subscription_settings --help 2>&1 | grep -q 'sync-subscription'; then
    debug "subscription_settings sync-subscription mevcut"
  fi

  if [[ -n "$handler" ]]; then
    # handler id kaynağa özel olabilir; hedefte aynı id var mı kontrol et
    if php_handler_exists "$handler"; then
      if (( DRYRUN )); then info "DRY: domain --update -php-handler-id $handler"; return 0; fi
      "$PLESK_BIN" bin domain --update "$domain" -php-handler-id "$handler" >/dev/null 2>&1 \
        && { ok "PHP handler ayarlandı: $handler"; return 0; }
      warn "PHP handler ayarlanamadı: $handler"
    else
      warn "'$handler' handler'ı bu sunucuda yok; sürüme göre eşleştirilecek."
    fi
  fi

  if [[ -n "$ver" ]]; then
    if (( DRYRUN )); then info "DRY: domain --update -php-version $ver"; return 0; fi
    if "$PLESK_BIN" bin domain --update "$domain" -php-version "$ver" >/dev/null 2>&1; then
      ok "PHP sürümü ayarlandı: $ver"; return 0
    fi
    # Sürüm string'i eşleşmezse ana sürümle (ör. 8.3) eşleştir.
    local major; major="$(printf '%s' "$ver" | cut -d. -f1,2)"
    local suffix="${handler##*-}"        # fpm / fastcgi / cgi
    local alt
    alt="$(php_handler_find "$major" "$suffix")"
    [[ -z "$alt" ]] && alt="$(php_handler_find "$major" "")"
    if [[ -n "$alt" ]]; then
      "$PLESK_BIN" bin domain --update "$domain" -php-handler-id "$alt" >/dev/null 2>&1 \
        && { ok "PHP handler ($major) eşleştirildi: $alt"; return 0; }
    fi
    warn "PHP sürümü ayarlanamadı: $ver"
  fi
  warn "PHP ayarları uygulanamadı; plan varsayılanları geçerli."
  return 0
}

# ===========================================================================
# SSH / shell
# ===========================================================================
sync_shell() {
  local sh_src; sh_src="$(domain_system_shell "$SOURCE")"
  if [[ -z "$sh_src" ]]; then
    warn "Kaynak SSH shell ayarı okunamadı"
    return 0
  fi
  info "Kaynak SSH shell: $sh_src"
  agent set-shell "$TARGET" "$sh_src" || warn "SSH shell ayarı uygulanamadı"
}

agent_set_shell() {
  local domain="$1" shell="$2"
  local cur; cur="$(domain_system_shell "$domain")"
  if [[ "$cur" == "$shell" ]]; then
    info "SSH shell zaten uyumlu: $shell"
    return 0
  fi
  info "SSH shell güncelleniyor: ${cur:-?} -> $shell"
  (( DRYRUN )) && return 0
  if [[ "$shell" == "/bin/false" || "$shell" == "/sbin/nologin" || -z "$shell" ]]; then
    "$PLESK_BIN" bin domain --update "$domain" -shell false >/dev/null 2>&1 \
      || { warn "SSH kapatılamadı"; return 1; }
  else
    "$PLESK_BIN" bin domain --update "$domain" -shell "$shell" >/dev/null 2>&1 \
      || { warn "SSH açılamadı ($shell)"; return 1; }
  fi
  ok "SSH shell güncellendi"
}

# ===========================================================================
# CRON
# ===========================================================================
sync_cron() {
  local sys_src="$SYS_USER_SRC"
  if ! crontab -l -u "$sys_src" >/dev/null 2>&1; then
    skipmsg "Kaynak kullanıcının ($sys_src) crontab'ı yok"
    return 0
  fi
  info "Crontab aktarılıyor: $sys_src -> hedef sistem kullanıcısı"
  if (( DRYRUN )); then
    skipmsg "DRY-RUN: crontab aktarımı atlandı"
    return 0
  fi
  # Kaynak domain adı geçen satırlar hedefe göre düzeltilir
  crontab -l -u "$sys_src" 2>/dev/null \
    | { if [[ "$SOURCE" != "$TARGET" ]]; then sed "s|$SOURCE|$TARGET|g"; else cat; fi; } \
    | agent_stdin cron-install \
    || { warn "Crontab aktarılamadı"; return 1; }
  ok "Crontab aktarıldı"
  warn "Not: Görevler crontab'a yazıldı; Plesk arayüzündeki 'Zamanlanmış Görevler' listesinde"
  warn "      görünmeleri için arayüzden bir kez kaydedilmeleri gerekebilir."
}

agent_cron_install() {
  local sys_tgt; sys_tgt="$(domain_system_user "$TARGET")"
  [[ -z "$sys_tgt" ]] && { err "Sistem kullanıcısı bulunamadı, cron atlandı"; cat >/dev/null; return 1; }
  if (( DRYRUN )); then info "DRY: crontab -u $sys_tgt"; cat >/dev/null; return 0; fi
  crontab -u "$sys_tgt" - || return 1
  ok "Crontab yüklendi: $sys_tgt"
}

# ===========================================================================
# DISK KULLANIMI / İSTATİSTİK
# ===========================================================================
agent_disk_usage() {
  local domain="$TARGET" dom_id
  dom_id="$(domain_id "$domain")"
  [[ -z "$dom_id" ]] && { warn "Domain ID bulunamadı: $domain"; return 0; }

  if (( DRYRUN )); then info "DRY: disk_usage kaydı"; return 0; fi

  local existing
  existing="$(psa1 "SELECT dom_id FROM disk_usage WHERE dom_id=$dom_id;")"

  if [[ -z "$existing" ]]; then
    local root="$VHOST_TGT" hsize=0 lsize=0
    [[ -d "$DOCROOT_TGT" ]] && hsize=$(( $(du -s "$DOCROOT_TGT" 2>/dev/null | awk '{print $1}' || echo 0) * 1024 ))
    [[ -d "$root/logs" ]]  && lsize=$(( $(du -s "$root/logs" 2>/dev/null | awk '{print $1}' || echo 0) * 1024 ))
    info "disk_usage kaydı oluşturuluyor (httpdocs=$(human_size "$hsize"), logs=$(human_size "$lsize"))"
    psa "INSERT INTO disk_usage
         (dom_id, httpdocs, httpsdocs, subdomains, web_users, anonftp, logs, mysql_dbases,
          mssql_dbases, mailboxes, maillists, domaindumps, www_root, dbases, configs, chroot, pgsql_dbases)
         VALUES ($dom_id, $hsize, 0, 0, 0, 0, $lsize, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);" \
      || warn "disk_usage kaydı eklenemedi"
  else
    info "disk_usage kaydı zaten var"
  fi

  if "$PLESK_BIN" sbin statistics --calculate-one --domain-name="$domain" >/dev/null 2>&1; then
    ok "İstatistikler hesaplandı"
  else
    warn "İstatistik hesaplama uyarı verdi (arka planda sürüyor olabilir)"
    psa "UPDATE disk_usage SET httpdocs=httpdocs WHERE dom_id=$dom_id;" >/dev/null 2>&1 || true
  fi
}

# ===========================================================================
# SSL — Let's Encrypt ve mevcut sertifika kopyalama
# ===========================================================================
issue_ssl() {
  local email="${SSL_EMAIL:-}"
  [[ -z "$email" ]] && email="admin@$(hostname -d 2>/dev/null || printf 'example.com')"
  info "Let's Encrypt sertifikası isteniyor: $TARGET ($email)"
  agent ssl-letsencrypt "$TARGET" "$email" || warn "Let's Encrypt sertifikası alınamadı (DNS hazır mı?)"
}

agent_ssl_letsencrypt() {
  local domain="$1" email="$2"
  (( DRYRUN )) && { info "DRY: letsencrypt $domain"; return 0; }
  "$PLESK_BIN" bin extension --exec letsencrypt cli.php -d "$domain" -m "$email" --agree-tos \
    || return 1
  ok "Let's Encrypt sertifikası kuruldu"
}

# Kaynaktaki mevcut sertifikayı (özel anahtar dahil) hedefe taşı
copy_certificate() {
  local certname; certname="$(domain_certificate_name "$SOURCE")"
  if [[ -z "$certname" ]]; then
    skipmsg "Kaynakta domain'e bağlı sertifika yok"
    return 0
  fi
  info "Sertifika taşınıyor: $certname"

  init_tmp
  local d="$CLONE_TMP/cert"; mkdir -p "$d"; chmod 700 "$d"
  local part
  for part in cert pvt ca; do
    printf '%b' "$(certificate_part "$certname" "$part")" >"$d/$part.pem"
    chmod 600 "$d/$part.pem"
  done
  if [[ ! -s "$d/cert.pem" || ! -s "$d/pvt.pem" ]]; then
    warn "Sertifika içeriği okunamadı; SSL taşıma atlanıyor"
    return 1
  fi

  local rdir="$AGENT_DIR/cert"
  rt_exec "mkdir -p $(shq "$rdir") && chmod 700 $(shq "$rdir")"
  rt_put "$d/cert.pem" "$rdir/cert.pem"
  rt_put "$d/pvt.pem"  "$rdir/pvt.pem"
  [[ -s "$d/ca.pem" ]] && rt_put "$d/ca.pem" "$rdir/ca.pem"

  agent cert-install "$TARGET" "$certname" "$rdir" || { warn "Sertifika kurulamadı"; return 1; }
  secure_rm "$d/cert.pem" "$d/pvt.pem" "$d/ca.pem"
  ok "Sertifika taşındı ve domaine atandı"
}

agent_cert_install() {
  local domain="$1" name="$2" dir="$3"
  (( DRYRUN )) && { info "DRY: certificate --create $name"; return 0; }

  local -a args=(bin certificate --create "$name" -domain "$domain"
                 -cert-file "$dir/cert.pem" -key-file "$dir/pvt.pem")
  [[ -s "$dir/ca.pem" ]] && args+=(-cacert-file "$dir/ca.pem")

  if ! "$PLESK_BIN" "${args[@]}" >/dev/null 2>&1; then
    # Aynı isim varsa güncelle
    "$PLESK_BIN" bin certificate --update "$name" -domain "$domain" \
      -cert-file "$dir/cert.pem" -key-file "$dir/pvt.pem" >/dev/null 2>&1 \
      || { warn "Sertifika oluşturulamadı: $name"; rm -rf "$dir"; return 1; }
  fi

  "$PLESK_BIN" bin site --update "$domain" -ssl true -certificate-name "$name" >/dev/null 2>&1 \
    || warn "Sertifika domaine atanamadı"
  rm -rf "$dir"
  ok "Sertifika kuruldu: $name"
}

# ===========================================================================
# DNS
# ===========================================================================
sync_dns() {
  local recs; recs="$(list_dns_records "$SOURCE")"
  if [[ -z "$recs" ]]; then
    skipmsg "Kaynakta taşınacak DNS kaydı yok"
    return 0
  fi
  local n; n="$(printf '%s\n' "$recs" | grep -c . || true)"
  info "$n DNS kaydı aktarılıyor (kaynak IP -> hedef IP dönüşümü uygulanır)"

  local applied=0 failed=0 type host val opt dhost dval
  while IFS=$'\t' read -r type host val opt dhost dval; do
    [[ -z "$type" ]] && continue
    # FQDN -> göreli isim
    local rel="${host%.}"
    if [[ "$rel" == "$SOURCE" ]]; then rel=""
    else rel="${rel%.$SOURCE}"; fi
    [[ "$SOURCE" != "$TARGET" ]] && val="${val//$SOURCE/$TARGET}"
    # Kaynak sunucu IP'sini hedefinkiyle değiştir
    [[ "$type" == "A" || "$type" == "AAAA" ]] && [[ "$val" == "$IP_SRC" ]] && val="$TARGET_IP"

    if agent dns-add "$TARGET" "$type" "$rel" "$val" "${opt:-}" >/dev/null 2>&1; then
      applied=$((applied+1))
    else
      failed=$((failed+1))
      debug "DNS kaydı eklenemedi (muhtemelen zaten var): $type ${rel:-@} $val"
    fi
  done <<<"$recs"

  ok "DNS: $applied kayıt eklendi, $failed atlandı/zaten mevcut"
}

agent_dns_add() {
  local domain="$1" type="$2" host="$3" val="$4" opt="${5:-}"
  if (( DRYRUN )); then info "DRY: dns --add $domain $type ${host:-@} $val"; return 0; fi

  case "$type" in
    A)     "$PLESK_BIN" bin dns --add "$domain" -a "$host" -ip "$val" ;;
    AAAA)  "$PLESK_BIN" bin dns --add "$domain" -aaaa "$host" -ip "$val" ;;
    CNAME) "$PLESK_BIN" bin dns --add "$domain" -cname "$host" -canonical "$val" ;;
    MX)    "$PLESK_BIN" bin dns --add "$domain" -mx "$host" -mailexchanger "$val" -priority "${opt:-10}" ;;
    TXT)   "$PLESK_BIN" bin dns --add "$domain" -txt "$val" -domain-name "$host" ;;
    SRV)   "$PLESK_BIN" bin dns --add "$domain" -srv "$host" -canonical "$val" -priority "${opt:-0}" ;;
    PTR)   "$PLESK_BIN" bin dns --add "$domain" -ptr "$val" -canonical "$host" ;;
    *)     return 1 ;;
  esac
}

# ===========================================================================
# ALT ALAN ADLARI / ALIAS
# ===========================================================================
sync_subdomains() {
  local subs; subs="$(list_subdomains "$SOURCE")"
  [[ -z "$subs" ]] && { skipmsg "Kaynakta alt alan adı yok"; return 0; }

  local s created=0
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    local newname="$s"
    [[ "$SOURCE" != "$TARGET" ]] && newname="${s%.$SOURCE}.$TARGET"
    local prefix="${s%.$SOURCE}"
    local docroot; docroot="$(domain_docroot "$s")"
    local rel="${docroot#$VHOST_SRC/}"
    info "Alt alan adı: $s -> $newname (docroot: $rel)"
    if agent subdomain-create "$TARGET" "$prefix" "$rel"; then
      created=$((created+1))
      # Alt alan adı dosyalarını da taşı
      if [[ -d "$docroot" ]]; then
        agent ensure-dir "$VHOST_TGT/$rel" || true
        rt_rsync_dir "$docroot/" "$VHOST_TGT/$rel/" --delete || warn "  Alt alan adı dosyaları kopyalanamadı"
      fi
    else
      warn "  Alt alan adı oluşturulamadı: $newname"
    fi
  done <<<"$subs"
  ok "$created alt alan adı taşındı"
}

agent_subdomain_create() {
  local parent="$1" prefix="$2" rel="$3"
  (( DRYRUN )) && { info "DRY: subdomain --create $prefix.$parent"; return 0; }
  "$PLESK_BIN" bin subdomain --create "$prefix" -domain "$parent" -www-root "$rel" >/dev/null 2>&1 \
    || "$PLESK_BIN" bin subdomain --create "$prefix" -domain "$parent" >/dev/null 2>&1
}

sync_aliases() {
  local aliases; aliases="$(list_domain_aliases "$SOURCE")"
  [[ -z "$aliases" ]] && { skipmsg "Kaynakta domain alias'ı yok"; return 0; }
  local a created=0
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    info "Domain alias: $a"
    agent alias-create "$TARGET" "$a" && created=$((created+1)) || warn "  Alias oluşturulamadı: $a"
  done <<<"$aliases"
  ok "$created alias taşındı"
}

agent_alias_create() {
  local domain="$1" alias="$2"
  (( DRYRUN )) && { info "DRY: site_alias --create $alias"; return 0; }
  "$PLESK_BIN" bin site_alias --create "$alias" -domain "$domain" >/dev/null 2>&1
}

# ===========================================================================
# MAIL
# ===========================================================================
MAILNAMES_DIR="${MAILNAMES_DIR:-/var/qmail/mailnames}"

sync_mail() {
  local boxes; boxes="$(list_mailboxes "$SOURCE")"
  [[ -z "$boxes" ]] && { skipmsg "Kaynakta mail hesabı yok"; return 0; }

  local n; n="$(printf '%s\n' "$boxes" | grep -c . || true)"
  info "$n mail hesabı taşınıyor"

  local created=0 name type pass
  while IFS=$'\t' read -r name type pass; do
    [[ -z "$name" ]] && continue
    local newpass="$pass" kept=1
    if [[ "$type" != "plain" || -z "$pass" ]]; then
      newpass="$(strong_pass)"; kept=0
    fi

    if agent mail-create "$TARGET" "$name" "$newpass"; then
      created=$((created+1))
      if (( kept )); then
        info "  $name@$TARGET — parola korundu"
      else
        warn "  $name@$TARGET — parola geri okunamadı, yenisi üretildi"
        secret_write "${TARGET}_MAIL_INFO.txt" "MAIL: $name@$TARGET | PAROLA: $newpass"
      fi
      # Maildir aktarımı
      local mdir="$MAILNAMES_DIR/$SOURCE/$name"
      if [[ -d "$mdir" ]]; then
        agent ensure-dir "$MAILNAMES_DIR/$TARGET/$name" || true
        rt_rsync_dir "$mdir/" "$MAILNAMES_DIR/$TARGET/$name/" \
          || warn "  Maildir kopyalanamadı: $name"
      fi
    else
      warn "  Mail hesabı oluşturulamadı: $name@$TARGET"
    fi
  done <<<"$boxes"

  agent mail-fix-perms "$TARGET" || true
  ok "$created mail hesabı taşındı"
  [[ -f "$LOG_DIR/${TARGET}_MAIL_INFO.txt" ]] && info "Yeni mail parolaları: $LOG_DIR/${TARGET}_MAIL_INFO.txt"
  return 0
}

agent_mail_create() {
  local domain="$1" name="$2" pass="$3"
  (( DRYRUN )) && { info "DRY: mail --create $name@$domain"; return 0; }
  "$PLESK_BIN" bin mail --create "$name@$domain" -mailbox true -passwd "$pass" >/dev/null 2>&1 \
    || "$PLESK_BIN" bin mail --update "$name@$domain" -mailbox true -passwd "$pass" >/dev/null 2>&1
}

agent_mail_fix_perms() {
  local domain="$1" d="$MAILNAMES_DIR/$domain"
  [[ -d "$d" ]] || return 0
  (( DRYRUN )) && return 0
  chown -R popuser:popuser "$d" 2>/dev/null || true
  "$PLESK_BIN" repair mail "$domain" -y >/dev/null 2>&1 || true
  ok "Mail izinleri düzeltildi"
}

# ===========================================================================
# FTP alt hesapları
# ===========================================================================
sync_ftp_users() {
  local rows
  rows="$(psa "SELECT su.login, su.home, a.type, a.password
               FROM sys_users su
               LEFT JOIN accounts a ON a.id = su.account_id
               WHERE su.home LIKE '$(sql_escape "$VHOST_SRC")%'
                 AND su.login <> '$(sql_escape "$SYS_USER_SRC")';")"
  [[ -z "$rows" ]] && { skipmsg "Kaynakta FTP alt hesabı yok"; return 0; }

  local created=0 login home type pass
  while IFS=$'\t' read -r login home type pass; do
    [[ -z "$login" ]] && continue
    local rel="${home#$VHOST_SRC}"; rel="${rel#/}"
    local newpass="$pass"
    [[ "$type" == "plain" && -n "$pass" ]] || { newpass="$(strong_pass)"; }
    info "FTP alt hesabı: $login (home: /${rel})"
    if agent ftp-create "$TARGET" "$login" "$newpass" "/$rel"; then
      created=$((created+1))
      [[ "$type" == "plain" && -n "$pass" ]] \
        || secret_write "${TARGET}_FTP_INFO.txt" "FTP: $login | PAROLA: $newpass"
    else
      warn "  FTP alt hesabı oluşturulamadı: $login"
    fi
  done <<<"$rows"
  ok "$created FTP alt hesabı taşındı"
}

agent_ftp_create() {
  local domain="$1" login="$2" pass="$3" home="$4"
  (( DRYRUN )) && { info "DRY: ftpsubaccount --create $login"; return 0; }
  "$PLESK_BIN" bin ftpsubaccount --create "$login" -domain "$domain" -passwd "$pass" -home "$home" >/dev/null 2>&1
}
