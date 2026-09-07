#!/usr/bin/env bash
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
