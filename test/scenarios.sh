#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Senaryo paketi - plesk-a (kaynak sunucu) uzerinde calisir.
#
# Her senaryo icin:
#   - kendi log dosyasi   /opt/testlogs/NN-<ad>.log
#   - dogrulamalar        (check ...)
#   - ozet                /opt/testlogs/SUMMARY.txt
#
# En kritik dogrulama: hedefteki health.php GERCEKTEN veritabanina baglaniyor mu.
# Bu tek kontrol, DB adi/kullanici/parola politikasi + config yeniden yazimi
# zincirinin tamaminin dogru calistigini kanitlar.
# ---------------------------------------------------------------------------
set -uo pipefail

SRC_DOMAIN="${SEED_DOMAIN:-demo.test}"
REMOTE_IP=172.28.0.11
LOGDIR=/opt/testlogs
WORKDIR=/root/pleskclone-test
PC=pleskclone

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR"

# ---------------------------------------------------------------------------
# Cerceve
# ---------------------------------------------------------------------------
TOTAL=0; PASSED=0; FAILED=0
CUR_ID=""; CUR_NAME=""; CUR_LOG=""; CUR_FAILS=0; CUR_CHECKS=0
declare -a RESULTS=()

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'

log()  { printf '%s\n' "$*" | tee -a "$CUR_LOG"; }
logq() { printf '%s\n' "$*" >>"$CUR_LOG"; }

scenario() {
  CUR_ID="$1"; CUR_NAME="$2"
  CUR_LOG="$LOGDIR/${CUR_ID}-${CUR_NAME}.log"
  CUR_FAILS=0; CUR_CHECKS=0
  : >"$CUR_LOG"
  printf '\n%s########## [%s] %s ##########%s\n' "$C_B" "$CUR_ID" "$CUR_NAME" "$C_0"
  printf '########## [%s] %s ##########\n' "$CUR_ID" "$CUR_NAME" >>"$CUR_LOG"
  printf 'Baslangic: %s\n' "$(date '+%F %T')" >>"$CUR_LOG"
}

# check "aciklama" komut...
check() {
  local desc="$1"; shift
  CUR_CHECKS=$((CUR_CHECKS+1)); TOTAL=$((TOTAL+1))
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    PASSED=$((PASSED+1))
    printf '  %s[GECTI]%s %s\n' "$C_G" "$C_0" "$desc"
    { printf '  [GECTI] %s\n' "$desc"; [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/          /'; } >>"$CUR_LOG"
  else
    FAILED=$((FAILED+1)); CUR_FAILS=$((CUR_FAILS+1))
    printf '  %s[KALDI]%s %s\n' "$C_R" "$C_0" "$desc"
    printf '%s\n' "$out" | sed 's/^/          /'
    { printf '  [KALDI] %s (rc=%s)\n' "$desc" "$rc"; printf '%s\n' "$out" | sed 's/^/          /'; } >>"$CUR_LOG"
  fi
}

scenario_end() {
  local status
  if (( CUR_FAILS == 0 )); then status="GECTI"; else status="KALDI ($CUR_FAILS/$CUR_CHECKS)"; fi
  RESULTS+=("$(printf '%-4s %-34s %-16s %s' "$CUR_ID" "$CUR_NAME" "$status" "${CUR_LOG#$LOGDIR/}")")
  printf 'Sonuc: %s\nBitis: %s\n' "$status" "$(date '+%F %T')" >>"$CUR_LOG"
  printf '%s---> %s%s\n' "$( ((CUR_FAILS==0)) && printf '%s' "$C_G" || printf '%s' "$C_R" )" "$status" "$C_0"
}

# ---------------------------------------------------------------------------
# Yardimcilar
# ---------------------------------------------------------------------------
psa()   { plesk db -Ne "$1" 2>/dev/null; }
SSH()   { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 root@$REMOTE_IP "$@"; }
SSHQ()  { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 "root@$REMOTE_IP" "$@"; }
psa_b() { SSH "plesk db -Ne \"$1\"" 2>/dev/null; }
# check ... bash -c "..." icinden de kullanilabilsin diye disari aktar
export REMOTE_IP
export -f SSHQ psa

adminpass() { cat /etc/psa/.psa.shadow; }
sql_local() { MYSQL_PWD="$(adminpass)" mysql -uadmin -N -B -e "$1" ${2:+"$2"} 2>/dev/null; }
sql_remote(){ SSH "MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"$1\" ${2:-}" 2>/dev/null; }

docroot_of()      { local d; d="$(psa "SELECT h.www_root FROM hosting h JOIN domains dm ON dm.id=h.dom_id WHERE dm.name='$1' LIMIT 1;")"; [[ "$d" == /* ]] || d="/var/www/vhosts/$1/${d:-httpdocs}"; printf '%s' "$d"; }
docroot_of_b()    { local d; d="$(psa_b "SELECT h.www_root FROM hosting h JOIN domains dm ON dm.id=h.dom_id WHERE dm.name='$1' LIMIT 1;")"; d="$(printf '%s' "$d" | tr -d '\r')"; [[ "$d" == /* ]] || d="/var/www/vhosts/$1/${d:-httpdocs}"; printf '%s' "$d"; }

cleanup_local() {
  local d="$1"
  plesk bin domain --remove "$d" >/dev/null 2>&1
  rm -rf "/var/www/vhosts/$d"
  # artik kalan veritabanlarini temizle
  local db
  for db in $(sql_local "SHOW DATABASES" | grep -E "_$(printf '%s' "$d" | tr '.-' '__')$|^(s2|b2)$" || true); do
    sql_local "DROP DATABASE IF EXISTS \`$db\`"
  done
  return 0
}
cleanup_remote() {
  local d="$1"
  SSH "plesk bin domain --remove '$d' >/dev/null 2>&1; rm -rf '/var/www/vhosts/$d'" >/dev/null 2>&1
  return 0
}

# ---- dogrulama yardimcilari ----
assert_domain_local()  { plesk bin domain --info "$1" >/dev/null 2>&1; }
assert_domain_remote() { SSH "plesk bin domain --info '$1' >/dev/null 2>&1"; }

assert_file_local()  { [[ -f "$1" ]] || { echo "yok: $1"; return 1; }; }
assert_file_remote() { SSH "test -f '$1'" || { echo "hedefte yok: $1"; return 1; }; }

# health.php'yi calistir: DB'ye gercekten baglanmali
health_local() {
  local dr="$1" out
  out="$(php "$dr/health.php" 2>&1)"; local rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || return 1
  printf '%s' "$out" | grep -q '^OK ana' || return 1
  return 0
}
health_remote() {
  local dr="$1" out
  out="$(SSH "php '$dr/health.php'" 2>&1)"; local rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || return 1
  printf '%s' "$out" | grep -q '^OK ana' || return 1
  return 0
}

# .env icindeki bir anahtarin degeri
envval_local()  { sed -n "s/^$2=//p" "$1/.env" 2>/dev/null | head -1; }
envval_remote() { SSH "sed -n 's/^$2=//p' '$1/.env' 2>/dev/null | head -1" | tr -d '\r'; }

rowcount_local()  { sql_local "SELECT COUNT(*) FROM items" "$1" | tr -d '[:space:]'; }
rowcount_remote() { sql_remote "SELECT COUNT(*) FROM items" "$1" | tr -d '[:space:]'; }
export -f adminpass sql_local rowcount_local

# ---------------------------------------------------------------------------
# Kaynak durumunu bir kez oku (karsilastirmalar icin)
# ---------------------------------------------------------------------------
SRC_DOCROOT="$(docroot_of "$SRC_DOMAIN")"
SRC_SYSUSER="$(psa "SELECT su.login FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$SRC_DOMAIN' LIMIT 1;")"
SRC_PHPH="$(psa "SELECT ph.id FROM domains d JOIN hosting h ON h.dom_id=d.id JOIN php_settings ps ON ps.id=h.php_settings_id JOIN php_handlers ph ON ph.id=ps.handler_id WHERE d.name='$SRC_DOMAIN' LIMIT 1;")"
SRC_SHELL="$(psa "SELECT su.shell FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$SRC_DOMAIN' LIMIT 1;")"
SRC_DBS="$(psa "SELECT d.name FROM data_bases d JOIN domains dm ON dm.id=d.dom_id WHERE dm.name='$SRC_DOMAIN';" | tr '\n' ' ')"
SRC_ROWS1="$(rowcount_local shopdb)"
SRC_CRON="$(crontab -l -u "$SRC_SYSUSER" 2>/dev/null | grep -c '^[^#]')"

printf '%s================ KAYNAK DURUMU ================%s\n' "$C_B" "$C_0"
printf '  domain=%s sysuser=%s php=%s shell=%s\n' "$SRC_DOMAIN" "$SRC_SYSUSER" "$SRC_PHPH" "$SRC_SHELL"
printf '  docroot=%s\n  dbs=%s (shopdb %s satir)  cron=%s\n' "$SRC_DOCROOT" "$SRC_DBS" "$SRC_ROWS1" "$SRC_CRON"
printf '%s==============================================%s\n' "$C_B" "$C_0"

# ===========================================================================
# S01 - Ayni sunucuda klon, DB bilgileri tamamen yenilenir
# ===========================================================================
T=stg1.demo.test
scenario S01 "yerel-klon-yeni-db"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --new-db --copy-git --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti (rc=$RC)"            test "$RC" -eq 0
check "hedef domain olustu"                        assert_domain_local "$T"
TD="$(docroot_of "$T")"
check "index.php kopyalandi"                       assert_file_local "$TD/index.php"
check ".env kopyalandi"                            assert_file_local "$TD/.env"
check "APP_URL hedef domaine cevrildi"             bash -c "[[ \"\$(sed -n 's/^APP_URL=//p' '$TD/.env')\" == 'https://$T' ]]"
check "DB adi degisti (shopdb degil)"              bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$TD/.env')\" != 'shopdb' ]]"
check "DB kullanicisi degisti"                     bash -c "[[ \"\$(sed -n 's/^DB_USERNAME=//p' '$TD/.env')\" != 'shopuser' ]]"
check "HEDEF UYGULAMA DB'YE BAGLANIYOR"            health_local "$TD"
NEWDB="$(envval_local "$TD" DB_DATABASE)"
check "veri satir sayisi korundu ($SRC_ROWS1)"     bash -c "[[ \"\$(MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e 'SELECT COUNT(*) FROM items' '$NEWDB' | tr -d '[:space:]')\" == '$SRC_ROWS1' ]]"
check "view ve procedure tasindi"                  bash -c "MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"SELECT COUNT(*) FROM information_schema.views WHERE table_schema='$NEWDB'\" | grep -q 1"
TSYS="$(psa "SELECT su.login FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$T' LIMIT 1;")"
check "cron gorevleri tasindi ($SRC_CRON adet)"    bash -c "[[ \"\$(crontab -l -u '$TSYS' 2>/dev/null | grep -c '^[^#]')\" == '$SRC_CRON' ]]"
check "cron icinde hedef domain yazili"            bash -c "crontab -l -u '$TSYS' 2>/dev/null | grep -q '$T'"
check "PHP handler eslesti"                        bash -c "[[ \"\$(plesk db -Ne \"SELECT ph.id FROM domains d JOIN hosting h ON h.dom_id=d.id JOIN php_settings ps ON ps.id=h.php_settings_id JOIN php_handlers ph ON ph.id=ps.handler_id WHERE d.name='$T' LIMIT 1;\")\" == '$SRC_PHPH' ]]"
check "SSH shell eslesti"                          bash -c "[[ \"\$(plesk db -Ne \"SELECT su.shell FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$T' LIMIT 1;\")\" == '$SRC_SHELL' ]]"
check "composer dizini kopyalandi"                 test -f "/var/www/vhosts/$T/.composer/composer.json"
check "composer cache haric tutuldu"               bash -c "[[ ! -e '/var/www/vhosts/$T/.composer/cache/files/dummy.bin' ]]"
check "git bare deposu kopyalandi"                 test -d "/var/www/vhosts/$T/git/app.git"
check "git deposu okunabiliyor"                    bash -c "git --git-dir='/var/www/vhosts/$T/git/app.git' log --oneline | grep -q 'ilk surum'"
check "git sanal klasoru (symlink) olustu"         test -L "/var/www/vhosts/$T/git/app"
TDOMID="$(psa "SELECT id FROM domains WHERE name='$T' LIMIT 1;")"
check "Git Extension kaydi hedefe eklendi"         bash -c "[[ \"\$(sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT COUNT(*) FROM Repositories WHERE domainId=$TDOMID\")\" == '1' ]]"
check "deployment path hedefe cevrildi"            bash -c "sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT deploymentPath FROM Repositories WHERE domainId=$TDOMID\" | grep -q '$T'"
check "deploy script (post-action) hedefe cevrildi" bash -c "sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT postDeploymentActions FROM Repositories WHERE domainId=$TDOMID\" | grep -q '$T'"
check "deploy key uretildi"                        bash -c "DK=\$(sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT deployKeyUuid FROM Repositories WHERE domainId=$TDOMID\"); test -f \"/usr/local/psa/var/modules/git/keys/\$DK\""
check "DeployKeys kaydi eklendi"                   bash -c "[[ \"\$(sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT COUNT(*) FROM DeployKeys WHERE name='app'\")\" -ge 1 ]]"
check "deploy.sh hedefte var"                      assert_file_local "$TD/deploy.sh"
check "deploy.sh icindeki domain cevrildi"         bash -c "grep -q 'DOMAIN_NAME=\"$T\"' '$TD/deploy.sh'"
check "DEPLOY SCRIPT HEDEFTE CALISIYOR"            bash -c "bash '$TD/deploy.sh'"
check "sqlite'daki post-deployment komutu calisiyor" bash -c "CMD=\$(sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT postDeploymentActions FROM Repositories WHERE domainId=$TDOMID\"); bash -c \"\$CMD\""
check "kaynak .env DEGISMEDI"                      bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$SRC_DOCROOT/.env')\" == 'shopdb' ]]"
check "config yedegi alindi"                       bash -c "ls -d /var/www/vhosts/$T/.plesk-clone-backup/*/ >/dev/null 2>&1"
check "wp-config.php de guncellendi"               bash -c "grep -q \"define( 'DB_NAME', '$NEWDB' )\" '$TD/wp-config.php'"
scenario_end

# ===========================================================================
# S02 - Ayni sunucuda: kullanici/parola korunmak istenirse otomatik dusurulmeli
# ===========================================================================
T=stg2.demo.test
scenario S02 "yerel-keep-guvenlik-dusurmesi"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --keep-db --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                      test "$RC" -eq 0
check "ayni sunucuda ad korunamaz uyarisi verildi" grep -q "veritabani adi korunamaz\|veritabanı adı korunamaz" "$CUR_LOG"
check "kullanici korunamaz uyarisi verildi"        grep -q "kullanici adi korunamaz\|kullanıcı adı korunamaz" "$CUR_LOG"
TD="$(docroot_of "$T")"
check "DB adi sonek aldi"                          bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$TD/.env')\" == shopdb_* ]]"
check "HEDEF UYGULAMA DB'YE BAGLANIYOR"            health_local "$TD"
scenario_end

# ===========================================================================
# S03 - Onek politikasi
# ===========================================================================
T=stg3.demo.test
scenario S03 "yerel-db-onek"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --db-prefix yeni --db-user-mode new --db-pass-mode new --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                      test "$RC" -eq 0
TD="$(docroot_of "$T")"
check "DB adi onek aldi (yeni_shopdb)"             bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$TD/.env')\" == 'yeni_shopdb' ]]"
check "HEDEF UYGULAMA DB'YE BAGLANIYOR"            health_local "$TD"
scenario_end

# ===========================================================================
# S04 - Elle eslemeli DB adlari
# ===========================================================================
T=stg4.demo.test
scenario S04 "yerel-db-elle-esleme"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --db-map "shopdb=s2db,blogdb=b2db" --db-user-mode new --db-pass-mode new --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                      test "$RC" -eq 0
TD="$(docroot_of "$T")"
check "ana DB adi s2db oldu"                       bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$TD/.env')\" == 's2db' ]]"
check "blog DB adi b2db oldu"                      bash -c "[[ \"\$(sed -n 's/^BLOG_DB_DATABASE=//p' '$TD/.env')\" == 'b2db' ]]"
check "HEDEF UYGULAMA IKI DB'YE DE BAGLANIYOR"     bash -c "php '$TD/health.php' | grep -c '^OK' | grep -q 2"
scenario_end

# ===========================================================================
# S05 - Sadece belirli bilesenler
# ===========================================================================
T=stg5.demo.test
scenario S05 "yerel-only-ve-skip"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --only domain,files,perms --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                      test "$RC" -eq 0
check "dosyalar kopyalandi"                        assert_file_local "$(docroot_of "$T")/index.php"
check "veritabani OLUSTURULMADI"                   bash -c "[[ -z \"\$(plesk db -Ne \"SELECT d.name FROM data_bases d JOIN domains dm ON dm.id=d.dom_id WHERE dm.name='$T';\")\" ]]"
check "cron KOPYALANMADI"                          bash -c "TS=\$(plesk db -Ne \"SELECT su.login FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$T' LIMIT 1;\"); [[ \"\$(crontab -l -u \$TS 2>/dev/null | grep -c '^[^#]')\" == '0' ]]"
scenario_end

# ===========================================================================
# S06 - DB kopyalanmadiginda config'e dokunulmamali
# ===========================================================================
T=stg6.demo.test
scenario S06 "yerel-no-db-config-korunur"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --no-db --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
TD="$(docroot_of "$T")"
check "komut basariyla bitti"                      test "$RC" -eq 0
check "DB adi kaynaktaki gibi kaldi"               bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$TD/.env')\" == 'shopdb' ]]"
check "sadece domain adi cevrildi"                 bash -c "[[ \"\$(sed -n 's/^APP_URL=//p' '$TD/.env')\" == 'https://$T' ]]"
scenario_end

# ===========================================================================
# S07 - dry-run hicbir sey degistirmemeli
# ===========================================================================
T=stg7.demo.test
scenario S07 "dry-run-degisiklik-yok"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --new-db --copy-git --dry-run --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                      test "$RC" -eq 0
check "hedef domain OLUSTURULMADI"                 bash -c "! plesk bin domain --info '$T' >/dev/null 2>&1"
check "hedef dizin OLUSTURULMADI"                  bash -c "[[ ! -d '/var/www/vhosts/$T/httpdocs' ]]"
check "yeni veritabani OLUSTURULMADI"              bash -c "! (MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e 'SHOW DATABASES' | grep -q 'stg7')"
scenario_end

# ===========================================================================
# S08 - --fix-git ile mevcut hedefte git onarimi
# ===========================================================================
T=stg1.demo.test
scenario S08 "fix-git-onarim"
TDOMID="$(psa "SELECT id FROM domains WHERE name='$T' LIMIT 1;")"
if [[ -n "$TDOMID" ]]; then
  sqlite3 /usr/local/psa/var/modules/git/git_db.db "DELETE FROM Repositories WHERE domainId=$TDOMID;"
  rm -f "/var/www/vhosts/$T/git/app"
  check "on kosul: kayit silindi"                  bash -c "[[ \"\$(sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT COUNT(*) FROM Repositories WHERE domainId=$TDOMID\")\" == '0' ]]"
  $PC -s "$SRC_DOMAIN" -t "$T" --fix-git --non-interactive -y >>"$CUR_LOG" 2>&1
  RC=$?
  check "komut basariyla bitti"                    test "$RC" -eq 0
  check "Git Extension kaydi geri geldi"           bash -c "[[ \"\$(sqlite3 /usr/local/psa/var/modules/git/git_db.db \"SELECT COUNT(*) FROM Repositories WHERE domainId=$TDOMID\")\" == '1' ]]"
  check "sanal klasor yeniden olustu"              test -L "/var/www/vhosts/$T/git/app"
else
  check "on kosul: S01 hedefi mevcut olmali"       false
fi
scenario_end

# ===========================================================================
# S09 - Guvenlik: ayni sunucuda ayni isim reddedilmeli
# ===========================================================================
scenario S09 "guvenlik-ayni-isim-ayni-sunucu"
OUT="$($PC -s "$SRC_DOMAIN" --move --non-interactive -y 2>&1)"; RC=$?
printf '%s\n' "$OUT" >>"$CUR_LOG"
check "komut hata ile durdu"                       test "$RC" -ne 0
check "anlasilir hata mesaji verildi"              bash -c "printf '%s' \"\$0\" | grep -q 'ayni sunucuda mumkun degil\|aynı sunucuda mümkün değil'" "$OUT"
check "hicbir domain olusmadi"                     bash -c "[[ \"\$(plesk db -Ne \"SELECT COUNT(*) FROM domains WHERE name='$SRC_DOMAIN'\")\" == '1' ]]"
scenario_end

# ===========================================================================
# S10 - UZAK SUNUCU: farkli isim, DB bilgileri BIREBIR korunur
# ===========================================================================
T=yeni.test
scenario S10 "uzak-farkli-isim-db-korunur"
cleanup_remote "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --full --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti (rc=$RC)"             test "$RC" -eq 0
check "hedef sunucuda domain olustu"               assert_domain_remote "$T"
BD="$(docroot_of_b "$T")"
logq "hedef docroot: $BD"
check "dosyalar hedef sunucuya gecti"              assert_file_remote "$BD/index.php"
check "DB adi BIREBIR ayni (shopdb)"               bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^DB_DATABASE=//p' '$BD/.env'\" | tr -d '\r')\" == 'shopdb' ]]"
check "DB kullanicisi BIREBIR ayni (shopuser)"     bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^DB_USERNAME=//p' '$BD/.env'\" | tr -d '\r')\" == 'shopuser' ]]"
check "DB parolasi BIREBIR ayni"                   bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^DB_PASSWORD=//p' '$BD/.env'\" | tr -d '\r')\" == 'ShopPass#2026a' ]]"
check "HEDEF SUNUCUDA UYGULAMA DB'YE BAGLANIYOR"   health_remote "$BD"
check "veri satir sayisi korundu"                  bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP 'MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"SELECT COUNT(*) FROM items\" shopdb' | tr -d '[:space:]')\" == '$SRC_ROWS1' ]]"
check "APP_URL hedef domaine cevrildi"             bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^APP_URL=//p' '$BD/.env'\" | tr -d '\r')\" == 'https://$T' ]]"
check "git deposu hedef sunucuda"                  bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"git --git-dir='/var/www/vhosts/$T/git/app.git' log --oneline\" | grep -q 'ilk surum'"
check "Git Extension kaydi hedef sunucuda"         bash -c "BID=\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT id FROM domains WHERE name='$T' LIMIT 1\\\"\" | tr -d '[:space:]'); [[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sqlite3 /usr/local/psa/var/modules/git/git_db.db \\\"SELECT COUNT(*) FROM Repositories WHERE domainId=\$BID\\\"\" | tr -d '[:space:]')\" == '1' ]]"
check "DEPLOY SCRIPT HEDEF SUNUCUDA CALISIYOR"     bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"bash '$BD/deploy.sh'\""
check "cron hedef sunucuya gecti"                  bash -c "TS=\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT su.login FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$T' LIMIT 1\\\"\" | tr -d '[:space:]\r'); [[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"crontab -l -u \$TS 2>/dev/null | grep -c '^[^#]'\" | tr -d '[:space:]')\" == '$SRC_CRON' ]]"
check "mail hesabi tasindi"                        bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT m.mail_name FROM mail m JOIN domains d ON d.id=m.dom_id WHERE d.name='$T'\\\"\" | grep -q info"
check "alias tasindi"                              bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT COUNT(*) FROM domain_aliases da JOIN domains d ON d.id=da.dom_id WHERE d.name='$T'\\\"\" | tr -d '[:space:]' | grep -q '^[1-9]'"
check "sertifika tasindi"                          bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT c.name FROM certificates c JOIN domains d ON d.certificate_id=c.id WHERE d.name='$T'\\\"\" | grep -q demo-cert"
check "tum vhost kopyalandi (.composer)"           bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"test -f '/var/www/vhosts/$T/.composer/composer.json'\""
scenario_end

# ===========================================================================
# S11 - UZAK SUNUCU: BIREBIR TASIMA (ayni isim)
# ===========================================================================
T="$SRC_DOMAIN"
scenario S11 "uzak-birebir-tasima-move"
cleanup_remote "$T"
$PC -s "$SRC_DOMAIN" --move --to-host "$REMOTE_IP" --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti (rc=$RC)"             test "$RC" -eq 0
check "hedef sunucuda ayni isimle domain var"      assert_domain_remote "$T"
BD="$(docroot_of_b "$T")"
check "sistem kullanicisi kaynakla ayni"           bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT su.login FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$T' LIMIT 1\\\"\" | tr -d '[:space:]\r')\" == '$SRC_SYSUSER' ]]"
check ".env HIC DEGISMEDI (birebir)"               bash -c "diff <(cat '$SRC_DOCROOT/.env') <(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"cat '$BD/.env'\")"
check "wp-config.php HIC DEGISMEDI"                bash -c "diff <(cat '$SRC_DOCROOT/wp-config.php') <(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"cat '$BD/wp-config.php'\")"
check "HEDEF SUNUCUDA UYGULAMA DB'YE BAGLANIYOR"   health_remote "$BD"
check "config yedegi olusturulmadi (gerek yoktu)"  bash -c "! ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"ls -d /var/www/vhosts/$T/.plesk-clone-backup/*/ 2>/dev/null\" | grep -q ."
check "DEPLOY SCRIPT HEDEF SUNUCUDA CALISIYOR"     bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"bash '$BD/deploy.sh'\""
check "git deposu tasindi"                         bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"git --git-dir='/var/www/vhosts/$T/git/app.git' log --oneline\" | grep -q 'ilk surum'"
check "alt alan adi tasindi"                       bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"plesk db -Ne \\\"SELECT COUNT(*) FROM domains d JOIN domains p ON p.id=d.parentDomainId WHERE p.name='$T'\\\"\" | tr -d '[:space:]' | grep -q '^[1-9]'"
scenario_end

# ===========================================================================
# S12 - UZAK: sadece DB adi degissin, kullanici/parola korunsun
# ===========================================================================
T=karma.test
scenario S12 "uzak-ad-degisir-kimlik-korunur"
cleanup_remote "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" \
   --db-mode suffix --db-user-mode keep --db-pass-mode keep --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                      test "$RC" -eq 0
BD="$(docroot_of_b "$T")"
check "DB adi sonek aldi"                          bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^DB_DATABASE=//p' '$BD/.env'\" | tr -d '\r')\" == shopdb_* ]]"
check "DB kullanicisi korundu (shopuser)"          bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^DB_USERNAME=//p' '$BD/.env'\" | tr -d '\r')\" == 'shopuser' ]]"
check "DB parolasi korundu"                        bash -c "[[ \"\$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP \"sed -n 's/^DB_PASSWORD=//p' '$BD/.env'\" | tr -d '\r')\" == 'ShopPass#2026a' ]]"
check "HEDEF SUNUCUDA UYGULAMA DB'YE BAGLANIYOR"   health_remote "$BD"
scenario_end

# ===========================================================================
# S13 - Kurulum ve guncelleme akisi
# ===========================================================================
scenario S13 "kurulum-ve-guncelleme"
check "pleskclone komutu PATH'te"                  bash -c "command -v pleskclone >/dev/null"
check "--version calisiyor"                        bash -c "pleskclone --version | grep -q 'plesk-clone'"
check "--where kurulum bilgisi veriyor"            bash -c "pleskclone --where 2>&1 | grep -q 'Kurulum yeri'"
check "tek dosyalik surum uretilmis"               test -f /usr/local/lib/pleskclone/dist/plesk-clone.sh
check "tek dosyalik surum bagimsiz calisiyor"      bash -c "bash /usr/local/lib/pleskclone/dist/plesk-clone.sh --version | grep -q 'plesk-clone'"
check "--update yerel kaynaktan calisiyor"         bash -c "PLESKCLONE_SRC=/opt/pleskclone-src pleskclone --update 2>&1 | grep -qi 'guncel\|Guncellendi'"
check "guncelleme sonrasi komut hala calisiyor"    bash -c "pleskclone --version | grep -q 'plesk-clone'"
check "hedef sunucuda da kurulu"                   bash -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$REMOTE_IP 'pleskclone --version' | grep -q 'plesk-clone'"
scenario_end

# ===========================================================================
# S14 - --full-vhost ve --no-config-rewrite
# ===========================================================================
T=stg8.demo.test
scenario S14 "full-vhost-ve-config-rewrite-kapali"
cleanup_local "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --new-db --full-vhost --no-config-rewrite --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
TD="$(docroot_of "$T")"
check "komut basariyla bitti"                      test "$RC" -eq 0
check "vhost geneli kopyalandi (.composer)"        test -f "/var/www/vhosts/$T/.composer/composer.json"
check "logs dizini haric tutuldu"                  bash -c "[[ ! -e '/var/www/vhosts/$T/logs/hariclendi.txt' ]]"
check "config yeniden yazilmadi (DB_DATABASE=shopdb)" bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$TD/.env')\" == 'shopdb' ]]"
scenario_end

# ===========================================================================
# Ek senaryolar (S15+)
# ===========================================================================
EXTRA="$(dirname "${BASH_SOURCE[0]}")/scenarios_extra.sh"
[[ -f "$EXTRA" ]] && . "$EXTRA"

# ===========================================================================
# OZET
# ===========================================================================
SUM="$LOGDIR/SUMMARY.txt"
{
  printf '=========================================================================\n'
  printf ' PLESK CLONE - TEST OZETI\n'
  printf ' Tarih   : %s\n' "$(date '+%F %T')"
  printf ' Kaynak  : %s (plesk-a)\n' "$SRC_DOMAIN"
  printf ' Hedef   : plesk-b (%s)\n' "$REMOTE_IP"
  printf ' Plesk   : %s\n' "$(plesk version 2>/dev/null | awk -F': *' '/Product version/{print $2; exit}')"
  printf ' Surum   : %s\n' "$(pleskclone --version 2>/dev/null)"
  printf '=========================================================================\n\n'
  printf '%-4s %-34s %-16s %s\n' "ID" "SENARYO" "SONUC" "LOG"
  printf -- '-------------------------------------------------------------------------\n'
  for r in "${RESULTS[@]}"; do printf '%s\n' "$r"; done
  printf -- '-------------------------------------------------------------------------\n'
  printf '\nToplam kontrol : %s\n' "$TOTAL"
  printf 'Gecen          : %s\n' "$PASSED"
  printf 'Kalan          : %s\n' "$FAILED"
  printf '\n'
  if (( FAILED == 0 )); then printf 'GENEL SONUC: TUM KONTROLLER GECTI\n'
  else printf 'GENEL SONUC: %s KONTROL BASARISIZ\n' "$FAILED"; fi
} >"$SUM"

printf '\n'
cat "$SUM"
exit $(( FAILED > 0 ? 1 : 0 ))
