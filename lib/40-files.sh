#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 40-files.sh — Dosya senkronizasyonu, composer, config yeniden yazımı, izinler
# ---------------------------------------------------------------------------

FULL_VHOST="${FULL_VHOST:-0}"          # 1: tüm vhost dizini, 0: sadece document root
CONFIG_REWRITE="${CONFIG_REWRITE:-1}"  # config dosyalarında eski->yeni değer değişimi
RSYNC_DELETE="${RSYNC_DELETE:-1}"

# Tam vhost kopyasında hariç tutulacaklar (Plesk'in kendi yönettiği dizinler)
declare -a VHOST_EXCLUDES=(
  "/logs/" "/statistics/" "/.sessions/" "/tmp/" "/git/"
  ".git/index.lock" "*.sock"
)

sync_files() {
  local -a extra=()
  (( RSYNC_DELETE )) && extra+=(--delete)
  (( VERBOSE )) && extra+=(-v)

  if (( FULL_VHOST )); then
    info "Tüm vhost dizini kopyalanıyor: $VHOST_SRC/ -> $(remote_label):$VHOST_TGT/"
    local e
    for e in "${VHOST_EXCLUDES[@]}"; do extra+=(--exclude="$e"); done
    rt_rsync_dir "$VHOST_SRC/" "$VHOST_TGT/" "${extra[@]}" \
      || { err "Dosya kopyalama başarısız"; return 1; }
  else
    info "Document root kopyalanıyor: $DOCROOT_SRC/ -> $(remote_label):$DOCROOT_TGT/"
    [[ -d "$DOCROOT_SRC" ]] || { err "Kaynak document root bulunamadı: $DOCROOT_SRC"; return 1; }
    agent ensure-dir "$DOCROOT_TGT" || true
    rt_rsync_dir "$DOCROOT_SRC/" "$DOCROOT_TGT/" "${extra[@]}" \
      || { err "Dosya kopyalama başarısız"; return 1; }
  fi
  ok "Dosyalar kopyalandı"
}

sync_composer() {
  local src="$VHOST_SRC/.composer"
  if [[ ! -d "$src" ]]; then
    skipmsg "Kaynakta .composer dizini yok"
    return 0
  fi
  info "Composer dizini kopyalanıyor (cache hariç)"
  agent ensure-dir "$VHOST_TGT/.composer" || true
  rt_rsync_dir "$src/" "$VHOST_TGT/.composer/" --exclude="cache/" \
    || { warn "Composer kopyalanamadı"; return 1; }
  ok "Composer dizini kopyalandı"
}

# ---- config yeniden yazımı ----
# Değişen her şeyi (domain adı, DB adı, DB kullanıcısı, DB parolası) hedef
# sunucudaki config dosyalarında güncellemek için eşleme dosyası üretir.
build_replacements_file() {
  local out="$1"
  : >"$out"
  chmod 600 "$out"

  if [[ "$SOURCE" != "$TARGET" ]]; then
    printf '%s\t%s\n' "$SOURCE" "$TARGET" >>"$out"
  fi

  if [[ -n "${DB_CHANGES_FILE:-}" && -s "$DB_CHANGES_FILE" ]]; then
    local kind old new
    while IFS=$'\t' read -r kind old new; do
      [[ -z "$old" || -z "$new" || "$old" == "$new" ]] && continue
      printf '%s\t%s\n' "$old" "$new" >>"$out"
    done <"$DB_CHANGES_FILE"
  fi

  [[ -s "$out" ]]
}

rewrite_configs() {
  if (( ! CONFIG_REWRITE )); then
    skipmsg "Config yeniden yazımı kapalı (--no-config-rewrite)"
    return 0
  fi
  init_tmp
  local repl="$CLONE_TMP/replacements.tsv"
  if ! build_replacements_file "$repl"; then
    skipmsg "Değişen bir değer yok — config yeniden yazımına gerek kalmadı (birebir klon)"
    return 0
  fi

  info "Config dosyaları güncelleniyor ($(wc -l <"$repl" | tr -d ' ') eşleme)"
  local remote_repl="$AGENT_DIR/replacements.tsv"
  rt_put "$repl" "$remote_repl"
  rt_exec "chmod 600 $(shq "$remote_repl")"
  agent rewrite-configs "$remote_repl" || { warn "Config yeniden yazımı sırasında sorun oluştu"; return 1; }
  ok "Config dosyaları güncellendi"
}

# ---- agent tarafı ----
agent_ensure_dir() {
  local d="$1"
  (( DRYRUN )) && { info "DRY: mkdir -p $d"; return 0; }
  mkdir -p "$d"
}

# Config dosyalarında eski->yeni değişimi. Yedekler .plesk-clone-backup/ altında tutulur.
agent_rewrite_configs() {
  local repl="$1"
  [[ -f "$repl" ]] || { err "eşleme dosyası yok: $repl"; return 1; }

  local root="$DOCROOT_TGT"
  [[ -d "$root" ]] || { warn "document root yok: $root"; return 0; }

  local backup_dir="$VHOST_TGT/.plesk-clone-backup/$(date +%Y%m%d_%H%M%S)"

  # Aday dosyalar: uzantı beyaz listesi YOK.
  # Eski sürümde yalnızca belirli uzantılar taranıyordu; deploy.sh gibi kabuk
  # betikleri ve uzantısız dosyalar atlanıyor, klon bozuk kalıyordu.
  # Artık metin olan her dosya taranır; ikili dosyalar grep -I ile elenir.
  local list; list="$(mktemp)"
  find "$root" \
       \( -type d \( -name node_modules -o -name vendor -o -name .git -o -name .svn \
                     -o -name .hg -o -name .plesk-clone-backup \) -prune \) -o \
       -type f -size -"${CONFIG_MAX_SIZE_MB:-10}"M -print 2>/dev/null >>"$list" || true

  # Boyut sınırını aşan metin dosyalarını say (sessizce atlamayalım)
  local skipped
  skipped="$(find "$root" \
       \( -type d \( -name node_modules -o -name vendor -o -name .git -o -name .svn \
                     -o -name .hg -o -name .plesk-clone-backup \) -prune \) -o \
       -type f -size +"${CONFIG_MAX_SIZE_MB:-10}"M -print 2>/dev/null | grep -c . || true)"
  (( skipped > 0 )) && warn "$skipped dosya boyut sınırını (${CONFIG_MAX_SIZE_MB:-10}MB) aştığı için taranmadı"

  sort -u "$list" -o "$list"

  # Tüm değişimler tek bir sed betiğinde toplanır (dosya başına tek geçiş)
  local sedscript; sedscript="$(mktemp)"
  local _o _n so sn
  while IFS=$'\t' read -r _o _n; do
    [[ -z "$_o" || -z "$_n" || "$_o" == "$_n" ]] && continue
    so="$(printf '%s' "$_o" | sed -e 's/[]\/$*.^[]/\\&/g')"
    sn="$(printf '%s' "$_n" | sed -e 's/[\/&]/\\&/g')"
    printf 's/%s/%s/g\n' "$so" "$sn" >>"$sedscript"
  done <"$repl"

  local total=0 changed=0 file old new
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    total=$((total+1))
    # Binary dosyaları atla
    grep -Iq . "$file" 2>/dev/null || continue

    local hit=0
    while IFS=$'\t' read -r old new; do
      [[ -z "$old" ]] && continue
      if grep -qF -- "$old" "$file" 2>/dev/null; then hit=1; break; fi
    done <"$repl"
    (( hit )) || continue

    if (( DRYRUN )); then
      info "DRY: güncellenecek ${file#$root/}"
      changed=$((changed+1))
      continue
    fi

    # Yedek al (dizin yapısını koruyarak)
    local rel="${file#$root/}"
    mkdir -p "$backup_dir/$(dirname "$rel")"
    cp -p "$file" "$backup_dir/$rel" 2>/dev/null || true

    # `sed -i` taşınabilir değil (GNU/BSD farkı); geçici dosya + cat ile yaz.
    # cat kullanmak dosyanın inode'unu, sahipliğini ve izinlerini korur.
    local tmpf; tmpf="$(mktemp)"
    if sed -f "$sedscript" "$file" >"$tmpf" 2>/dev/null && cat "$tmpf" >"$file"; then
      info "  güncellendi: $rel"
      changed=$((changed+1))
    else
      warn "  güncellenemedi: $rel"
    fi
    rm -f "$tmpf"
  done <"$list"
  rm -f "$list" "$sedscript"

  if (( changed > 0 )); then
    ok "$changed/$total dosya güncellendi"
    (( DRYRUN )) || info "Yedekler: $backup_dir"
  else
    info "Güncellenecek config bulunamadı ($total dosya tarandı)"
  fi
  return 0
}

# İzinleri ve sahipliği düzelt
agent_fix_perms() {
  local sys_tgt; sys_tgt="$(domain_system_user "$TARGET")"
  [[ -z "$sys_tgt" ]] && { warn "Sistem kullanıcısı bulunamadı; izin düzeltme atlandı."; return 0; }

  info "İzinler düzeltiliyor (owner=$sys_tgt, group=psacln)"
  (( DRYRUN )) && return 0

  local root="$VHOST_TGT"
  if [[ -d "$root" ]]; then
    chown "$sys_tgt":psacln "$root" 2>/dev/null || true
    chmod 750 "$root" 2>/dev/null || true
  fi

  if [[ -d "$DOCROOT_TGT" ]]; then
    chown -R "$sys_tgt":psacln "$DOCROOT_TGT" 2>/dev/null || true
    find "$DOCROOT_TGT" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$DOCROOT_TGT" -type f -exec chmod 644 {} + 2>/dev/null || true
    # Çalıştırılabilir kalması gerekenler
    find "$DOCROOT_TGT" -type f \( -name "*.sh" -o -name "*.pl" -o -name "*.cgi" \) \
      -exec chmod 750 {} + 2>/dev/null || true
  fi

  local d
  for d in "cgi-bin" "error_docs" "private" "statistics" "tmp" ".composer" ".ssh"; do
    [[ -d "$root/$d" ]] || continue
    chown -R "$sys_tgt":psacln "$root/$d" 2>/dev/null || true
  done
  [[ -d "$root/.ssh" ]] && chmod 700 "$root/.ssh" 2>/dev/null || true

  if [[ -d "$root/git" ]]; then
    chown -R "$sys_tgt":psacln "$root/git" 2>/dev/null || true
    chmod -R 755 "$root/git" 2>/dev/null || true
  fi

  # Plesk'in kendi izin şemasını uygula (varsa) — en güvenilir son adım
  if [[ -x /usr/local/psa/bin/repair ]] || "$PLESK_BIN" repair --help >/dev/null 2>&1; then
    "$PLESK_BIN" repair fs "$TARGET" -y >/dev/null 2>&1 \
      && info "plesk repair fs uygulandı" \
      || debug "plesk repair fs çalıştırılamadı"
  fi

  ok "İzin düzeltmesi tamamlandı"
}
