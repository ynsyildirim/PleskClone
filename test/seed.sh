#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Kaynak dugumu (plesk-a) gercekci demo veriyle doldurur.
#
# Olusturulanlar:
#   - demo.test domaini (hosting, sistem kullanicisi)
#   - httpdocs icerigi: index.php, .env, wp-config.php, health.php
#   - 2 veritabani + kullanicilari (shopdb/shopuser, blogdb/bloguser)
#   - bare git deposu + deploy (post-deployment) script + Git Extension kaydi
#   - crontab girdisi
#   - alt alan adi, domain alias, mail hesabi, ek DNS kayitlari
#   - kendinden imzali SSL sertifikasi
# ---------------------------------------------------------------------------
set -uo pipefail

DOMAIN="${SEED_DOMAIN:-demo.test}"
SUB="app"
ALIAS="demo-alias.test"
SYSUSER="demouser"
SYSPASS='SeedUser#2026x'
DB1=shopdb;  DB1USER=shopuser;  DB1PASS='ShopPass#2026a'
DB2=blogdb;  DB2USER=bloguser;  DB2PASS='BlogPass#2026b'
VHOST="/var/www/vhosts/$DOMAIN"
DOCROOT="$VHOST/httpdocs"
GITDIR="$VHOST/git"
GIT_DB=/usr/local/psa/var/modules/git/git_db.db

say()  { printf '[SEED] %s\n' "$*"; }
ok()   { printf '[SEED][OK] %s\n' "$*"; }
warn() { printf '[SEED][UYARI] %s\n' "$*"; }
die()  { printf '[SEED][HATA] %s\n' "$*" >&2; exit 1; }

psa() { plesk db -Ne "$1" 2>/dev/null; }

say "Kaynak dugum tohumlaniyor: $DOMAIN"

# ---------------------------------------------------------------------------
# 1. Servis plani
# ---------------------------------------------------------------------------
PLAN="$(psa "SELECT name FROM ServicePlans WHERE name NOT LIKE '%Reseller%' ORDER BY id LIMIT 1;")"
[[ -z "$PLAN" ]] && PLAN="Default Domain"
say "Servis plani: $PLAN"

# ---------------------------------------------------------------------------
# 2. Domain
# ---------------------------------------------------------------------------
if plesk bin domain --info "$DOMAIN" >/dev/null 2>&1; then
  say "Domain zaten var: $DOMAIN"
else
  plesk bin domain --create "$DOMAIN" \
     -owner admin -service-plan "$PLAN" \
     -login "$SYSUSER" -passwd "$SYSPASS" -hosting true \
    || die "Domain olusturulamadi"
  ok "Domain olusturuldu: $DOMAIN (sys=$SYSUSER)"
fi

# SSH shell acik olsun (kopyalanip kopyalanmadigini test edecegiz)
plesk bin domain --update "$DOMAIN" -shell /bin/bash >/dev/null 2>&1 \
  && ok "SSH shell: /bin/bash" || warn "SSH shell ayarlanamadi"

# PHP surumu belirle (hedefte ayni mi olacak bakacagiz)
PHPH="$(psa "SELECT id FROM php_handlers WHERE id LIKE '%fpm%' ORDER BY id DESC LIMIT 1;")"
[[ -n "$PHPH" ]] && plesk bin domain --update "$DOMAIN" -php-handler-id "$PHPH" >/dev/null 2>&1 \
  && ok "PHP handler: $PHPH"

DOCROOT="$(psa "SELECT h.www_root FROM hosting h JOIN domains d ON d.id=h.dom_id WHERE d.name='$DOMAIN' LIMIT 1;")"
[[ "$DOCROOT" != /* ]] && DOCROOT="$VHOST/${DOCROOT:-httpdocs}"
say "Document root: $DOCROOT"

# ---------------------------------------------------------------------------
# 3. Veritabanlari
# ---------------------------------------------------------------------------
create_db() {
  local db="$1" user="$2" pass="$3"
  if psa "SELECT name FROM data_bases WHERE name='$db';" | grep -q .; then
    say "DB zaten var: $db"
  else
    plesk bin database --create "$db" -domain "$DOMAIN" -type mysql -server localhost \
      || die "DB olusturulamadi: $db"
    plesk bin database --create-dbuser "$user" -passwd "$pass" -database "$db" \
      -domain "$DOMAIN" -type mysql -server localhost \
      || die "DB kullanicisi olusturulamadi: $user"
    ok "DB olusturuldu: $db / $user"
  fi
  # Icerik
  local adminpass; adminpass="$(cat /etc/psa/.psa.shadow)"
  MYSQL_PWD="$adminpass" mysql -uadmin "$db" <<SQL
CREATE TABLE IF NOT EXISTS items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  note TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
DELETE FROM items;
INSERT INTO items (name, note) VALUES
 ('$db-kayit-1','kaynak sunucudan'),
 ('$db-kayit-2','klonlama testi'),
 ('$db-kayit-3','ucuncu satir');
CREATE OR REPLACE VIEW items_view AS SELECT id, name FROM items;
DROP PROCEDURE IF EXISTS item_count;
CREATE PROCEDURE item_count() SELECT COUNT(*) FROM items;
SQL
  ok "  $db icerigi hazir ($(MYSQL_PWD="$adminpass" mysql -uadmin -N -B -e "SELECT COUNT(*) FROM items" "$db") satir)"
}
create_db "$DB1" "$DB1USER" "$DB1PASS"
create_db "$DB2" "$DB2USER" "$DB2PASS"

# ---------------------------------------------------------------------------
# 4. Uygulama dosyalari
# ---------------------------------------------------------------------------
mkdir -p "$DOCROOT"

cat >"$DOCROOT/.env" <<EOF
APP_NAME=DemoApp
APP_ENV=production
APP_URL=https://$DOMAIN
APP_HOST=$DOMAIN

DB_CONNECTION=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=$DB1
DB_USERNAME=$DB1USER
DB_PASSWORD=$DB1PASS

BLOG_DB_DATABASE=$DB2
BLOG_DB_USERNAME=$DB2USER
BLOG_DB_PASSWORD=$DB2PASS

MAIL_FROM=info@$DOMAIN
EOF

cat >"$DOCROOT/wp-config.php" <<EOF
<?php
define( 'DB_NAME', '$DB1' );
define( 'DB_USER', '$DB1USER' );
define( 'DB_PASSWORD', '$DB1PASS' );
define( 'DB_HOST', 'localhost' );
define( 'WP_HOME', 'https://$DOMAIN' );
define( 'WP_SITEURL', 'https://$DOMAIN' );
EOF

cat >"$DOCROOT/index.php" <<EOF
<?php
echo "DemoApp on $DOMAIN\n";
EOF

# Saglik kontrolu: .env'i okur ve GERCEKTEN veritabanina baglanir.
# Klonlamadan sonra hedefte bunu calistiracagiz; OK donerse DB adi/kullanici/
# parola ve config yeniden yazimi zincirinin tamami dogru demektir.
cat >"$DOCROOT/health.php" <<'PHPEOF'
<?php
// Kullanim: php health.php [env-dosyasi]
$envFile = $argv[1] ?? __DIR__ . '/.env';
if (!is_readable($envFile)) { fwrite(STDERR, "FAIL: .env okunamadi: $envFile\n"); exit(2); }
$env = [];
foreach (file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    if ($line[0] === '#' || strpos($line, '=') === false) continue;
    [$k, $v] = explode('=', $line, 2);
    $env[trim($k)] = trim($v);
}
$checks = [
    ['ana',  $env['DB_DATABASE'] ?? '',      $env['DB_USERNAME'] ?? '',      $env['DB_PASSWORD'] ?? ''],
    ['blog', $env['BLOG_DB_DATABASE'] ?? '', $env['BLOG_DB_USERNAME'] ?? '', $env['BLOG_DB_PASSWORD'] ?? ''],
];
$fail = 0;
foreach ($checks as [$label, $db, $user, $pass]) {
    if ($db === '') { echo "SKIP $label (tanimsiz)\n"; continue; }
    $conn = @new mysqli($env['DB_HOST'] ?? 'localhost', $user, $pass, $db);
    if ($conn->connect_errno) {
        echo "FAIL $label db=$db user=$user -> {$conn->connect_error}\n"; $fail++; continue;
    }
    $r = $conn->query('SELECT COUNT(*) c FROM items');
    if (!$r) { echo "FAIL $label db=$db -> sorgu hatasi\n"; $fail++; $conn->close(); continue; }
    $c = $r->fetch_assoc()['c'];
    echo "OK $label db=$db user=$user satir=$c\n";
    $conn->close();
}
echo "APP_URL=" . ($env['APP_URL'] ?? '?') . "\n";
exit($fail === 0 ? 0 : 1);
PHPEOF

chown -R "$SYSUSER":psacln "$DOCROOT"
ok "Uygulama dosyalari yazildi (.env, wp-config.php, index.php, health.php)"

# Kaynakta saglik kontrolu gecmeli
if php "$DOCROOT/health.php" >/tmp/seed_health.txt 2>&1; then
  ok "Kaynak saglik kontrolu: $(tr '\n' ' ' </tmp/seed_health.txt)"
else
  warn "Kaynak saglik kontrolu BASARISIZ: $(cat /tmp/seed_health.txt)"
fi

# ---------------------------------------------------------------------------
# 5. .composer dizini
# ---------------------------------------------------------------------------
mkdir -p "$VHOST/.composer/cache/files"
echo '{"config":{"vendor-dir":"vendor"}}' > "$VHOST/.composer/composer.json"
echo 'onbellek-dosyasi' > "$VHOST/.composer/cache/files/dummy.bin"
chown -R "$SYSUSER":psacln "$VHOST/.composer"
ok "Composer dizini hazir (cache dahil)"

# ---------------------------------------------------------------------------
# 6. Git: bare depo + deploy script + Plesk Git Extension kaydi
# ---------------------------------------------------------------------------
mkdir -p "$GITDIR"
WORK=/tmp/seed-git-work
rm -rf "$WORK" "$GITDIR/app.git"
git init --bare -q "$GITDIR/app.git"

git init -q "$WORK"
cd "$WORK"
git config user.email seed@test.local
git config user.name "Seed Bot"

cat > deploy.sh <<EOF
#!/usr/bin/env bash
# Deploy sonrasi calisan script (Plesk post-deployment action)
set -e
DOMAIN_NAME="$DOMAIN"
DOCROOT="/var/www/vhosts/\$DOMAIN_NAME/httpdocs"
echo "[deploy] domain=\$DOMAIN_NAME"
echo "[deploy] docroot=\$DOCROOT"
if [[ -f "\$DOCROOT/.env" ]]; then
  echo "[deploy] .env bulundu"
  php "\$DOCROOT/health.php" "\$DOCROOT/.env"
else
  echo "[deploy] .env YOK" >&2
  exit 1
fi
echo "[deploy] tamamlandi"
EOF
chmod +x deploy.sh

cat > app.php <<EOF
<?php
// Depodan gelen uygulama dosyasi
define('DEPLOYED_DOMAIN', '$DOMAIN');
echo "app.php @ " . DEPLOYED_DOMAIN . "\n";
EOF

echo "DemoApp git deposu - kaynak: $DOMAIN" > README.md
git add -A
git commit -q -m "ilk surum"
git branch -M main
git remote add origin "$GITDIR/app.git"
git push -q origin main
cd /
rm -rf "$WORK"
ok "Bare git deposu hazir: $GITDIR/app.git (branch main)"

# Ikinci depo: BARE OLMAYAN. Plesk yerlesimi korunur (git dizininin kendisi
# <ad>.git'tir) ama core.bare=false'tur. worktree bileseninin gercek yolunu
# kapsamak icin gerekli.
rm -rf "$GITDIR/site.git" /tmp/site-work
git init --bare -q "$GITDIR/site.git"
git init -q /tmp/site-work
(
  cd /tmp/site-work
  git config user.email seed@test.local
  git config user.name "Seed Bot"
  echo "site deposu - git ile izlenen dosya" > tracked.txt
  git add -A && git commit -q -m "site ilk surum" && git branch -M main
  git remote add origin "$GITDIR/site.git" && git push -q origin main
) >/dev/null 2>&1
rm -rf /tmp/site-work
# Plesk'in "remote" tipi depolari bare degildir
git --git-dir="$GITDIR/site.git" config core.bare false
ok "Bare OLMAYAN git deposu hazir: $GITDIR/site.git (core.bare=false)"

# Plesk Git Extension SQLite kaydi
mkdir -p "$(dirname "$GIT_DB")" /usr/local/psa/var/modules/git/keys
if [[ ! -f "$GIT_DB" ]]; then
  say "Git Extension veritabani yok, sema olusturuluyor"
  sqlite3 "$GIT_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS Repositories (
  domainId INTEGER, name TEXT, type TEXT, deploymentMode TEXT, branch TEXT,
  deploymentPath TEXT, fetchUrl TEXT, uuid TEXT PRIMARY KEY,
  skipSslVerification INTEGER, postDeploymentActionsEnabled INTEGER,
  deploymentsCounter INTEGER, deployKeyUuid TEXT, postDeploymentActions TEXT,
  httpUser TEXT, httpPassword TEXT, smbUserIds TEXT
);
CREATE TABLE IF NOT EXISTS DeployKeys (
  uuid TEXT PRIMARY KEY, domainUuid TEXT, name TEXT, isDefault INTEGER
);
CREATE TABLE IF NOT EXISTS RepositoryDeploymentInfo (
  repoUuid TEXT PRIMARY KEY, lastCommitHash TEXT, deployedCommitHash TEXT,
  deployedCommitAuthor TEXT, deployedCommitDate TEXT, deployedCommitMessage TEXT
);
SQL
fi

DOMID="$(psa "SELECT id FROM domains WHERE name='$DOMAIN' LIMIT 1;")"
DOMGUID="$(psa "SELECT guid FROM domains WHERE name='$DOMAIN' LIMIT 1;")"
REPO_UUID="$(cat /proc/sys/kernel/random/uuid)"
KEY_UUID="$(cat /proc/sys/kernel/random/uuid)"

# Deploy script'i post-deployment action olarak kaydet (icinde domain adi geciyor -
# klonlamada hedef domaine cevrilmesi gerekiyor)
POSTACT="cd /var/www/vhosts/$DOMAIN/httpdocs && bash /var/www/vhosts/$DOMAIN/httpdocs/deploy.sh"

sqlite3 "$GIT_DB" "
DELETE FROM Repositories WHERE domainId=$DOMID;
INSERT INTO Repositories
 (domainId,name,type,deploymentMode,branch,deploymentPath,fetchUrl,uuid,
  skipSslVerification,postDeploymentActionsEnabled,deploymentsCounter,
  deployKeyUuid,postDeploymentActions,httpUser,httpPassword,smbUserIds)
VALUES
 ($DOMID,'app','local','auto','main','$DOCROOT','','$REPO_UUID',
  0,1,3,'$KEY_UUID','$(printf '%s' "$POSTACT" | sed "s/'/''/g")',NULL,NULL,NULL);
INSERT OR REPLACE INTO DeployKeys (uuid,domainUuid,name,isDefault)
VALUES ('$KEY_UUID','$DOMGUID','app',1);
INSERT OR REPLACE INTO RepositoryDeploymentInfo
 (repoUuid,lastCommitHash,deployedCommitHash,deployedCommitAuthor,deployedCommitDate,deployedCommitMessage)
VALUES ('$REPO_UUID',NULL,NULL,NULL,NULL,NULL);
" || warn "Git Extension kaydi eklenemedi"
ok "Git Extension kaydi eklendi (repo=app, deploy script kayitli)"

# Depoyu docroot'a deploy et (Plesk'in yaptigi isin esdegeri)
git --git-dir="$GITDIR/app.git" --work-tree="$DOCROOT" checkout -f main >/dev/null 2>&1 \
  && ok "Depo docroot'a deploy edildi" || warn "Deploy edilemedi"
chown -R "$SYSUSER":psacln "$VHOST"

# Kaynakta deploy script'i calissin
if bash "$DOCROOT/deploy.sh" >/tmp/seed_deploy.txt 2>&1; then
  ok "Kaynak deploy script'i calisti"
  sed 's/^/       /' /tmp/seed_deploy.txt
else
  warn "Kaynak deploy script'i basarisiz:"; sed 's/^/       /' /tmp/seed_deploy.txt
fi

# ---------------------------------------------------------------------------
# 7. Crontab
# ---------------------------------------------------------------------------
crontab -u "$SYSUSER" - <<EOF
# DemoApp zamanlanmis gorevleri
*/15 * * * * /usr/bin/php /var/www/vhosts/$DOMAIN/httpdocs/index.php >/dev/null 2>&1
0 3 * * * /usr/bin/php /var/www/vhosts/$DOMAIN/httpdocs/health.php >/dev/null 2>&1
EOF
ok "Crontab yazildi ($(crontab -l -u "$SYSUSER" | grep -c '^[^#]' ) gorev)"

# ---------------------------------------------------------------------------
# 8. Alt alan adi
# ---------------------------------------------------------------------------
if plesk bin subdomain --info "$SUB.$DOMAIN" >/dev/null 2>&1; then
  say "Alt alan adi zaten var"
else
  plesk bin subdomain --create "$SUB" -domain "$DOMAIN" >/dev/null 2>&1 \
    && ok "Alt alan adi olusturuldu: $SUB.$DOMAIN" || warn "Alt alan adi olusturulamadi"
fi
SUBROOT="$(psa "SELECT h.www_root FROM hosting h JOIN domains d ON d.id=h.dom_id WHERE d.name='$SUB.$DOMAIN' LIMIT 1;")"
[[ -n "$SUBROOT" ]] && { [[ "$SUBROOT" != /* ]] && SUBROOT="$VHOST/$SUBROOT"; mkdir -p "$SUBROOT"; echo "<?php echo 'subdomain on $DOMAIN';" > "$SUBROOT/index.php"; }

# ---------------------------------------------------------------------------
# 9. Domain alias
# ---------------------------------------------------------------------------
plesk bin site_alias --create "$ALIAS" -domain "$DOMAIN" >/dev/null 2>&1 \
  && ok "Alias olusturuldu: $ALIAS" || warn "Alias olusturulamadi (zaten var olabilir)"

# ---------------------------------------------------------------------------
# 10. Mail hesabi
# ---------------------------------------------------------------------------
plesk bin mail --create "info@$DOMAIN" -mailbox true -passwd 'MailPass#2026m' >/dev/null 2>&1 \
  && ok "Mail hesabi olusturuldu: info@$DOMAIN" || warn "Mail hesabi olusturulamadi"

# ---------------------------------------------------------------------------
# 11. Ek DNS kayitlari
# ---------------------------------------------------------------------------
plesk bin dns --add "$DOMAIN" -txt "v=spf1 a mx -all" -domain-name "" >/dev/null 2>&1 \
  && ok "TXT (SPF) kaydi eklendi" || warn "TXT kaydi eklenemedi"
plesk bin dns --add "$DOMAIN" -cname "cdn" -canonical "cdn.example.net." >/dev/null 2>&1 \
  && ok "CNAME kaydi eklendi" || warn "CNAME kaydi eklenemedi"

# ---------------------------------------------------------------------------
# 12. SSL sertifikasi (kendinden imzali)
# ---------------------------------------------------------------------------
CERTDIR=/tmp/seed-cert; rm -rf "$CERTDIR"; mkdir -p "$CERTDIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
  -subj "/CN=$DOMAIN/O=PleskCloneTest" >/dev/null 2>&1
if plesk bin certificate --create "demo-cert" -domain "$DOMAIN" \
     -cert-file "$CERTDIR/cert.pem" -key-file "$CERTDIR/key.pem" >/dev/null 2>&1; then
  plesk bin site --update "$DOMAIN" -ssl true -certificate-name "demo-cert" >/dev/null 2>&1
  ok "SSL sertifikasi olusturuldu ve atandi: demo-cert"
else
  warn "SSL sertifikasi olusturulamadi"
fi
rm -rf "$CERTDIR"

# ---------------------------------------------------------------------------
# 13. FTP alt hesabi
# ---------------------------------------------------------------------------
plesk bin ftpsubaccount --create "demoftp" -domain "$DOMAIN" -passwd 'FtpPass#2026f' -home "/httpdocs" >/dev/null 2>&1 \
  && ok "FTP alt hesabi olusturuldu: demoftp" || warn "FTP alt hesabi olusturulamadi"

# ---------------------------------------------------------------------------
# Ozet
# ---------------------------------------------------------------------------
printf '\n[SEED] ==================== OZET ====================\n'
printf '  Domain        : %s (id=%s)\n' "$DOMAIN" "$DOMID"
printf '  Sistem kul.   : %s\n' "$SYSUSER"
printf '  Document root : %s\n' "$DOCROOT"
printf '  Veritabanlari : %s\n' "$(psa "SELECT GROUP_CONCAT(d.name) FROM data_bases d JOIN domains dm ON dm.id=d.dom_id WHERE dm.name='$DOMAIN';")"
printf '  DB kullanici  : %s\n' "$(psa "SELECT GROUP_CONCAT(du.login) FROM db_users du JOIN data_bases d ON d.id=du.db_id JOIN domains dm ON dm.id=d.dom_id WHERE dm.name='$DOMAIN';")"
printf '  Git depolari  : %s\n' "$(ls -1 "$GITDIR" 2>/dev/null | tr '\n' ' ')"
printf '  Git kayitlari : %s\n' "$(sqlite3 "$GIT_DB" "SELECT COUNT(*) FROM Repositories WHERE domainId=$DOMID;" 2>/dev/null)"
printf '  Cron gorev    : %s\n' "$(crontab -l -u "$SYSUSER" 2>/dev/null | grep -c '^[^#]')"
printf '  Alt alan adi  : %s\n' "$(psa "SELECT GROUP_CONCAT(d.name) FROM domains d JOIN domains p ON p.id=d.parentDomainId WHERE p.name='$DOMAIN';")"
printf '  Alias         : %s\n' "$(psa "SELECT GROUP_CONCAT(da.name) FROM domain_aliases da JOIN domains d ON d.id=da.dom_id WHERE d.name='$DOMAIN';")"
printf '  Mail          : %s\n' "$(psa "SELECT GROUP_CONCAT(m.mail_name) FROM mail m JOIN domains d ON d.id=m.dom_id WHERE d.name='$DOMAIN';")"
printf '  Sertifika     : %s\n' "$(psa "SELECT c.name FROM certificates c JOIN domains d ON d.certificate_id=c.id WHERE d.name='$DOMAIN';")"
printf '[SEED] ================================================\n'
ok "Tohumlama tamamlandi"
