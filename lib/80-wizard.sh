#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 80-wizard.sh — Etkileşimli plan sihirbazı, doğrulama ve özet
# ---------------------------------------------------------------------------

DB_POLICY_SET="${DB_POLICY_SET:-0}"     # komut satırından belirlendiyse sorma
TRANSPORT_SET="${TRANSPORT_SET:-0}"

wizard_transport() {
  (( TRANSPORT_SET )) && return 0
  (( INTERACTIVE )) || { TRANSPORT_SET=1; return 0; }

  if [[ "$SOURCE" == "$TARGET" ]]; then
    info "Kaynak ve hedef domain aynı -> hedef mutlaka başka bir sunucu olmalı."
    TRANSPORT="remote"
  else
    local c
    c="$(choose "Hedef domain nerede oluşturulacak?" \
         "Bu sunucuda (aynı Plesk üzerinde klon)" \
         "Farklı bir sunucuda (SSH ile taşıma)")"
    [[ "$c" == "2" ]] && TRANSPORT="remote" || TRANSPORT="local"
  fi

  if is_remote; then
    [[ -z "$REMOTE_HOST" ]] && REMOTE_HOST="$(ask "Hedef sunucu IP/hostname" "")"
    [[ -z "$REMOTE_HOST" ]] && die "Hedef sunucu adresi gerekli"
    REMOTE_USER="$(ask "SSH kullanıcısı" "$REMOTE_USER")"
    REMOTE_PORT="$(ask "SSH portu" "$REMOTE_PORT")"
    local k; k="$(ask "SSH özel anahtar dosyası (boş = varsayılan)" "$REMOTE_KEY")"
    REMOTE_KEY="$k"
  fi
  TRANSPORT_SET=1
}

wizard_db_policy() {
  (( DB_POLICY_SET )) && return 0
  (( INTERACTIVE )) || return 0
  comp_enabled db || return 0

  local same_server=1
  is_remote && same_server=0

  local -a opts=()
  if (( ! same_server )); then
    opts+=("Hiçbir şey değişmesin — ad, kullanıcı ve parola birebir aynı kalsın (önerilen: taşıma)")
  fi
  opts+=(
    "Sadece veritabanı ADI değişsin (kullanıcı ve parola aynı kalsın)"
    "Ad, kullanıcı ve parola — hepsi yeniden üretilsin (önerilen: aynı sunucuda klon)"
    "Tek tek seçmek istiyorum"
    "Veritabanlarını hiç kopyalama"
  )

  local c; c="$(choose "Veritabanı bilgileri nasıl işlensin?" "${opts[@]}")"
  # Aynı sunucuda ilk seçenek listelenmediği için indeksi kaydır
  (( same_server )) && c=$((c+1))

  case "$c" in
    1) DB_MODE="keep";   DB_USER_MODE="keep"; DB_PASS_MODE="keep" ;;
    2) DB_MODE="suffix"; DB_USER_MODE="keep"; DB_PASS_MODE="keep" ;;
    3) DB_MODE="suffix"; DB_USER_MODE="new";  DB_PASS_MODE="new"  ;;
    4) wizard_db_custom ;;
    5) COMPONENTS_SKIP="${COMPONENTS_SKIP},db" ;;
  esac
  DB_POLICY_SET=1
}

wizard_db_custom() {
  local same_server=1; is_remote && same_server=0

  local -a nameopts=()
  (( ! same_server )) && nameopts+=("Aynı kalsın")
  nameopts+=("Sonek eklensin (ör. shop_yeni_domain_com)" "Önek eklensin" "Elle eşleme gireceğim")
  local c; c="$(choose "Veritabanı ADI:" "${nameopts[@]}")"
  (( same_server )) && c=$((c+1))
  case "$c" in
    1) DB_MODE="keep" ;;
    2) DB_MODE="suffix"; DB_SUFFIX="$(ask "Sonek" "$DB_SUFFIX")" ;;
    3) DB_MODE="prefix"; DB_PREFIX="$(ask "Önek" "${DB_PREFIX:-yeni}")" ;;
    4) DB_MODE="map";    DB_MAP="$(ask "Eşleme (eski1=yeni1,eski2=yeni2)" "")" ;;
  esac

  local -a useropts=()
  (( ! same_server )) && useropts+=("Aynı kalsın")
  useropts+=("Yeni rastgele kullanıcı adı üretilsin" "Elle eşleme gireceğim")
  c="$(choose "Veritabanı KULLANICI ADI:" "${useropts[@]}")"
  (( same_server )) && c=$((c+1))
  case "$c" in
    1) DB_USER_MODE="keep" ;;
    2) DB_USER_MODE="new" ;;
    3) DB_USER_MODE="map"; DB_USER_MAP="$(ask "Eşleme (eski=yeni,...)" "")" ;;
  esac

  c="$(choose "Veritabanı PAROLASI:" \
        "Aynı kalsın (uygulama config'i değişmesin)" \
        "Yeni güçlü parola üretilsin" \
        "Elle gireceğim")"
  case "$c" in
    1) DB_PASS_MODE="keep" ;;
    2) DB_PASS_MODE="new" ;;
    3) DB_PASS_MODE="map"; DB_PASS_MAP="$(ask "Eşleme (kullanici=parola,...)" "")" ;;
  esac
}

wizard_extras() {
  (( ! INTERACTIVE )) && return 0
  (( ASSUME_YES )) && return 0
  [[ -n "${EXTRAS_ASKED:-}" ]] && return 0

  # Sadece taşıma senaryosunda ek bileşenleri sor
  if [[ "$SOURCE" == "$TARGET" ]] && ! csv_contains "$COMPONENTS_ON" "dns"; then
    confirm "DNS kayıtları da taşınsın mı?" "e" && COMPONENTS_ON="${COMPONENTS_ON},dns"
    confirm "Mail hesapları ve posta kutuları taşınsın mı?" "e" && COMPONENTS_ON="${COMPONENTS_ON},mail"
    confirm "Mevcut SSL sertifikası taşınsın mı?" "e" && COMPONENTS_ON="${COMPONENTS_ON},certs"
    confirm "Alt alan adları ve alias'lar taşınsın mı?" "e" && COMPONENTS_ON="${COMPONENTS_ON},subdomains,aliases"
  fi
  EXTRAS_ASKED=1
}

# ---- doğrulama ----
validate_plan() {
  [[ -z "$SOURCE" ]] && die "Kaynak domain (-s) zorunlu."
  [[ -z "$TARGET" ]] && die "Hedef domain (-t) zorunlu."

  if [[ "$SOURCE" == "$TARGET" ]] && ! is_remote; then
    die "Kaynak ve hedef domain aynı ($SOURCE) — aynı sunucuda mümkün değil. --to-host ile hedef sunucu belirtin."
  fi

  if ! is_remote; then
    if [[ "$DB_MODE" == "keep" ]]; then
      warn "Aynı sunucuda veritabanı adı korunamaz (çakışma) — sonek moduna geçiliyor."
      DB_MODE="suffix"
    fi
    if [[ "$DB_USER_MODE" == "keep" ]]; then
      warn "Aynı sunucuda veritabanı kullanıcı adı korunamaz (MySQL kullanıcıları sunucu genelinde tekil) — yeni kullanıcı üretilecek."
      DB_USER_MODE="new"
      [[ "$DB_PASS_MODE" == "keep" ]] && DB_PASS_MODE="new"
    fi
  fi

  [[ "$DB_MODE" == "suffix" && -z "$DB_SUFFIX" ]] && DB_SUFFIX="$(slugify "$TARGET")"
  [[ "$DB_MODE" == "prefix" && -z "$DB_PREFIX" ]] && DB_PREFIX="$(slugify "$TARGET")"
  [[ -z "$DB_USER_SUFFIX" ]] && DB_USER_SUFFIX="$(slugify "$TARGET")"

  [[ "$ENGINE" == "native" && "$SOURCE" != "$TARGET" ]] \
    && die "native motor yeniden adlandırmayı desteklemez; --engine granular kullanın."

  # Hiçbir değer değişmiyorsa config yeniden yazımına gerek yok
  if [[ "$SOURCE" == "$TARGET" && "$DB_MODE" == "keep" \
        && "$DB_USER_MODE" == "keep" && "$DB_PASS_MODE" == "keep" ]]; then
    CONFIG_REWRITE=0
  fi
  return 0
}

# ---- özet ----
print_plan() {
  local db_desc
  if comp_enabled db; then
    db_desc="ad=$DB_MODE"
    [[ "$DB_MODE" == "suffix" ]] && db_desc+="(_$DB_SUFFIX)"
    [[ "$DB_MODE" == "prefix" ]] && db_desc+="(${DB_PREFIX}_)"
    db_desc+=" kullanıcı=$DB_USER_MODE parola=$DB_PASS_MODE"
  else
    db_desc="kopyalanmayacak"
  fi

  _log ""
  bold "================== İŞLEM PLANI =================="
  _log "  Motor           : $ENGINE"
  _log "  Kaynak domain   : $SOURCE"
  _log "  Hedef domain    : $TARGET$( [[ "$SOURCE" == "$TARGET" ]] && printf '  (birebir taşıma)' )"
  _log "  Hedef sunucu    : $(remote_label)"
  _log "  Sahip (owner)   : $OWNER"
  _log "  Servis planı    : ${SERVICE_PLAN:-<hedef varsayılanı>}"
  _log "  Sistem kullanıcı: $SYS_USER"
  _log "  Dosya kapsamı   : $( (( FULL_VHOST )) && printf 'tüm vhost dizini' || printf 'document root' )"
  _log "  Veritabanı      : $db_desc"
  _log "  Config güncelle : $( (( CONFIG_REWRITE )) && printf 'evet' || printf 'hayır (değişen değer yok)' )"
  _log "  Bileşenler      : $(active_components | comma_join)"
  (( DRYRUN )) && _log "  ${C_YLW}MOD           : DRY-RUN (hiçbir değişiklik yapılmaz)${C_RST}"
  bold "================================================="
  _log ""
}
