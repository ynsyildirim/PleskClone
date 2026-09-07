#!/usr/bin/env bash
# ===========================================================================
# Plesk Clone / Migrate — tek giriş noktası
#
# Aynı sunucuda klonlama ve farklı sunucuya birebir taşıma için ortak akış.
# Hedef sunucudaki tüm işlemler "agent" modu üzerinden yapılır; böylece local
# ve remote senaryolar arasında mantık farkı yoktur.
#
# Kaynak: https://github.com/ynsyildirim/PleskClone
# ===========================================================================
set -euo pipefail

PLESK_CLONE_VERSION="2.0.0"

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF_PATH")"


# ---- bundled build (build.sh tarafından üretildi) ----
PLESK_CLONE_BUNDLED=1

# ===== lib/00-core.sh =====
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

# ===== lib/10-plesk.sh =====
# ---------------------------------------------------------------------------
# 10-plesk.sh — Plesk CLI ve psa veritabanı sarmalayıcıları
# Bu fonksiyonlar "çalıştığı sunucudaki" Plesk'i sorgular.
# Orkestratörde kaynak domain, agent'ta hedef domain için kullanılır.
# ---------------------------------------------------------------------------

PLESK_BIN="${PLESK_BIN:-plesk}"
VHOST_ROOT="${VHOST_ROOT:-/var/www/vhosts}"

plesk_available() { command -v "$PLESK_BIN" >/dev/null 2>&1; }

# psa veritabanı sorgusu (başlıksız, sekme ayraçlı)
psa() { "$PLESK_BIN" db -Ne "$1" 2>/dev/null || true; }

# Tek değer döndüren sorgu
psa1() { psa "$1" | head -n1; }

plesk_version() {
  "$PLESK_BIN" version 2>/dev/null | awk -F': *' '/Product version/ {print $2; exit}'
}

domain_exists() {
  "$PLESK_BIN" bin domain --info "$1" >/dev/null 2>&1
}

domain_id() {
  psa1 "SELECT id FROM domains WHERE name='$(sql_escape "$1")' LIMIT 1;"
}

domain_guid() {
  psa1 "SELECT guid FROM domains WHERE name='$(sql_escape "$1")' LIMIT 1;"
}

# domain -i çıktısından alan okuma
domain_field() {
  local domain="$1" key="$2"
  "$PLESK_BIN" bin domain -i "$domain" 2>/dev/null | awk -F': ' -v k="$key" '$1==k {print $2; exit}'
}

domain_system_user() {
  psa1 "SELECT su.login
        FROM sys_users su
        JOIN hosting h ON h.sys_user_id=su.id
        JOIN domains d ON d.id=h.dom_id
        WHERE d.name='$(sql_escape "$1")' LIMIT 1;"
}

domain_system_shell() {
  psa1 "SELECT su.shell
        FROM sys_users su
        JOIN hosting h ON h.sys_user_id=su.id
        JOIN domains d ON d.id=h.dom_id
        WHERE d.name='$(sql_escape "$1")' LIMIT 1;"
}

# Gerçek document root (httpdocs varsayımı yerine psa'dan okunur)
domain_docroot() {
  local domain="$1" www
  www="$(psa1 "SELECT h.www_root
                FROM hosting h JOIN domains d ON d.id=h.dom_id
                WHERE d.name='$(sql_escape "$domain")' LIMIT 1;")"
  if [[ -n "$www" ]]; then
    # www_root bazı sürümlerde göreli ("httpdocs"), bazılarında mutlak yol tutar
    if [[ "$www" == /* ]]; then printf '%s' "$www"
    else printf '%s/%s/%s' "$VHOST_ROOT" "$domain" "$www"; fi
  else
    printf '%s/%s/httpdocs' "$VHOST_ROOT" "$domain"
  fi
}

domain_vhost_dir() { printf '%s/%s' "$VHOST_ROOT" "$1"; }

domain_ip() {
  local ip
  ip="$(domain_field "$1" "IP address")"
  [[ -z "$ip" ]] && ip="$(psa1 "SELECT ia.ip_address
                                FROM domains d
                                JOIN DomainServices ds ON ds.dom_id=d.id
                                JOIN IpAddressesCollections ic ON ic.ipCollectionId=ds.ipCollectionId
                                JOIN IP_Addresses ia ON ia.id=ic.ipAddressId
                                WHERE d.name='$(sql_escape "$1")' LIMIT 1;")"
  printf '%s' "$ip"
}

# Makine kimliği — "uzak" sunucunun aslında aynı makine olup olmadığını anlamak için
machine_id() {
  local id=""
  [[ -r /etc/machine-id ]] && id="$(cat /etc/machine-id 2>/dev/null)"
  [[ -z "$id" && -r /var/lib/dbus/machine-id ]] && id="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
  [[ -z "$id" ]] && id="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  printf '%s' "$id"
}

server_primary_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "$ip" ]] && ip="$(psa1 "SELECT ip_address FROM IP_Addresses ORDER BY id LIMIT 1;")"
  printf '%s' "$ip"
}

# Servis planı tespiti — 4 kademeli fallback (orijinal davranış korunur)
domain_service_plan() {
  local domain="$1" plan

  plan="$("$PLESK_BIN" bin domain --info "$domain" 2>/dev/null | awk -F': ' '/^Service plan/ {print $2; exit}')"
  [[ -n "$plan" ]] && { printf '%s' "$plan"; return; }

  plan="$("$PLESK_BIN" bin domain --info "$domain" 2>/dev/null | awk -F': ' '/^Plan/ {print $2; exit}')"
  [[ -n "$plan" ]] && { printf '%s' "$plan"; return; }

  plan="$("$PLESK_BIN" bin subscription --info "$domain" 2>/dev/null | awk -F': ' '/^Service plan/ {print $2; exit}')"
  [[ -n "$plan" ]] && { printf '%s' "$plan"; return; }

  # psa şeması: planlar Templates tablosunda, abonelik eşlemesi
  # PlansSubscriptions + Subscriptions üzerinden yapılır.
  # ("ServicePlans" ve "domains.plan_id" gerçek Plesk'te YOKTUR.)
  plan="$(psa1 "SELECT t.name
                FROM Templates t
                JOIN PlansSubscriptions ps ON ps.plan_id = t.id
                JOIN Subscriptions s ON s.id = ps.subscription_id
                JOIN domains d ON d.id = s.object_id
                WHERE d.name='$(sql_escape "$domain")' AND t.type='domain' LIMIT 1;")"
  printf '%s' "$plan"
}

service_plan_exists() {
  local p; p="$(psa1 "SELECT id FROM Templates WHERE name='$(sql_escape "$1")' AND type='domain' LIMIT 1;")"
  [[ -n "$p" ]]
}

# Hedefte kullanılabilecek bir plan adı (yoksa boş)
default_service_plan() {
  # Tercih sırası: Unlimited > Default Domain > diğerleri
  # (FIELD bilinmeyenler için 0 döner; onları en sona atıyoruz)
  psa1 "SELECT name FROM Templates WHERE type='domain'
        ORDER BY (FIELD(name,'Unlimited','Default Domain') = 0),
                 FIELD(name,'Unlimited','Default Domain'), id
        LIMIT 1;"
}

domain_owner() {
  local o
  o="$(domain_field "$1" "Owner")"
  [[ -z "$o" ]] && o="$(psa1 "SELECT c.login FROM domains d
                              JOIN clients c ON c.id=d.cl_id
                              WHERE d.name='$(sql_escape "$1")' LIMIT 1;")"
  printf '%s' "$o"
}

# ---- PHP ----
# psa şeması: handler kimliği doğrudan hosting.php_handler_id kolonundadır
# (ör. "plesk-php83-fpm"). "php_settings"/"php_handlers" tabloları YOKTUR.
domain_php_handler_id() {
  psa1 "SELECT h.php_handler_id
        FROM hosting h JOIN domains d ON d.id=h.dom_id
        WHERE d.name='$(sql_escape "$1")' LIMIT 1;"
}

# php_handler --list satirlarini ayristirir: "<id> <surum>" ciftleri uretir.
# Sutun sayisina guvenilmez (display name bosluk icerebilir); bu yuzden id ilk
# alandan, surum ise N.N bicimindeki ILK alandan okunur.
_php_handlers() {
  "$PLESK_BIN" bin php_handler --list 2>/dev/null | awk '
    NR==1 || $1 ~ /^id:?$/ { next }
    NF < 2 { next }
    {
      ver=""
      for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+$/) { ver=$i; break }
      if (ver != "") print $1 "\t" ver
    }'
}

# Handler kimliginden surumu bul: plesk-php83-fpm -> 8.3
domain_php_version() {
  local h; h="$(domain_php_handler_id "$1")"
  [[ -z "$h" ]] && return 0
  local v
  v="$(_php_handlers | awk -F'\t' -v id="$h" '$1==id {print $2; exit}')"
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  # CLI kullanilamiyorsa kimlikten turet
  if [[ "$h" =~ php([0-9])([0-9]+) ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# Hedefte bu handler kimligi tanimli mi
php_handler_exists() {
  _php_handlers | awk -F'\t' -v id="$1" '$1==id {f=1} END{exit !f}'
}

# Verilen ana surum (ve istege bagli tip soneki) icin bir handler kimligi bul
php_handler_find() {
  local major="$1" suffix="${2:-}"
  _php_handlers | awk -F'\t' -v maj="$major" -v sfx="$suffix" '
    $2 == maj && (sfx == "" || $1 ~ (sfx "$")) { print $1; exit }'
}

# Özel php.ini direktifleri (dom_param üzerinden)
domain_php_custom_settings() {
  psa "SELECT dp.param, dp.val FROM dom_param dp
       JOIN domains d ON d.id=dp.dom_id
       WHERE d.name='$(sql_escape "$1")' AND dp.param LIKE 'php_%';"
}

# ---- MySQL admin erişimi ----
mysql_admin_user() { printf '%s' "${MYSQL_ADMIN_USER:-admin}"; }

PSA_SHADOW_FILE="${PSA_SHADOW_FILE:-/etc/psa/.psa.shadow}"

mysql_admin_pass() {
  local p
  p="$(cat "$PSA_SHADOW_FILE" 2>/dev/null || true)"
  printf '%s' "$p"
}

# mysql_q <sorgu> [db] — admin kimliğiyle sorgu (başlıksız)
mysql_q() {
  local q="$1" db="${2:-}"
  local u p; u="$(mysql_admin_user)"; p="$(mysql_admin_pass)"
  [[ -z "$p" ]] && return 1
  if [[ -n "$db" ]]; then
    MYSQL_PWD="$p" mysql -u"$u" -N -B -e "$q" "$db" 2>/dev/null
  else
    MYSQL_PWD="$p" mysql -u"$u" -N -B -e "$q" 2>/dev/null
  fi
}

# ---- veritabanları ----
list_domain_dbs() {
  psa "SELECT d.name FROM data_bases d
       JOIN domains dm ON dm.id=d.dom_id
       WHERE dm.name='$(sql_escape "$1")' AND d.type='mysql';"
}

db_server_id() {
  psa1 "SELECT d.db_server_id FROM data_bases d
        JOIN domains dm ON dm.id=d.dom_id
        WHERE dm.name='$(sql_escape "$2")' AND d.name='$(sql_escape "$1")' LIMIT 1;"
}

# Bir veritabanına bağlı Plesk DB kullanıcıları
list_db_users() {
  psa "SELECT du.login FROM db_users du
       JOIN data_bases d ON d.id=du.db_id
       WHERE d.name='$(sql_escape "$1")';"
}

# Plesk'in sakladığı düz metin parola (accounts.type='plain' ise geri okunabilir)
db_user_plain_password() {
  local dbname="$1" login="$2" row type pass
  row="$(psa "SELECT a.type, a.password FROM db_users du
              JOIN data_bases d ON d.id=du.db_id
              JOIN accounts a ON a.id=du.account_id
              WHERE d.name='$(sql_escape "$dbname")' AND du.login='$(sql_escape "$login")' LIMIT 1;")"
  [[ -z "$row" ]] && return 1
  type="$(printf '%s' "$row" | cut -f1)"
  pass="$(printf '%s' "$row" | cut -f2-)"
  [[ "$type" == "plain" && -n "$pass" ]] || return 1
  printf '%s' "$pass"
}

# MySQL seviyesindeki parola hash'i (plugin<TAB>hash)
db_user_auth_hash() {
  local login="$1" host="$2" row
  row="$(mysql_q "SELECT plugin, authentication_string FROM mysql.user
                  WHERE user='$(sql_escape "$login")' AND host='$(sql_escape "$host")' LIMIT 1;")" || return 1
  if [[ -z "$row" || "$(printf '%s' "$row" | cut -f2)" == "" ]]; then
    # MariaDB <10.4 / MySQL 5.6: parola 'password' kolonunda
    row="$(mysql_q "SELECT 'mysql_native_password', password FROM mysql.user
                    WHERE user='$(sql_escape "$login")' AND host='$(sql_escape "$host")' LIMIT 1;")" || return 1
  fi
  [[ -z "$row" ]] && return 1
  printf '%s' "$row"
}

# Kullanıcının erişim host'ları (virgülle)
db_user_hosts() {
  local login="$1" hosts
  hosts="$(mysql_q "SELECT host FROM mysql.user WHERE user='$(sql_escape "$login")';" || true)"
  [[ -z "$hosts" ]] && { printf 'localhost'; return; }
  printf '%s' "$hosts" | paste -sd',' -
}

# ---- alt alan adları / alias / mail / ftp ----
list_subdomains() {
  psa "SELECT d.name FROM domains d
       JOIN domains p ON p.id = d.parentDomainId
       WHERE p.name='$(sql_escape "$1")';"
}

list_domain_aliases() {
  psa "SELECT da.name FROM domain_aliases da
       JOIN domains d ON d.id=da.dom_id
       WHERE d.name='$(sql_escape "$1")';"
}

list_mailboxes() {
  psa "SELECT m.mail_name, a.type, a.password
       FROM mail m
       JOIN domains d ON d.id=m.dom_id
       LEFT JOIN accounts a ON a.id=m.account_id
       WHERE d.name='$(sql_escape "$1")';"
}

list_ftp_users() {
  psa "SELECT su.login, su.home
       FROM sys_users su
       JOIN domains d ON d.id=su.subdomain_id OR d.id=(SELECT dom_id FROM hosting WHERE sys_user_id=su.id LIMIT 1)
       WHERE d.name='$(sql_escape "$1")' AND su.id NOT IN (SELECT sys_user_id FROM hosting);"
}

# ---- DNS ----
list_dns_records() {
  psa "SELECT dr.type, dr.host, dr.val, dr.opt, dr.displayHost, dr.displayVal
       FROM dns_recs dr
       JOIN dns_zone z ON z.id = dr.dns_zone_id
       JOIN domains d ON d.dns_zone_id = z.id
       WHERE d.name='$(sql_escape "$1")' AND dr.type NOT IN ('SOA','NS');"
}

# ---- SSL sertifikaları ----
domain_certificate_name() {
  psa1 "SELECT c.name FROM certificates c
        JOIN domains d ON d.certificate_id = c.id
        WHERE d.name='$(sql_escape "$1")' LIMIT 1;"
}

# Sertifika içeriği: cert / pvt / ca kolonları
certificate_part() {
  local certname="$1" col="$2"
  psa1 "SELECT $col FROM certificates WHERE name='$(sql_escape "$certname")' LIMIT 1;"
}

# ===== lib/20-transport.sh =====
# ---------------------------------------------------------------------------
# 20-transport.sh — local/remote soyutlaması
#
# Tek bir kod yolu ile hem aynı sunucuda hem farklı sunucuda çalışabilmek için
# hedef taraftaki tüm işlemler "agent" üzerinden çağrılır:
# TRANSPORT=local   -> agent aynı makinede bash ile çalışır
# TRANSPORT=remote  -> agent ssh üzerinden hedef sunucuda çalışır
#
# Böylece local ve remote akışları arasında hiçbir mantık farkı kalmaz.
# ---------------------------------------------------------------------------

TRANSPORT="${TRANSPORT:-local}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_KEY="${REMOTE_KEY:-}"

AGENT_DIR=""          # agent'ın hedef sunucudaki dizini
AGENT_PATH=""         # agent script'inin hedef sunucudaki tam yolu
SSH_CTL=""            # ControlMaster soket yolu
declare -a SSH_OPTS=()

is_remote() { [[ "$TRANSPORT" == "remote" ]]; }

remote_label() {
  if is_remote; then printf '%s@%s:%s' "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT"
  else printf 'localhost'; fi
}

# ---- ssh kurulumu ----
transport_init() {
  init_tmp
  if ! is_remote; then
    debug "transport: local"
    return 0
  fi

  require_cmd ssh rsync
  # Soket yolu boşluk içermemeli: rsync -e dizgisini kabuk gibi ayrıştırmaz.
  SSH_CTL="/tmp/plesk-clone-ssh-$$-%C"
  SSH_OPTS=(
    -p "$REMOTE_PORT"
    -o ConnectTimeout=15
    -o ServerAliveInterval=30
    -o ControlMaster=auto
    -o ControlPersist=15m
    -o "ControlPath=$SSH_CTL"
  )
  [[ -n "$REMOTE_KEY" ]] && SSH_OPTS+=(-i "$REMOTE_KEY")

  info "SSH bağlantısı kuruluyor: $(remote_label)"
  if ! ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" true; then
    die "SSH bağlantısı kurulamadı: $(remote_label) (anahtar tabanlı kimlik doğrulama önerilir)"
  fi
  ok "SSH bağlantısı hazır (multiplexing aktif — tek kimlik doğrulama)"
}

transport_close() {
  if is_remote && [[ -n "$SSH_CTL" ]]; then
    ssh "${SSH_OPTS[@]}" -O exit "${REMOTE_USER}@${REMOTE_HOST}" >/dev/null 2>&1 || true
  fi
}

# rsync'in -e parametresi için: rsync bu dizgiyi kabuk gibi ayrıştırmaz,
# sadece boşluklardan böler. Bu yüzden tırnak KULLANILMAZ.
ssh_cmd_string() { printf 'ssh %s' "${SSH_OPTS[*]}"; }

# ---- uzak/yerel komut çalıştırma ----
_rt_exec_impl() {
  local nostdin="$1" cmd="$2"
  if is_remote; then
    if (( nostdin )); then
      ssh -n "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -c $(shq "$cmd")"
    else
      ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -c $(shq "$cmd")"
    fi
  else
    if (( nostdin )); then bash -c "$cmd" </dev/null
    else bash -c "$cmd"; fi
  fi
}

# rt_exec — stdin KAPALI çalıştırır.
# Kritik: `while read ... done <<<"$liste"` döngüleri içinden çağrıldığında
# ssh/bash döngünün girdisini yutmasın diye stdin /dev/null'a bağlanır.
rt_exec() { _rt_exec_impl 1 "$1"; }

# rt_exec_stdin — stdin'i hedefe akıtır (mysqldump | ... | agent db-import gibi)
rt_exec_stdin() { _rt_exec_impl 0 "$1"; }

# ---- dosya aktarımı ----
# rt_put <yerel-dosya> <hedef-yol>
rt_put() {
  local src="$1" dst="$2"
  if is_remote; then
    rsync -q -e "$(ssh_cmd_string)" "$src" "${REMOTE_USER}@${REMOTE_HOST}:$dst"
  else
    [[ "$src" == "$dst" ]] || cp -a "$src" "$dst"
  fi
}

# rt_get <hedefteki-dosya> <yerel-yol>
rt_get() {
  local src="$1" dst="$2"
  if is_remote; then
    rsync -q -e "$(ssh_cmd_string)" "${REMOTE_USER}@${REMOTE_HOST}:$src" "$dst"
  else
    [[ "$src" == "$dst" ]] || cp -a "$src" "$dst"
  fi
}

# rsync yetenek tespiti: eski sürümlerde -A/-X/-H yok, körlemesine kullanılamaz
RSYNC_BASE_FLAGS=""
_rsync_base_flags() {
  if [[ -z "$RSYNC_BASE_FLAGS" ]]; then
    local help; help="$(rsync --help 2>&1 || true)"
    local f="-a"
    [[ "$help" == *"--hard-links"* ]] && f+="H"
    [[ "$help" == *"--acls"* ]]       && f+="A"
    [[ "$help" == *"--xattrs"* ]]     && f+="X"
    RSYNC_BASE_FLAGS="$f"
    debug "rsync bayrakları: $RSYNC_BASE_FLAGS"
  fi
  printf '%s' "$RSYNC_BASE_FLAGS"
}

# rt_rsync_dir <yerel-kaynak-dizin/> <hedef-dizin/> [ekstra rsync argümanları...]
rt_rsync_dir() {
  local src="$1" dst="$2"; shift 2
  local -a extra=("$@")
  if (( DRYRUN )); then
    _log "${C_DIM}${LOG_PREFIX}[DRY  ] rsync ${extra[*]} $src -> $(is_remote && printf '%s:' "$REMOTE_HOST")$dst${C_RST}"
    return 0
  fi
  local base; base="$(_rsync_base_flags)"
  if is_remote; then
    rsync "$base" --numeric-ids "${extra[@]}" -e "$(ssh_cmd_string)" \
      "$src" "${REMOTE_USER}@${REMOTE_HOST}:$dst"
  else
    rsync "$base" "${extra[@]}" "$src" "$dst"
  fi
}

# ---- agent dağıtımı ----
# Çalışan script'in tek dosyalık bir kopyasını üretir (lib/ varsa birleştirilir).
build_self_bundle() {
  local out="$1"
  if [[ -n "${PLESK_CLONE_BUNDLED:-}" ]] || [[ ! -d "$SELF_DIR/lib" ]]; then
    cp -f "$SELF_PATH" "$out"
  else
    bundle_inline "$SELF_PATH" "$SELF_DIR/lib" "$out"
  fi
  chmod 700 "$out"
}

# Tek dosyalık kendi kendine yeten kopya üretir (lib/ içeriği gövdeye gömülür)
bundle_inline() {
  local entry="$1" libdir="$2" out="$3" f
  : >"$out"
  awk '/^# @@LIB_INJECT@@/{exit} {print}' "$entry" >>"$out"
  printf '\nPLESK_CLONE_BUNDLED=1\n' >>"$out"
  for f in "$libdir"/*.sh; do
    printf '\n# ===== %s =====\n' "$(basename "$f")" >>"$out"
    sed '1{/^#!/d;}' "$f" >>"$out"
  done
  awk 'f{print} /^# @@LIB_INJECT_END@@/{f=1}' "$entry" >>"$out"
}

# Agent'ı hedef sunucuya kurar ve bağlam dosyasını gönderir
agent_deploy() {
  local ctx_file="$1"
  init_tmp
  local bundle="$CLONE_TMP/plesk-clone-bundle.sh"
  build_self_bundle "$bundle"

  if is_remote; then
    AGENT_DIR="/tmp/plesk-clone-agent-$$-$(rand_hex 3)"
    rt_exec "mkdir -p $(shq "$AGENT_DIR") && chmod 700 $(shq "$AGENT_DIR")"
    rt_put "$bundle" "$AGENT_DIR/plesk-clone.sh"
    rt_put "$ctx_file" "$AGENT_DIR/ctx.env"
    rt_exec "chmod 700 $(shq "$AGENT_DIR/plesk-clone.sh"); chmod 600 $(shq "$AGENT_DIR/ctx.env")"
  else
    AGENT_DIR="$CLONE_TMP/agent"
    mkdir -p "$AGENT_DIR"
    cp -f "$bundle" "$AGENT_DIR/plesk-clone.sh"
    cp -f "$ctx_file" "$AGENT_DIR/ctx.env"
  fi
  AGENT_PATH="$AGENT_DIR/plesk-clone.sh"
  debug "agent kuruldu: $(remote_label):$AGENT_PATH"
}

agent_cleanup() {
  if is_remote && [[ -n "$AGENT_DIR" ]]; then
    rt_exec "rm -rf $(shq "$AGENT_DIR")" >/dev/null 2>&1 || true
  fi
}

# Bağlam dosyasını güncelleyip hedefe yeniden gönderir
agent_push_ctx() {
  local ctx_file="$1"
  [[ -n "$AGENT_DIR" ]] || return 0
  if is_remote; then
    rt_put "$ctx_file" "$AGENT_DIR/ctx.env"
  else
    cp -f "$ctx_file" "$AGENT_DIR/ctx.env"
  fi
}

# ---- agent çağrıları ----
_agent_cmd() {
  local op="$1"; shift
  local cmd="bash $(shq "$AGENT_PATH") --agent $(shq "$op")"
  [[ $# -gt 0 ]] && cmd+=" $(shq_cmd "$@")"
  printf '%s' "$cmd"
}

# agent <op> [args...] — hedef sunucuda bir işlem çalıştırır (stdin kapalı)
agent() {
  debug "agent[$1] ${*:2}"
  rt_exec "$(_agent_cmd "$@")"
}

# agent_stdin <op> [args...] — stdin'i hedefe akıtır (DB import, crontab)
agent_stdin() {
  debug "agent-stdin[$1] ${*:2}"
  rt_exec_stdin "$(_agent_cmd "$@")"
}

# agent_soft — hata durumunda uyarı verip devam eder
agent_soft() {
  local desc="$1"; shift
  if ! agent "$@"; then
    warn "$desc"
    return 1
  fi
  return 0
}

# ===== lib/30-db.sh =====
# ---------------------------------------------------------------------------
# 30-db.sh — Veritabanı klonlama ve isim/kimlik politikaları
#
# Politikalar:
# DB_MODE       keep | suffix | prefix | map      (veritabanı adı)
# DB_USER_MODE  keep | new    | map               (kullanıcı adı)
# DB_PASS_MODE  keep | new    | map               (parola)
#
# "keep" seçildiğinde hiçbir şey değişmez; uygulama config'i (.env, wp-config)
# olduğu gibi çalışmaya devam eder. Farklı sunucuya birebir taşıma senaryosunun
# temelidir.
# ---------------------------------------------------------------------------

DB_MODE="${DB_MODE:-suffix}"
DB_SUFFIX="${DB_SUFFIX:-}"
DB_PREFIX="${DB_PREFIX:-}"
DB_MAP="${DB_MAP:-}"              # "eski1=yeni1,eski2=yeni2"
DB_USER_MODE="${DB_USER_MODE:-new}"
DB_USER_SUFFIX="${DB_USER_SUFFIX:-}"
DB_USER_MAP="${DB_USER_MAP:-}"
DB_PASS_MODE="${DB_PASS_MODE:-new}"
DB_PASS_MAP="${DB_PASS_MAP:-}"
DB_OVERWRITE="${DB_OVERWRITE:-0}"

# Eski -> yeni eşlemelerinin tutulduğu dosya (config rewrite için kullanılır)
DB_CHANGES_FILE=""

# csv haritasından değer çek: map_lookup "a=1,b=2" "b" -> 2
map_lookup() {
  local map="$1" key="$2" pair
  local IFS=','
  for pair in $map; do
    [[ "${pair%%=*}" == "$key" ]] && { printf '%s' "${pair#*=}"; return 0; }
  done
  return 1
}

resolve_db_name() {
  local src="$1" out
  case "$DB_MODE" in
    keep)   out="$src" ;;
    suffix) out="${src}_${DB_SUFFIX}" ;;
    prefix) out="${DB_PREFIX}_${src}" ;;
    map)    out="$(map_lookup "$DB_MAP" "$src" || printf '%s' "$src")" ;;
    *)      out="$src" ;;
  esac
  printf '%s' "$out"
}

resolve_db_user() {
  local src="$1" out
  case "$DB_USER_MODE" in
    keep) out="$src" ;;
    new)  out="u_${DB_USER_SUFFIX}_$(rand_hex 3)" ;;
    map)  out="$(map_lookup "$DB_USER_MAP" "$src" || printf '%s' "$src")" ;;
    *)    out="$src" ;;
  esac
  # MySQL kullanıcı adı 32 karakterle sınırlı (MySQL 8'de 32, eski sürümlerde 16)
  printf '%s' "${out:0:32}"
}

# resolve_db_pass <kaynak-db> <kaynak-kullanici>
# stdout: <yontem>\t<deger1>\t<deger2>
# plain <parola>              -> düz metin parola bilinip aynen kullanılacak
# hash  <plugin> <hash>       -> düz metin bilinmiyor, MySQL hash'i kopyalanacak
# new   <parola>              -> yeni rastgele parola
resolve_db_pass() {
  local db="$1" user="$2" p

  case "$DB_PASS_MODE" in
    map)
      if p="$(map_lookup "$DB_PASS_MAP" "$user")"; then
        printf 'plain\t%s' "$p"; return 0
      fi
      ;;
    keep)
      # 1) Plesk'in sakladığı düz metin parola
      if p="$(db_user_plain_password "$db" "$user")"; then
        printf 'plain\t%s' "$p"; return 0
      fi
      # 2) MySQL parola hash'i (Plesk düz metni saklamıyorsa)
      local host hash_row
      host="$(db_user_hosts "$user" | cut -d, -f1)"
      if hash_row="$(db_user_auth_hash "$user" "$host")" && [[ -n "$hash_row" ]]; then
        printf 'hash\t%s' "$hash_row"; return 0
      fi
      warn "  '$user' parolası geri okunamadı; yeni parola üretilecek."
      ;;
  esac
  printf 'new\t%s' "$(strong_pass)"
}

# ---- mysqldump argümanları (sürüme göre uyarlanır) ----
_mysqldump_args() {
  local -a a=(--single-transaction --quick --routines --triggers --hex-blob)
  if mysqldump --help 2>/dev/null | grep -q -- '--no-tablespaces'; then
    a+=(--no-tablespaces)
  fi
  if mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then
    a+=(--set-gtid-purged=OFF)
  fi
  printf '%s\n' "${a[@]}"
}

# ---- ana akış ----
clone_databases() {
  local dbs total=0 idx=0
  dbs="$(list_domain_dbs "$SOURCE")"

  if [[ -z "$dbs" ]]; then
    info "Kaynak domain'de MySQL veritabanı yok, atlanıyor."
    return 0
  fi

  total="$(printf '%s\n' "$dbs" | grep -c . || true)"
  info "Kaynak domain'de $total veritabanı bulundu."
  info "İsim politikası: $DB_MODE | Kullanıcı: $DB_USER_MODE | Parola: $DB_PASS_MODE"

  local admin_pass; admin_pass="$(mysql_admin_pass)"
  [[ -z "$admin_pass" ]] && { warn "/etc/psa/.psa.shadow okunamadı; veritabanı aşaması atlanıyor."; return 1; }

  local -a dumpargs=()
  local _a
  while IFS= read -r _a; do [[ -n "$_a" ]] && dumpargs+=("$_a"); done < <(_mysqldump_args)

  init_logdir
  DB_CHANGES_FILE="${DB_CHANGES_FILE:-$CLONE_TMP/db_changes.tsv}"
  : >"$DB_CHANGES_FILE"

  local DB
  while IFS= read -r DB; do
    [[ -z "$DB" ]] && continue
    idx=$((idx+1))
    local NEWDB; NEWDB="$(resolve_db_name "$DB")"

    if (( ${#NEWDB} > 64 )); then
      warn "  Veritabanı adı 64 karakteri aşıyor, kısaltılıyor: $NEWDB"
      NEWDB="${NEWDB:0:64}"
    fi

    step "[$idx/$total] Veritabanı: $DB -> $NEWDB"

    # Hedefte var mı?
    #
    # Yıkıcı olan işlem yalnızca VERİ AKTARIMIDIR; kullanıcı ve yetki oluşturmak
    # güvenli ve tekrarlanabilirdir. Bu yüzden veritabanı zaten varsa adımın
    # tamamı atlanmaz: sadece import atlanır. Aksi halde hedefte veritabanı olup
    # kullanıcısı/yetkisi olmayan, yani ÇALIŞMAYAN bir klon kalıyordu.
    local skip_import=0
    local exists; exists="$(agent db-exists "$NEWDB" 2>/dev/null || printf '0')"
    if [[ "$exists" == "1" ]]; then
      if (( DB_OVERWRITE )); then
        warn "  Hedefte '$NEWDB' zaten var — içeriği üzerine yazılacak."
      else
        warn "  Hedefte '$NEWDB' zaten var — veri aktarımı atlanıyor (--db-overwrite ile yazılır)."
        info "  Kullanıcı ve yetkiler yine de doğrulanacak."
        skip_import=1
      fi
    else
      agent db-create "$NEWDB" "$TARGET" || { err "  Veritabanı oluşturulamadı: $NEWDB"; continue; }
      ok "  Veritabanı oluşturuldu: $NEWDB"
    fi

    [[ "$DB" != "$NEWDB" ]] && printf 'db\t%s\t%s\n' "$DB" "$NEWDB" >>"$DB_CHANGES_FILE"

    # ---- kullanıcılar ----
    local users; users="$(list_db_users "$DB")"
    if [[ -z "$users" ]]; then
      warn "  '$DB' için Plesk DB kullanıcısı bulunamadı."
    fi

    local U
    while IFS= read -r U; do
      [[ -z "$U" ]] && continue
      local NEWU; NEWU="$(resolve_db_user "$U")"
      local passinfo method v1 v2
      passinfo="$(resolve_db_pass "$DB" "$U")"
      method="$(printf '%s' "$passinfo" | cut -f1)"
      v1="$(printf '%s' "$passinfo" | cut -f2)"
      v2="$(printf '%s' "$passinfo" | cut -f3)"

      local hosts; hosts="$(db_user_hosts "$U")"
      local create_pass="$v1"
      [[ "$method" == "hash" ]] && create_pass="$(strong_pass)"

      info "  Kullanıcı: $U -> $NEWU (parola: $method, host: $hosts)"

      if agent db-user-create "$NEWDB" "$NEWU" "$create_pass" "$hosts" "$TARGET"; then
        # Kullanici zaten varsa Plesk yalnizca parolayi gunceller; yetkinin
        # gercekten durdugunu garanti etmek icin idempotent bir GRANT atiyoruz.
        agent db-user-grant "$NEWDB" "$NEWU" "$hosts" \
          || warn "    Yetki dogrulanamadi: $NEWU -> $NEWDB"
        if [[ "$method" == "hash" ]]; then
          # Plesk kullanıcıyı geçici parolayla oluşturdu; MySQL parolasını kaynakla eşitle
          if agent db-user-set-hash "$NEWU" "$hosts" "$v1" "$v2"; then
            ok "    Parola hash'i kaynaktan kopyalandı (uygulama config'i değişmeden çalışır)"
            warn "    Plesk arayüzü bu kullanıcı için farklı bir parola gösterecek: $create_pass"
            secret_write "${TARGET}_DB_INFO.txt" \
              "DB: $NEWDB | USER: $NEWU | PAROLA: <kaynakla aynı (hash kopyalandı)> | Plesk-UI parolası: $create_pass"
          else
            warn "    Hash kopyalanamadı; geçerli parola: $create_pass"
            warn "    Config dosyalarındaki parola OTOMATİK güncellenemez."
            secret_write "${TARGET}_DB_INFO.txt" "DB: $NEWDB | USER: $NEWU | PAROLA: $create_pass"
            # Eski parola bilinmediği için metin değişimi YAPILAMAZ.
            # Buraya 'dbpass <kullanıcı> <yeni parola>' yazmak, config'lerde
            # kullanıcı adını parolayla değiştirip klonu bozardı.
            manual_note "DB parolası elle güncellenmeli: $NEWDB / $NEWU -> $create_pass (kaynak parola okunamadı)"
          fi
        else
          secret_write "${TARGET}_DB_INFO.txt" "DB: $NEWDB | USER: $NEWU | PAROLA: $create_pass"
          if [[ "$method" == "new" ]]; then
            local oldpass
            oldpass="$(db_user_plain_password "$DB" "$U" || true)"
            if [[ -n "$oldpass" ]]; then
              printf 'dbpass\t%s\t%s\n' "$oldpass" "$create_pass" >>"$DB_CHANGES_FILE"
            else
              # Eski parola geri okunamadi: metin degisimi yapilamaz.
              # Sessiz kalirsak klonlanan uygulama "Access denied" ile patlar.
              warn "    '$U' kullanicisinin eski parolasi okunamadi."
              warn "    Config dosyalarindaki parola OTOMATIK guncellenemez."
              manual_note "DB parolasi elle guncellenmeli: $NEWDB / $NEWU -> $create_pass (eski parola okunamadi)"
            fi
          fi
        fi
        [[ "$U" != "$NEWU" ]] && printf 'dbuser\t%s\t%s\n' "$U" "$NEWU" >>"$DB_CHANGES_FILE"
      else
        warn "    Kullanıcı oluşturulamadı: $NEWU"
      fi
    done <<<"$users"

    # ---- veri aktarımı ----
    if (( DRYRUN )); then
      skipmsg "  DRY-RUN: '$DB' dökümü/aktarımı atlandı"
      continue
    fi

    if (( skip_import )); then
      skipmsg "  Veri aktarımı atlandı (hedefte veritabanı zaten var)"
      continue
    fi

    info "  Veri aktarılıyor (mysqldump -> hedef)..."
    local rc=0
    MYSQL_PWD="$admin_pass" mysqldump -u"$(mysql_admin_user)" "${dumpargs[@]}" "$DB" \
      | gzip -1 \
      | agent_stdin db-import "$NEWDB" || rc=$?
    if (( rc == 0 )); then
      ok "  Veri aktarımı tamamlandı: $NEWDB"
    else
      err "  Veri aktarımı başarısız: $DB -> $NEWDB (rc=$rc)"
    fi
  done <<<"$dbs"

  [[ -s "$LOG_DIR/${TARGET}_DB_INFO.txt" ]] && info "DB erişim bilgileri: $LOG_DIR/${TARGET}_DB_INFO.txt (600)"
  return 0
}

# ---- agent tarafı işlemler ----
agent_db_exists() {
  local name="$1"
  local out
  # LIKE KULLANILMAZ: '_' ve '%' SQL joker karakterleridir ve veritabanı
  # adlarında sık geçer (shop_db, blogdb_stg1_demo_test ...).
  # "SHOW DATABASES LIKE 'shop_db'" alakasız 'shopXdb' ile de eşleşir; bu da
  # var olmayan bir veritabanını "zaten var" sanıp oluşturmamaya yol açardı.
  out="$(mysql_q "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
                  WHERE SCHEMA_NAME='$(sql_escape "$name")' LIMIT 1;" || true)"
  [[ -n "$out" ]] && printf '1' || printf '0'
}

agent_db_create() {
  local name="$1" domain="$2"
  (( DRYRUN )) && { info "DRY: database --create $name"; return 0; }
  "$PLESK_BIN" bin database --create "$name" -domain "$domain" -type mysql -server localhost
}

agent_db_drop() {
  local name="$1" domain="$2"
  (( DRYRUN )) && { info "DRY: database --remove $name"; return 0; }
  "$PLESK_BIN" bin database --remove "$name" -domain "$domain" -type mysql -server localhost
}

agent_db_user_create() {
  local db="$1" login="$2" pass="$3" hosts="$4" domain="$5"
  (( DRYRUN )) && { info "DRY: database --create-dbuser $login"; return 0; }

  # Kullanıcı zaten varsa (aynı adı koruma modunda olabilir) parolasını güncelle
  local existing
  existing="$("$PLESK_BIN" db -Ne "SELECT du.login FROM db_users du
              JOIN data_bases d ON d.id=du.db_id
              WHERE d.name='$(sql_escape "$db")' AND du.login='$(sql_escape "$login")' LIMIT 1;" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    "$PLESK_BIN" bin database --update-dbuser "$login" -passwd "$pass" -database "$db" \
      -domain "$domain" -type mysql -server localhost && return 0
    return 1
  fi

  # access-hosts destekleniyorsa kaynaktaki erişim host'larını da taşı
  if "$PLESK_BIN" bin database --help 2>&1 | grep -q -- '-access-hosts'; then
    "$PLESK_BIN" bin database --create-dbuser "$login" -passwd "$pass" -database "$db" \
      -domain "$domain" -type mysql -server localhost -access-hosts "$hosts" && return 0
  fi
  "$PLESK_BIN" bin database --create-dbuser "$login" -passwd "$pass" -database "$db" \
    -domain "$domain" -type mysql -server localhost
}

# MySQL parola hash'ini kaynakla eşitle (uygulama config'i değişmesin diye)
agent_db_user_set_hash() {
  local login="$1" hosts="$2" plugin="$3" hash="$4" h ok_any=0
  (( DRYRUN )) && { info "DRY: ALTER USER $login (hash kopyala)"; return 0; }
  [[ -z "$hash" ]] && return 1
  plugin="${plugin:-mysql_native_password}"

  local IFS=','
  for h in $hosts; do
    [[ -z "$h" ]] && continue
    # MySQL 5.7/8 sozdizimi
    if mysql_q "ALTER USER '$(sql_escape "$login")'@'$(sql_escape "$h")'
                IDENTIFIED WITH '$(sql_escape "$plugin")' AS '$(sql_escape "$hash")';" >/dev/null 2>&1; then
      ok_any=1
    # MariaDB 10.4+ sozdizimi
    elif mysql_q "ALTER USER '$(sql_escape "$login")'@'$(sql_escape "$h")'
                  IDENTIFIED VIA $(sql_escape "$plugin") USING '$(sql_escape "$hash")';" >/dev/null 2>&1; then
      ok_any=1
    # Eski MariaDB / MySQL 5.6
    elif mysql_q "SET PASSWORD FOR '$(sql_escape "$login")'@'$(sql_escape "$h")' = '$(sql_escape "$hash")';" >/dev/null 2>&1; then
      ok_any=1
    fi
  done
  mysql_q "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
  (( ok_any ))
}

# Yetkiyi garanti et (idempotent).
# Plesk kullanıcı zaten varsa yalnızca parolayı günceller; yetkinin gerçekten
# durduğunu doğrulamak, tekrar çalıştırmalarda çalışan bir klon için şart.
agent_db_user_grant() {
  local db="$1" login="$2" hosts="$3" h ok_any=0
  (( DRYRUN )) && { info "DRY: GRANT $db -> $login"; return 0; }
  local IFS=','
  for h in $hosts; do
    [[ -z "$h" ]] && continue
    if mysql_q "GRANT ALL PRIVILEGES ON \`$(sql_escape "$db")\`.* TO '$(sql_escape "$login")'@'$(sql_escape "$h")';" >/dev/null 2>&1; then
      ok_any=1
    fi
  done
  mysql_q "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
  (( ok_any ))
}

# stdin: gzip'lenmiş SQL dökümü
agent_db_import() {
  local name="$1"
  if (( DRYRUN )); then
    info "DRY: $name içine import"
    cat >/dev/null
    return 0
  fi
  local p; p="$(mysql_admin_pass)"
  [[ -z "$p" ]] && { err "MySQL admin parolası okunamadı"; cat >/dev/null; return 1; }
  gunzip -c | MYSQL_PWD="$p" mysql -u"$(mysql_admin_user)" --default-character-set=utf8mb4 "$name"
}

# ===== lib/40-files.sh =====
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

# ===== lib/50-git.sh =====
# ---------------------------------------------------------------------------
# 50-git.sh — Plesk Git Extension klonlama
#
# Orijinal script Git ayarlarını tek bir "INSERT ... SELECT" ile kopyalıyordu;
# bu yalnızca aynı sunucuda çalışır. Burada kaynak SQLite kayıtları taşınabilir
# bir dosyaya aktarılır, hedefte yeniden kurulur. Böylece local ve remote akış
# aynı kodu kullanır.
# ---------------------------------------------------------------------------

GIT_DB_PATH="${GIT_DB_PATH:-/usr/local/psa/var/modules/git/git_db.db}"
GIT_KEYS_DIR="${GIT_KEYS_DIR:-/usr/local/psa/var/modules/git/keys}"

# hex -> düz metin (xxd/base64 bağımlılığı olmadan)
unhex() {
  local h="$1"
  [[ -z "$h" ]] && return 0
  printf '%b' "$(printf '%s' "$h" | sed 's/../\\x&/g')"
}

# Git 2.35.2+ "dubious ownership" koruması: root, başka bir kullanıcıya ait
# depoda çalışırken hata verir. Plesk depoları domain kullanıcısına aittir.
#
# safe.directory yalnizca "korumali" konfigurasyondan okunur: system, global ve
# komut satiri -c. Ortam degiskeni (GIT_CONFIG_*) bilerek yok sayilir. Burada
# yaptigimiz islemler (config/reset/clean) tek surecte kaldigi icin -c yeterli.
git_at() {
  local repo="$1"; shift
  git -c safe.directory="$repo" -c safe.directory='*' --git-dir="$repo" "$@"
}

git_sync() {
  local git_src="$VHOST_SRC/git"

  if [[ ! -d "$git_src" ]]; then
    warn "Kaynakta Plesk Git dizini yok: $git_src"
    return 0
  fi

  # 1) Git dosyalarını (bare repo'lar dahil) kopyala
  info "Git depoları kopyalanıyor: $git_src/ -> $(remote_label):$VHOST_TGT/git/"
  agent ensure-dir "$VHOST_TGT/git" || true
  rt_rsync_dir "$git_src/" "$VHOST_TGT/git/" \
    || { warn "Git dosyaları kopyalanamadı"; return 1; }

  local repo_count
  repo_count="$(find "$git_src" -maxdepth 2 -name '*.git' -type d 2>/dev/null | grep -c . || true)"
  info "Kaynakta $repo_count Git deposu bulundu"

  # 2) Git Extension SQLite kayıtlarını dışa aktar
  if [[ ! -f "$GIT_DB_PATH" ]]; then
    warn "Kaynakta Git Extension veritabanı yok: $GIT_DB_PATH (sadece dosyalar kopyalandı)"
    agent git-finalize || true
    return 0
  fi
  if ! has_cmd sqlite3; then
    warn "sqlite3 komutu yok; Git Extension ayarları aktarılamıyor (dosyalar kopyalandı)"
    agent git-finalize || true
    return 0
  fi

  local src_id; src_id="$(domain_id "$SOURCE")"
  [[ -z "$src_id" ]] && { warn "Kaynak domain ID bulunamadı; Git ayarları atlanıyor"; return 1; }

  init_tmp
  local export_file="$CLONE_TMP/git_repos.psv"
  sqlite3 "$GIT_DB_PATH" "
    SELECT hex(ifnull(name,''))                       || '|' ||
           hex(ifnull(type,''))                       || '|' ||
           hex(ifnull(deploymentMode,''))             || '|' ||
           hex(ifnull(branch,''))                     || '|' ||
           hex(ifnull(deploymentPath,''))             || '|' ||
           hex(ifnull(fetchUrl,''))                   || '|' ||
           hex(ifnull(skipSslVerification,0))         || '|' ||
           hex(ifnull(postDeploymentActionsEnabled,0))|| '|' ||
           hex(ifnull(deploymentsCounter,0))          || '|' ||
           hex(ifnull(postDeploymentActions,''))
    FROM Repositories WHERE domainId = $src_id;
  " >"$export_file" 2>/dev/null || true

  local rows; rows="$(grep -c . "$export_file" 2>/dev/null || printf '0')"
  if [[ "$rows" == "0" ]]; then
    info "Git Extension'da kayıtlı depo yok; sadece dosyalar taşındı"
    agent git-finalize || true
    return 0
  fi
  info "$rows Git deposu kaydı hedefe aktarılıyor"

  local remote_file="$AGENT_DIR/git_repos.psv"
  rt_put "$export_file" "$remote_file"
  agent git-import "$remote_file" || { warn "Git Extension ayarları aktarılamadı"; return 1; }
  ok "Git entegrasyonu tamamlandı"
}

# ---- agent tarafı ----

# Repo adı normalizasyonu: "app.git" -> "app"
_git_repo_basename() {
  local n="$1"
  printf '%s' "${n%.git}"
}

_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif has_cmd uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    printf '%s-%s-4%s-a%s-%s' "$(rand_hex 4)" "$(rand_hex 2)" \
      "$(rand_hex 2 | cut -c2-)" "$(rand_hex 2 | cut -c2-)" "$(rand_hex 6)"
  fi
}

agent_git_import() {
  local file="$1"
  [[ -f "$file" ]] || { err "Git kayıt dosyası yok: $file"; return 1; }
  [[ -f "$GIT_DB_PATH" ]] || { err "Git Extension veritabanı yok: $GIT_DB_PATH"; return 1; }
  has_cmd sqlite3 || { err "sqlite3 komutu yok"; return 1; }

  local tgt_id tgt_guid
  tgt_id="$(domain_id "$TARGET")"
  tgt_guid="$(domain_guid "$TARGET")"
  [[ -z "$tgt_id" ]] && { err "Domain ID bulunamadı: $TARGET"; return 1; }

  local imported=0 line
  while IFS='|' read -r h_name h_type h_mode h_branch h_path h_fetch h_skip h_actions_en h_counter h_actions; do
    [[ -z "$h_name" ]] && continue
    local name type mode branch dpath fetch skipssl actions_en counter actions
    name="$(unhex "$h_name")";           type="$(unhex "$h_type")"
    mode="$(unhex "$h_mode")";           branch="$(unhex "$h_branch")"
    dpath="$(unhex "$h_path")";          fetch="$(unhex "$h_fetch")"
    skipssl="$(unhex "$h_skip")";        actions_en="$(unhex "$h_actions_en")"
    counter="$(unhex "$h_counter")";     actions="$(unhex "$h_actions")"

    name="$(_git_repo_basename "$name")"
    # Yol ve aksiyonlardaki kaynak domain adını hedefe çevir
    if [[ "$SOURCE" != "$TARGET" ]]; then
      dpath="${dpath//$SOURCE/$TARGET}"
      actions="${actions//$SOURCE/$TARGET}"
    fi

    # Mevcut kayıt varsa uuid'leri koru
    local uuid dkuuid
    uuid="$(sqlite3 "$GIT_DB_PATH" \
      "SELECT uuid FROM Repositories WHERE domainId=$tgt_id AND name='$(sql_escape "$name")' LIMIT 1;" 2>/dev/null || true)"
    dkuuid="$(sqlite3 "$GIT_DB_PATH" \
      "SELECT deployKeyUuid FROM Repositories WHERE domainId=$tgt_id AND name='$(sql_escape "$name")' LIMIT 1;" 2>/dev/null || true)"
    [[ -z "$uuid" ]]   && uuid="$(_uuid)"
    [[ -z "$dkuuid" ]] && dkuuid="$(_uuid)"

    info "Git deposu: $name (branch=${branch:-?}, path=${dpath:-?})"
    if (( DRYRUN )); then imported=$((imported+1)); continue; fi

    local actions_sql="NULL"
    [[ -n "$actions" ]] && actions_sql="'$(sql_escape "$actions")'"

    sqlite3 "$GIT_DB_PATH" "
      INSERT OR REPLACE INTO Repositories
        (domainId, name, type, deploymentMode, branch, deploymentPath, fetchUrl, uuid,
         skipSslVerification, postDeploymentActionsEnabled, deploymentsCounter,
         deployKeyUuid, postDeploymentActions, httpUser, httpPassword, smbUserIds)
      VALUES
        ($tgt_id,
         '$(sql_escape "$name")',
         '$(sql_escape "$type")',
         '$(sql_escape "$mode")',
         '$(sql_escape "$branch")',
         '$(sql_escape "$dpath")',
         '$(sql_escape "$fetch")',
         '$uuid',
         ${skipssl:-0},
         ${actions_en:-0},
         ${counter:-0},
         '$dkuuid',
         $actions_sql,
         NULL, NULL, NULL);
    " 2>/dev/null || { warn "Kayıt eklenemedi: $name"; continue; }

    # Deploy key (SSH anahtar çifti)
    mkdir -p "$GIT_KEYS_DIR" 2>/dev/null || true
    local key_path="$GIT_KEYS_DIR/$dkuuid"
    if [[ ! -f "$key_path" ]] && has_cmd ssh-keygen; then
      if ssh-keygen -t rsa -b 4096 -f "$key_path" -N "" -C "plesk-git-${name}@${TARGET}" >/dev/null 2>&1; then
        chown root:root "$key_path" "$key_path.pub" 2>/dev/null || true
        chmod 600 "$key_path" 2>/dev/null || true
        chmod 644 "$key_path.pub" 2>/dev/null || true
        info "  deploy key oluşturuldu"
      else
        warn "  deploy key oluşturulamadı: $name"
      fi
    fi

    if [[ -n "$tgt_guid" ]]; then
      sqlite3 "$GIT_DB_PATH" \
        "INSERT OR REPLACE INTO DeployKeys (uuid, domainUuid, name, isDefault)
         VALUES ('$dkuuid', '$tgt_guid', '$(sql_escape "$name")', 1);" 2>/dev/null \
        || warn "  DeployKeys kaydı eklenemedi: $name"
    fi

    sqlite3 "$GIT_DB_PATH" \
      "INSERT OR REPLACE INTO RepositoryDeploymentInfo
       (repoUuid, lastCommitHash, deployedCommitHash, deployedCommitAuthor, deployedCommitDate, deployedCommitMessage)
       VALUES ('$uuid', NULL, NULL, NULL, NULL, NULL);" 2>/dev/null \
      || warn "  RepositoryDeploymentInfo kaydı eklenemedi: $name"

    # Anahtarı kullanıcıya göster
    if [[ -f "$key_path.pub" ]]; then
      info "  public key: $(cut -c1-60 <"$key_path.pub")..."
    fi

    imported=$((imported+1))
  done <"$file"

  agent_git_finalize
  ok "$imported Git deposu senkronize edildi"
}

# Sanal klasörler (Plesk Git arayüzünün beklediği symlink'ler) + sahiplik
agent_git_finalize() {
  local git_dir="$VHOST_TGT/git"
  [[ -d "$git_dir" ]] || return 0

  local created=0 total=0 repo_path
  for repo_path in "$git_dir"/*.git; do
    [[ -d "$repo_path" ]] || continue
    total=$((total+1))
    local repo_name base link
    repo_name="$(basename "$repo_path")"
    base="${repo_name%.git}"
    link="$git_dir/$base"
    if [[ ! -e "$link" ]]; then
      if (( DRYRUN )); then
        info "DRY: symlink $base -> $repo_name"; created=$((created+1))
      elif ln -sf "$repo_name" "$link" 2>/dev/null; then
        created=$((created+1)); info "  sanal klasör: $base -> $repo_name"
      else
        warn "  sanal klasör oluşturulamadı: $base"
      fi
    fi
  done

  if (( ! DRYRUN )); then
    local sys_tgt; sys_tgt="$(domain_system_user "$TARGET")"
    [[ -n "$sys_tgt" ]] && chown -R "$sys_tgt":psacln "$git_dir" 2>/dev/null || true
  fi

  info "Git sanal klasörler: $created yeni / $total depo"
}

# Bare olmayan depolar için çalışma dizinini hedefe göre yeniden kur
agent_git_reset_worktree() {
  local git_dir="$VHOST_TGT/git" repo_path found=0
  has_cmd git || { warn "git komutu yok; çalışma dizini kurulumu atlandı"; return 0; }
  for repo_path in "$git_dir"/*.git; do
    [[ -d "$repo_path" ]] || continue
    # Iki yerlesim de desteklenir: git dizininin kendisi (<ad>.git/config) ve
    # calisma agaci icinde .git bulunan yerlesim (<ad>.git/.git/config)
    local gd="$repo_path"
    [[ -f "$gd/config" ]] || { [[ -f "$gd/.git/config" ]] && gd="$gd/.git"; }
    [[ -f "$gd/config" ]] || continue
    found=1
    local is_bare
    is_bare="$(git_at "$gd" config --get core.bare 2>/dev/null || printf 'false')"
    if [[ "$is_bare" == "true" ]]; then
      info "Bare depo, çalışma dizini kurulmuyor: $(basename "$repo_path")"
      continue
    fi
    info "Çalışma dizini yeniden kuruluyor: $(basename "$repo_path")"
    (( DRYRUN )) && continue
    git_at "$gd" --work-tree="$DOCROOT_TGT" reset --hard HEAD >/dev/null 2>&1 \
      || warn "  git reset uyarı verdi"
    # 'git clean -fd' git'te izlenmeyen dosyaları SİLER (.env, yüklenen medya...).
    # Varsayılan olarak çalıştırılmaz; --git-clean ile açıkça istenmelidir.
    if (( ${GIT_CLEAN:-0} )); then
      warn "  git clean -fd çalıştırılıyor (izlenmeyen dosyalar silinecek)"
      git_at "$gd" --work-tree="$DOCROOT_TGT" clean -fd >/dev/null 2>&1 \
        || warn "  git clean uyarı verdi"
    else
      info "  izlenmeyen dosyalar korundu (silmek için --git-clean)"
    fi
  done
  (( found )) || info "Çalışma dizini kurulacak depo bulunamadı"
  return 0
}

# ===== lib/60-extras.sh =====
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

# ===== lib/70-native.sh =====
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

# ===== lib/80-wizard.sh =====
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

# ===== lib/90-run.sh =====
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

# ===== lib/95-selfupdate.sh =====
# ---------------------------------------------------------------------------
# 95-selfupdate.sh - kurulum bilgisi, guncelleme ve kaldirma
#
# pleskclone --update    : depodaki son surumu ceker, build eder, yerine koyar
# pleskclone --where     : kurulum dizini ve surum bilgisi
# pleskclone --uninstall : kurulumu kaldirir
# ---------------------------------------------------------------------------

PLESKCLONE_REPO="${PLESKCLONE_REPO:-ynsyildirim/PleskClone}"
PLESKCLONE_REF="${PLESKCLONE_REF:-main}"

# Kurulum kokunu bul: once launcher'in verdigi degisken, sonra script'in yeri
install_home() {
  if [[ -n "${PLESKCLONE_HOME:-}" && -d "$PLESKCLONE_HOME" ]]; then
    printf '%s' "$PLESKCLONE_HOME"
  else
    printf '%s' "$SELF_DIR"
  fi
}

# Bu dizin install.sh tarafından yönetilen bir kurulum mu?
#
# Kritik: install_home() kurulu değilken SELF_DIR'e düşer. Bu kontrol olmadan
# depo klasöründen çalıştırılan --uninstall, kullanıcının git checkout'unu
# (commit edilmemiş çalışması dahil) siler; --update ise üzerine yazar.
is_managed_install() { [[ -f "$(install_home)/.install-info" ]]; }

require_managed_install() {
  local what="$1" home; home="$(install_home)"
  is_managed_install && return 0
  err "'$what' yalnızca install.sh ile kurulmuş bir dizinde çalışır."
  err "Bu dizin yönetilen bir kurulum değil: $home"
  err "(.install-info bulunamadı — burası muhtemelen depo çalışma kopyanız.)"
  info "Kurmak için:  bash $home/install.sh"
  die "İşlem yapılmadı."
}

install_info_get() {
  local key="$1" f; f="$(install_home)/.install-info"
  [[ -f "$f" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}' "$f"
}

show_where() {
  local home; home="$(install_home)"
  bold "Plesk Clone kurulum bilgisi"
  printf '  Surum        : %s\n' "$PLESK_CLONE_VERSION"
  printf '  Kurulum yeri : %s\n' "$home"
  printf '  Giris betigi : %s\n' "$SELF_PATH"
  if [[ -f "$home/.install-info" ]]; then
    printf '  Depo         : %s\n' "$(install_info_get repo || printf '?')"
    printf '  Dal/etiket   : %s\n' "$(install_info_get ref || printf '?')"
    printf '  Kurulum tar. : %s\n' "$(install_info_get installed_at || printf '?')"
    printf '  Komut        : %s/pleskclone\n' "$(install_info_get bin || printf '?')"
  else
    printf '  Not          : install.sh ile kurulmamis (depo dizininden calisiyor)\n'
  fi
  printf '  Bundled      : %s\n' "$( [[ -n "${PLESK_CLONE_BUNDLED:-}" ]] && printf 'evet (tek dosya)' || printf 'hayir (lib/ ile)' )"
}

do_uninstall() {
  require_managed_install "--uninstall"
  local home; home="$(install_home)"
  local bin; bin="$(install_info_get bin 2>/dev/null || printf '/usr/local/bin')"
  warn "Kaldirilacak: $home ve $bin/pleskclone"
  confirm "Devam edilsin mi?" "h" || die "Iptal edildi."
  if [[ -f "$home/install.sh" ]]; then
    bash "$home/install.sh" --uninstall --dir "$home" --bin-dir "$bin"
  else
    rm -f "$bin/pleskclone"
    rm -rf "$home"
    ok "Kaldirildi."
  fi
}

do_update() {
  require_managed_install "--update"
  local home; home="$(install_home)"
  local bin;  bin="$(install_info_get bin 2>/dev/null || printf '')"
  [[ -z "$bin" ]] && bin="$(dirname "$(command -v pleskclone 2>/dev/null || printf '/usr/local/bin/pleskclone')")"
  local repo ref
  repo="$(install_info_get repo 2>/dev/null || printf '%s' "$PLESKCLONE_REPO")"
  ref="${PLESKCLONE_REF_OVERRIDE:-$(install_info_get ref 2>/dev/null || printf '%s' "$PLESKCLONE_REF")}"

  bold "Plesk Clone guncelleme"
  info "Mevcut surum : $PLESK_CLONE_VERSION"
  info "Depo         : ${repo}@${ref}"
  info "Kurulum yeri : $home"

  [[ -w "$home" || "$(id -u)" == "0" ]] \
    || die "Kurulum dizinine yazma izni yok: $home (root olarak calistirin)"

  # Kurulum betigi elimizde varsa onu kullan; yoksa depodan cek
  if [[ -f "$home/install.sh" ]]; then
    info "install.sh calistiriliyor..."
    bash "$home/install.sh" --dir "$home" --bin-dir "$bin" --repo "$repo" --ref "$ref" \
      || die "Guncelleme basarisiz."
  else
    local url="https://raw.githubusercontent.com/${repo}/${ref}/install.sh"
    info "Kurulum betigi indiriliyor: $url"
    if has_cmd curl; then
      curl -fsSL "$url" | bash -s -- --dir "$home" --bin-dir "$bin" --repo "$repo" --ref "$ref" \
        || die "Guncelleme basarisiz."
    elif has_cmd wget; then
      wget -qO- "$url" | bash -s -- --dir "$home" --bin-dir "$bin" --repo "$repo" --ref "$ref" \
        || die "Guncelleme basarisiz."
    else
      die "curl veya wget gerekli."
    fi
  fi

  local newver
  newver="$(awk -F'\"' '/^PLESK_CLONE_VERSION=/{print $2; exit}' "$home/plesk_clone.sh" 2>/dev/null || true)"
  if [[ -n "$newver" && "$newver" != "$PLESK_CLONE_VERSION" ]]; then
    ok "Guncellendi: $PLESK_CLONE_VERSION -> $newver"
  else
    ok "Zaten guncel (surum $PLESK_CLONE_VERSION)."
  fi
}

# ---- varsayılanlar ----
SOURCE=""
TARGET=""
OWNER=""
SERVICE_PLAN=""
TARGET_IP=""
SYS_USER=""
SYS_PASS=""
SYS_USER_SRC=""
IP_SRC=""
VHOST_SRC=""
VHOST_TGT=""
DOCROOT_SRC=""
DOCROOT_TGT=""
SSL_EMAIL=""
MOVE_MODE=0
FIX_GIT_ONLY=0
GIT_CLEAN=0
ACTION="clone"
PLESKCLONE_REF_OVERRIDE=""

usage() {
  cat <<EOF
Plesk Clone / Migrate v${PLESK_CLONE_VERSION}

KULLANIM
  $0 -s KAYNAK [-t HEDEF] [-o SAHİP] [seçenekler]

TEMEL
  -s, --source DOMAIN      Kaynak domain (zorunlu)
  -t, --target DOMAIN      Hedef domain (varsayılan: --move ile kaynağın aynısı)
  -o, --owner  LOGIN       Hedef domain sahibi (varsayılan: kaynağın sahibi)
      --move               Başka sunucuya BİREBİR taşıma kısayolu:
                           hedef = kaynak, DB bilgileri korunur, tüm bileşenler açılır
  -h, --help               Bu yardım
      --version            Sürüm

HEDEF SUNUCU (boş bırakılırsa aynı sunucuda klonlanır)
      --to-host HOST       Hedef sunucu IP/hostname (SSH)
      --ssh-user USER      SSH kullanıcısı (varsayılan: root)
      --ssh-port PORT      SSH portu (varsayılan: 22)
      --ssh-key FILE       SSH özel anahtarı

VERİTABANI  (asıl soru: bilgiler değişsin mi?)
      --keep-db            Ad + kullanıcı + parola BİREBİR korunur
                           (config dosyalarına dokunulmaz; sadece farklı sunucuda)
      --new-db             Ad + kullanıcı + parola yeniden üretilir (aynı sunucuda klon)
      --db-mode MOD        keep | suffix | prefix | map     (ad politikası)
      --db-suffix STR      suffix modunda kullanılacak sonek
      --db-prefix STR      prefix modunda kullanılacak önek
      --db-map  "a=b,c=d"  map modunda eski=yeni eşlemeleri
      --db-user-mode MOD   keep | new | map
      --db-user-map "a=b"  kullanıcı eşlemeleri
      --db-pass-mode MOD   keep | new | map
      --db-pass-map "u=p"  parola eşlemeleri
      --db-overwrite       Hedefte aynı adlı DB varsa üzerine yaz
      --no-db              Veritabanlarını hiç kopyalama

DOSYALAR
      --full-vhost         Tüm vhost dizinini kopyala (private, cgi-bin, .ssh ...)
      --docroot-only       Sadece document root (varsayılan)
      --no-delete          rsync --delete kullanma (hedefteki fazlalıkları silme)
      --no-config-rewrite  .env / wp-config.php gibi dosyalarda otomatik güncelleme yapma

BİLEŞENLER
      --full               Tüm bileşenleri aç (dns, mail, sertifika, alias, ftp, git ...)
      --only  a,b,c        Sadece bu bileşenleri çalıştır
      --skip  a,b,c        Bu bileşenleri atla
      --copy-git           Git depoları + Plesk Git Extension ayarları
      --git-worktree       Bare olmayan depolarda çalışma dizinini yeniden kur
                           (hedef docroot'ta 'git reset --hard' çalıştırır)
      --git-clean          --git-worktree + 'git clean -fd'
                           DİKKAT: git'te izlenmeyen dosyaları SİLER (.env dahil)
      --fix-git            Sadece Git entegrasyonunu onar (domain zaten varsa)
      --ssl                Let's Encrypt sertifikası al
      --ssl-email MAIL     Let's Encrypt e-posta adresi
  Bileşenler: $ALL_COMPONENTS

HEDEF DOMAIN AYARLARI
      --plan NAME          Servis planı (varsayılan: kaynağınki)
      --ip IP              Hedef IP adresi
      --sys-user LOGIN     Hedef sistem kullanıcısı (varsayılan: taşımada kaynakla aynı)
      --sys-pass PASS      Hedef sistem kullanıcı parolası

MOTOR
      --engine granular    Ayrıntılı klonlama (varsayılan) — yeniden adlandırma yapabilir
      --engine native      plesk pleskbackup/pleskrestore ile birebir taşıma
                           (sadece aynı isimle, farklı sunucuya)
      --keep-backup        native motorda yedek dosyalarını silme

KURULUM
      --update             Depodaki son sürüme güncelle (build otomatik)
      --ref REF            Güncellemede kullanılacak dal/etiket
      --where              Kurulum dizini ve sürüm bilgisi
      --uninstall          Kurulumu kaldır
  Kurulum tek satırla:
      curl -fsSL https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/install.sh | bash

GENEL
  -y, --yes                Tüm onayları otomatik ver
      --non-interactive    Hiç soru sorma (varsayılanlarla devam et)
  -v, --verbose            Ayrıntılı çıktı
      --dry-run            Hiçbir değişiklik yapma, sadece ne yapılacağını göster
      --log-dir DIR        Log/kimlik bilgisi dizini (varsayılan: ./logs)

ÖRNEKLER
  # Aynı sunucuda staging klonu (DB adı/kullanıcı/parola yenilenir)
  $0 -s example.com -t staging.example.com --new-db --copy-git --ssl

  # Aynı sunucuda klon, ama DB kullanıcı/parolası aynı kalsın (sadece ad değişsin)
  $0 -s example.com -t staging.example.com --db-mode suffix --db-user-mode keep --db-pass-mode keep

  # Başka sunucuya BİREBİR taşıma — hiçbir bilgi değişmez
  $0 -s example.com --move --to-host 203.0.113.10

  # Başka sunucuya farklı isimle taşıma, DB bilgileri korunarak
  $0 -s example.com -t yeni.com --to-host 203.0.113.10 --keep-db --full

  # Plesk'in kendi yedek motoruyla birebir taşıma
  $0 -s example.com --move --to-host 203.0.113.10 --engine native

  # Ne olacağını gör
  $0 -s example.com -t test.example.com --dry-run
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -s|--source)   SOURCE="${2:-}"; shift 2 ;;
      -t|--target)   TARGET="${2:-}"; shift 2 ;;
      -o|--owner)    OWNER="${2:-}";  shift 2 ;;
      --move)        MOVE_MODE=1; shift ;;

      --to-host)     REMOTE_HOST="${2:-}"; TRANSPORT="remote"; TRANSPORT_SET=1; shift 2 ;;
      --ssh-user)    REMOTE_USER="${2:-}"; shift 2 ;;
      --ssh-port)    REMOTE_PORT="${2:-}"; shift 2 ;;
      --ssh-key)     REMOTE_KEY="${2:-}";  shift 2 ;;

      --keep-db)     DB_MODE="keep";   DB_USER_MODE="keep"; DB_PASS_MODE="keep"; DB_POLICY_SET=1; shift ;;
      --new-db)      DB_MODE="suffix"; DB_USER_MODE="new";  DB_PASS_MODE="new";  DB_POLICY_SET=1; shift ;;
      --db-mode)     DB_MODE="${2:-}";      DB_POLICY_SET=1; shift 2 ;;
      --db-suffix)   DB_SUFFIX="${2:-}";    DB_MODE="suffix"; DB_POLICY_SET=1; shift 2 ;;
      --db-prefix)   DB_PREFIX="${2:-}";    DB_MODE="prefix"; DB_POLICY_SET=1; shift 2 ;;
      --db-map)      DB_MAP="${2:-}";       DB_MODE="map";    DB_POLICY_SET=1; shift 2 ;;
      --db-user-mode) DB_USER_MODE="${2:-}"; DB_POLICY_SET=1; shift 2 ;;
      --db-user-map)  DB_USER_MAP="${2:-}"; DB_USER_MODE="map"; DB_POLICY_SET=1; shift 2 ;;
      --db-pass-mode) DB_PASS_MODE="${2:-}"; DB_POLICY_SET=1; shift 2 ;;
      --db-pass-map)  DB_PASS_MAP="${2:-}"; DB_PASS_MODE="map"; DB_POLICY_SET=1; shift 2 ;;
      --db-overwrite) DB_OVERWRITE=1; shift ;;
      --no-db)        COMPONENTS_SKIP="${COMPONENTS_SKIP},db"; DB_POLICY_SET=1; shift ;;

      --full-vhost)  FULL_VHOST=1; shift ;;
      --docroot-only) FULL_VHOST=0; shift ;;
      --no-delete)   RSYNC_DELETE=0; shift ;;
      --no-config-rewrite) CONFIG_REWRITE=0; shift ;;

      --full)        COMPONENTS_ON="$(all_components_csv)"; shift ;;
      --only)        COMPONENTS_ON="${2:-}"; ONLY_MODE=1; shift 2 ;;
      --skip)        COMPONENTS_SKIP="${COMPONENTS_SKIP},${2:-}"; shift 2 ;;
      --copy-git)    comp_add "git"; shift ;;
      --git-worktree) comp_add "worktree"; shift ;;
      --git-clean)   comp_add "worktree"; GIT_CLEAN=1; shift ;;
      --fix-git)     FIX_GIT_ONLY=1; comp_add "git"; shift ;;
      --ssl)         comp_add "ssl"; shift ;;
      --ssl-email)   SSL_EMAIL="${2:-}"; shift 2 ;;

      --plan)        SERVICE_PLAN="${2:-}"; shift 2 ;;
      --ip)          TARGET_IP="${2:-}"; shift 2 ;;
      --sys-user)    SYS_USER="${2:-}"; shift 2 ;;
      --sys-pass)    SYS_PASS="${2:-}"; shift 2 ;;

      --engine)      ENGINE="${2:-granular}"; shift 2 ;;
      --keep-backup) NATIVE_KEEP_BACKUP=1; shift ;;

      -y|--yes)      ASSUME_YES=1; shift ;;
      --non-interactive) INTERACTIVE=0; ASSUME_YES=1; shift ;;
      -v|--verbose)  VERBOSE=1; shift ;;
      --dry-run)     DRYRUN=1; shift ;;
      --log-dir)     LOG_DIR="${2:-}"; shift 2 ;;

      --update)      ACTION="update"; shift ;;
      --uninstall)   ACTION="uninstall"; shift ;;
      --where)       ACTION="where"; shift ;;
      --ref)         PLESKCLONE_REF_OVERRIDE="${2:-}"; shift 2 ;;

      --version)     printf 'plesk-clone %s\n' "$PLESK_CLONE_VERSION"; exit 0 ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "Bilinmeyen argüman: $1" ;;
    esac
  done

  # Sorular /dev/tty üzerinden sorulur; kontrol terminali yoksa etkileşimi kapat.
  # (stdin'in boru olması sorun değil — `curl ... | bash` kullanımı çalışmaya devam eder.)
  { [[ -t 0 ]] || { : </dev/tty; } 2>/dev/null; } || INTERACTIVE=0

  # --move: birebir taşıma kısayolu
  if (( MOVE_MODE )); then
    [[ -z "$TARGET" ]] && TARGET="$SOURCE"
    if (( ! DB_POLICY_SET )); then
      DB_MODE="keep"; DB_USER_MODE="keep"; DB_PASS_MODE="keep"; DB_POLICY_SET=1
    fi
    (( ONLY_MODE )) || COMPONENTS_ON="$(all_components_csv),${COMPONENTS_ON}"
    FULL_VHOST=1
  fi

  [[ -z "$TARGET" ]] && TARGET="$SOURCE"
  return 0
}

main() {
  # ---- agent modu: hedef sunucuda tek bir işlem çalıştır ----
  if [[ "${1:-}" == "--agent" ]]; then
    shift
    [[ $# -ge 1 ]] || { err "--agent için işlem adı gerekli"; exit 64; }
    agent_dispatch "$@"
    exit $?
  fi

  parse_args "$@"

  # ---- kurulum yonetimi (klonlamadan bagimsiz) ----
  case "$ACTION" in
    update)    do_update;    exit 0 ;;
    uninstall) do_uninstall; exit 0 ;;
    where)     show_where;   exit 0 ;;
  esac

  [[ -z "$SOURCE" ]] && { usage >&2; die "Kaynak domain (-s) zorunlu."; }

  init_logdir
  LOG_FILE="$LOG_DIR/${TARGET}_clone_$(date +%Y%m%d_%H%M%S).log"
  : >"$LOG_FILE"; chmod 600 "$LOG_FILE" 2>/dev/null || true

  bold "Plesk Clone v${PLESK_CLONE_VERSION} — $SOURCE -> $TARGET"
  info "Oturum logu: $LOG_FILE"

  install_cleanup_hook

  if (( FIX_GIT_ONLY )); then
    do_fix_git
  else
    do_clone
  fi
}

main "$@"
