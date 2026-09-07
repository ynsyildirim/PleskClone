#!/usr/bin/env bash
# Test dugumu baslatici: MariaDB + sshd + cron, psa semasi, admin kimlik bilgisi
set -uo pipefail

log() { printf '[node] %s\n' "$*"; }

# Her konteynerin kendi makine kimligi olsun ("ayni makine" korumasi testi icin)
head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/machine-id

# ---- MariaDB ----
mkdir -p /run/mysqld /var/log/mysql
chown -R mysql:mysql /run/mysqld /var/lib/mysql /var/log/mysql 2>/dev/null || true
if [[ ! -d /var/lib/mysql/mysql ]]; then
  log "MariaDB ilk kurulum"
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 \
    || mysql_install_db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1
fi
log "MariaDB baslatiliyor"
mysqld_safe --user=mysql --skip-name-resolve >/var/log/mysql/safe.log 2>&1 &
for i in $(seq 1 60); do
  mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 && break
  sleep 1
done
mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 || { log "MariaDB baslatilamadi"; tail -20 /var/log/mysql/safe.log; }

# ---- Plesk admin kimlik bilgisi ----
if [[ ! -f /etc/psa/.psa.shadow ]]; then
  mkdir -p /etc/psa
  openssl rand -base64 18 | tr -d '\n=/+' | head -c 20 > /etc/psa/.psa.shadow
  chmod 600 /etc/psa/.psa.shadow
fi
ADMINPW="$(cat /etc/psa/.psa.shadow)"
mysql --protocol=socket -uroot -e "
  CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED BY '$ADMINPW';
  ALTER USER 'admin'@'localhost' IDENTIFIED BY '$ADMINPW';
  GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
  FLUSH PRIVILEGES;" 2>/dev/null && log "admin MySQL kullanicisi hazir"

# ---- psa semasi ----
mysql --protocol=socket -uroot < /opt/psa_schema.sql 2>/dev/null && log "psa semasi yuklendi"

# Sunucunun kendi IP'sini kaydet
IP="$(hostname -I | awk '{print $1}')"
mysql --protocol=socket -uroot psa -e "INSERT IGNORE INTO IP_Addresses (ip_address) VALUES ('$IP');" 2>/dev/null

# ---- Git Extension SQLite ----
mkdir -p /usr/local/psa/var/modules/git/keys
GITDB=/usr/local/psa/var/modules/git/git_db.db
if [[ ! -f "$GITDB" ]]; then
  sqlite3 "$GITDB" <<'SQL'
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
  log "Git Extension veritabani olusturuldu"
fi

# ---- git (sadece test kosumu icin ayri global config) ----
# Test betikleri root olarak domain kullanicisina ait depolarda git calistirir.
# safe.directory yalnizca korumali konfigurasyondan (system/global/-c) okunur.
# Bunu SISTEM GENELINE yazmiyoruz; ayri bir dosyaya yaziyoruz ve test betikleri
# GIT_CONFIG_GLOBAL ile bu dosyayi kullaniyor. Boylece urun kodunun kendi
# -c safe.directory duzeltmesi maskelenmez, regresyon kapsami korunur.
printf '[safe]\n\tdirectory = *\n' > /opt/testgitconfig
chmod 644 /opt/testgitconfig

# ---- sshd ----
mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
ssh-keygen -A >/dev/null 2>&1
/usr/sbin/sshd
log "sshd baslatildi"

# ---- cron ----
service cron start >/dev/null 2>&1 || cron 2>/dev/null || true

# ---- vhost kok dizini ----
mkdir -p /var/www/vhosts /var/qmail/mailnames

log "Dugum hazir: $(hostname) ip=$IP"
touch /run/node-ready

# Konteyneri ayakta tut
tail -f /dev/null
