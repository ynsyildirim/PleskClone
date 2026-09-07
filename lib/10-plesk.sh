#!/usr/bin/env bash
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
