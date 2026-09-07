#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 70-native.sh — Plesk'in kendi yedek/geri yükleme motoru (pleskbackup/pleskrestore)
#
# Domain'i BAŞKA bir sunucuya AYNI isimle taşımanın en eksiksiz yolu budur:
# posta, DNS, sertifikalar, izinler, planlar, zamanlanmış görevler dahil her şey
# Plesk tarafından taşınır. Yeniden adlandırma (klonlama) desteklemez.
#
# Kullanım: --engine native
# ---------------------------------------------------------------------------

NATIVE_KEEP_BACKUP="${NATIVE_KEEP_BACKUP:-0}"

native_migrate() {
  [[ "$SOURCE" == "$TARGET" ]] \
    || die "native motor yeniden adlandırma yapamaz (kaynak ve hedef domain aynı olmalı). Klonlama için --engine granular kullanın."
  is_remote \
    || die "native motor aynı sunucuda anlamlı değil; --to-host ile hedef sunucu belirtin."

  require_cmd rsync
  init_tmp

  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local local_backup="/tmp/plesk-clone-${SOURCE}-${ts}.tar"
  local remote_backup="/tmp/plesk-clone-${SOURCE}-${ts}.tar"

  step "1/4 Plesk yedeği alınıyor: $SOURCE"
  if (( DRYRUN )); then
    skipmsg "DRY-RUN: pleskbackup atlandı"
  else
    local -a bargs=(bin pleskbackup --domains-name "$SOURCE" --output-file="$local_backup")
    "$PLESK_BIN" bin pleskbackup --help 2>&1 | grep -q -- '--skip-logs' && bargs+=(--skip-logs)
    "$PLESK_BIN" "${bargs[@]}" || die "Plesk yedeği alınamadı"
    ok "Yedek hazır: $local_backup ($(du -h "$local_backup" | cut -f1))"
  fi

  step "2/4 Yedek hedef sunucuya aktarılıyor: $(remote_label)"
  if (( DRYRUN )); then
    skipmsg "DRY-RUN: transfer atlandı"
  else
    rsync -a --info=progress2 -e "$(ssh_cmd_string)" \
      "$local_backup" "${REMOTE_USER}@${REMOTE_HOST}:$remote_backup" \
      || die "Yedek aktarılamadı"
    ok "Aktarım tamamlandı"
  fi

  step "3/4 Hedef sunucuda geri yükleniyor"
  agent native-restore "$remote_backup" "$SOURCE" "$OWNER" \
    || die "Geri yükleme başarısız — hedef sunucudaki logları kontrol edin"

  step "4/4 Temizlik"
  if (( NATIVE_KEEP_BACKUP )); then
    info "Yedekler korunuyor: $local_backup ve $(remote_label):$remote_backup"
  else
    (( DRYRUN )) || rm -f "$local_backup"
    rt_exec "rm -f $(shq "$remote_backup")" >/dev/null 2>&1 || true
    info "Geçici yedek dosyaları silindi"
  fi
  ok "Native taşıma tamamlandı"
}

agent_native_restore() {
  local backup="$1" domain="$2" owner="$3"
  [[ -f "$backup" ]] || { err "Yedek dosyası yok: $backup"; return 1; }

  if (( DRYRUN )); then
    info "DRY: pleskrestore --restore $backup -level domains"
    return 0
  fi

  local mapfile="/tmp/plesk-clone-map-$$.xml"
  if "$PLESK_BIN" bin pleskrestore --create-map "$backup" -map-file "$mapfile" >/dev/null 2>&1; then
    info "Eşleme dosyası oluşturuldu: $mapfile"
  else
    warn "Eşleme dosyası oluşturulamadı; varsayılan eşleme ile denenecek"
    mapfile=""
  fi

  local -a rargs=(bin pleskrestore --restore "$backup" -level domains -ignore-sign)
  [[ -n "$mapfile" ]] && rargs+=(-map-file "$mapfile")

  if "$PLESK_BIN" "${rargs[@]}"; then
    ok "Geri yükleme tamamlandı: $domain"
    [[ -n "$mapfile" ]] && rm -f "$mapfile"
    return 0
  fi
  [[ -n "$mapfile" ]] && rm -f "$mapfile"
  return 1
}
