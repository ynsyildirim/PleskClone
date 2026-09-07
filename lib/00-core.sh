#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-core.sh — Ortak çekirdek: loglama, dry-run, etkileşim, yardımcılar
# Hem orkestratör (kaynak sunucu) hem agent (hedef sunucu) tarafında kullanılır.
# ---------------------------------------------------------------------------

DRYRUN="${DRYRUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
INTERACTIVE="${INTERACTIVE:-1}"
VERBOSE="${VERBOSE:-0}"
LOG_DIR="${LOG_DIR:-./logs}"
LOG_FILE="${LOG_FILE:-}"
LOG_PREFIX="${LOG_PREFIX:-}"

# ---- renkler (sadece tty'de) ----
if [[ -t 2 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_CYN=$'\033[36m'
else
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""
fi

# Tüm loglar stderr'e gider; böylece "değer döndüren" fonksiyonların stdout'u temiz kalır.
_log() {
  local line="$1"
  printf '%s\n' "$line" >&2
  [[ -n "$LOG_FILE" ]] && printf '%s\n' "$(printf '%s' "$line" | sed -E 's/\x1b\[[0-9;]*m//g')" >>"$LOG_FILE" 2>/dev/null || true
}

bold()    { _log "${C_B}${LOG_PREFIX}$*${C_RST}"; }
info()    { _log "${LOG_PREFIX}[BİLGİ] $*"; }
ok()      { _log "${C_GRN}${LOG_PREFIX}[  OK ]${C_RST} $*"; }
warn()    { _log "${C_YLW}${LOG_PREFIX}[UYARI]${C_RST} $*"; }
err()     { _log "${C_RED}${LOG_PREFIX}[HATA ]${C_RST} $*"; }
debug()   { (( VERBOSE )) && _log "${C_DIM}${LOG_PREFIX}[DEBUG] $*${C_RST}" || true; }
skipmsg() { _log "${C_DIM}${LOG_PREFIX}[ATLA ] $*${C_RST}"; }
die()     { err "$*"; exit 1; }

step() {
  _log ""
  _log "${C_CYN}${C_B}${LOG_PREFIX}> $*${C_RST}"
}

# ---- dry-run destekli çalıştırma ----
is_dry() { (( DRYRUN )); }

# run <komut...>  — dry-run'da sadece yazdırır
run() {
  if (( DRYRUN )); then
    _log "${C_DIM}${LOG_PREFIX}[DRY  ] $*${C_RST}"
    return 0
  fi
  debug "exec: $*"
  "$@"
}

# run_soft — hata verse de akışı durdurmaz, uyarı basar
run_soft() {
  local desc="$1"; shift
  if (( DRYRUN )); then
    _log "${C_DIM}${LOG_PREFIX}[DRY  ] $*${C_RST}"
    return 0
  fi
  if ! "$@" >/dev/null 2>&1; then
    warn "$desc"
    return 1
  fi
  return 0
}

# ---- etkileşim ----
# confirm "soru" [varsayilan:e|h]
confirm() {
  local q="$1" def="${2:-h}" ans
  if (( ASSUME_YES )); then debug "otomatik onay: $q"; return 0; fi
  if (( ! INTERACTIVE )); then
    [[ "$def" == "e" ]] && return 0 || return 1
  fi
  local hint="e/H"; [[ "$def" == "e" ]] && hint="E/h"
  read -r -p "$(printf '%s%s%s (%s): ' "$C_B" "$q" "$C_RST" "$hint")" ans </dev/tty || ans=""
  ans="${ans:-$def}"
  [[ "$ans" == "e" || "$ans" == "E" || "$ans" == "y" || "$ans" == "Y" ]]
}

# ask "soru" "varsayilan" -> stdout'a cevabı yazar
ask() {
  local q="$1" def="${2:-}" ans
  if (( ! INTERACTIVE )) || (( ASSUME_YES )); then printf '%s' "$def"; return 0; fi
  if [[ -n "$def" ]]; then
    read -r -p "$(printf '%s%s%s [%s]: ' "$C_B" "$q" "$C_RST" "$def")" ans </dev/tty || ans=""
  else
    read -r -p "$(printf '%s%s%s: ' "$C_B" "$q" "$C_RST")" ans </dev/tty || ans=""
  fi
  printf '%s' "${ans:-$def}"
}

# ask_secret "soru" -> gizli giriş
ask_secret() {
  local q="$1" ans
  if (( ! INTERACTIVE )); then printf ''; return 0; fi
  read -r -s -p "$(printf '%s%s%s: ' "$C_B" "$q" "$C_RST")" ans </dev/tty || ans=""
  printf '\n' >&2
  printf '%s' "$ans"
}

# choose "başlık" "sec1" "sec2" ... -> seçilen indeksi (1-based) stdout'a yazar
choose() {
  local title="$1"; shift
  local -a opts=("$@")
  local i ans
  if (( ! INTERACTIVE )); then printf '1'; return 0; fi
  _log ""
  _log "${C_B}${title}${C_RST}"
  for i in "${!opts[@]}"; do
    _log "  $((i+1))) ${opts[$i]}"
  done
  while :; do
    read -r -p "$(printf 'Seçiminiz [1-%d]: ' "${#opts[@]}")" ans </dev/tty || ans="1"
    ans="${ans:-1}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
      printf '%s' "$ans"; return 0
    fi
    warn "Geçersiz seçim."
  done
}

# ---- yardımcılar ----
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Gerekli komut bulunamadı: $c"
  done
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# POSIX tek-tırnak escape (ssh üzerinden komut geçirmek için güvenli).
# İçerideki her ' karakteri '\'' dizisine dönüştürülür.
shq() {
  local s="$1" q="'"
  s="${s//$q/$q\\$q$q}"
  printf '%s%s%s' "$q" "$s" "$q"
}

# Birden fazla argümanı tek bir güvenli komut dizgisine çevirir
shq_cmd() {
  local out="" a
  for a in "$@"; do out+="$(shq "$a") "; done
  printf '%s' "${out% }"
}

sql_escape() { printf '%s' "${1//\'/\'\'}"; }

# domain.com -> domain_com
slugify() {
  local s="${1//./_}"
  s="${s//-/_}"
  printf '%s' "$s"
}

rand_pass() {
  local n="${1:-18}"
  if has_cmd openssl; then
    openssl rand -base64 $(( n * 2 )) | tr -dc 'A-Za-z0-9' | head -c "$n"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n"
  fi
  printf ''
}

rand_hex() {
  local n="${1:-3}"
  if has_cmd openssl; then openssl rand -hex "$n"
  else tr -dc 'a-f0-9' </dev/urandom | head -c $(( n * 2 )); fi
}

# Plesk parola politikasına uygun güçlü parola (harf+rakam+sembol garantili)
strong_pass() {
  printf '%s%s%s%s' "$(rand_pass 14)" "A" "9" "!"
}

human_size() {
  local b="${1:-0}"
  if (( b > 1073741824 )); then printf '%s GB' "$(( b / 1073741824 ))"
  elif (( b > 1048576 )); then printf '%s MB' "$(( b / 1048576 ))"
  elif (( b > 1024 )); then printf '%s KB' "$(( b / 1024 ))"
  else printf '%s B' "$b"; fi
}

secure_rm() {
  local f
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    if has_cmd shred; then shred -u "$f" 2>/dev/null || rm -f "$f"
    else rm -f "$f"; fi
  done
}

# ---- geçici dizin yönetimi ----
CLONE_TMP=""
_tmp_cleanup() {
  local rc=$?
  [[ -n "$CLONE_TMP" && -d "$CLONE_TMP" ]] && rm -rf "$CLONE_TMP" 2>/dev/null || true
  return $rc
}

init_tmp() {
  [[ -n "$CLONE_TMP" ]] && return 0
  CLONE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/plesk-clone.XXXXXX")"
  chmod 700 "$CLONE_TMP"
  # Ana akış kendi kapsamlı temizlik kancasını kurduysa üzerine yazma
  (( ${CLEANUP_HOOK_INSTALLED:-0} )) || trap _tmp_cleanup EXIT INT TERM
  debug "geçici dizin: $CLONE_TMP"
}

# ---- log dosyaları / gizli bilgi kayıtları ----
init_logdir() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  chmod 700 "$LOG_DIR" 2>/dev/null || true
}

# Rapora girecek "elle yapilmasi gereken" notlari
MANUAL_NOTES_FILE=""
manual_note() {
  init_tmp
  MANUAL_NOTES_FILE="${MANUAL_NOTES_FILE:-$CLONE_TMP/manual_notes.txt}"
  printf '%s\n' "$*" >>"$MANUAL_NOTES_FILE"
}

# secret_write <dosya-adi> <satir>
secret_write() {
  local f="$LOG_DIR/$1"; shift
  init_logdir
  printf '%s\n' "$*" >>"$f"
  chmod 600 "$f" 2>/dev/null || true
}

# ---- listeler (bileşen yönetimi) ----
# csv_contains "a,b,c" "b"
csv_contains() {
  local list=",${1},"
  [[ "$list" == *",${2},"* ]]
}

# stdin'deki satırları "a, b, c" biçiminde birleştirir
comma_join() { tr '\n' ' ' | sed -e 's/  */, /g' -e 's/, $//'; }
