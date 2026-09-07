# ---------------------------------------------------------------------------
# Lisanssiz test dugumu (native mimari - hizli)
#
# GERCEK olanlar : MariaDB, OpenSSH, rsync, git, sqlite3, cron, PHP, tar/gzip,
#                  dosya sistemi, sistem kullanicilari, izinler, psa semasi
# UYUMLULUK KATMANI : sadece "plesk" CLI komut yuzeyi (test/sim/plesk)
#
# Gerekcesi: plesk/plesk imajinin lisans anahtari sanallastirma dogrulamasi
# ister ve bu dogrulama qemu-x86_64 emulasyonunda gecmez; ayrica anahtar tek
# domain ile sinirlidir. Gercek Plesk profili icin: docker-compose.yml "real".
# ---------------------------------------------------------------------------
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      mariadb-server mariadb-client \
      openssh-server openssh-client \
      rsync git sqlite3 cron gzip tar openssl \
      php-cli php-mysql \
      procps iproute2 ca-certificates curl less file \
      coreutils findutils sed gawk diffutils \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd -f psacln && groupadd -f psaserv \
 && (getent group popuser >/dev/null || groupadd popuser) \
 && (id popuser >/dev/null 2>&1 || useradd -M -g popuser -s /usr/sbin/nologin popuser)

RUN mkdir -p /var/www/vhosts /etc/psa \
             /usr/local/psa/var/modules/git/keys \
             /var/qmail/mailnames /run/sshd /root/.ssh \
 && chmod 700 /root/.ssh \
 && printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\nLogLevel ERROR\n' > /root/.ssh/config \
 && chmod 600 /root/.ssh/config \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config \
 && sed -i 's/^#\?UseDNS.*/UseDNS no/'                                   /etc/ssh/sshd_config

COPY plesk          /usr/local/sbin/plesk
COPY psa_schema.sql /opt/psa_schema.sql
COPY entrypoint.sh  /usr/local/sbin/entrypoint.sh
RUN chmod 755 /usr/local/sbin/plesk /usr/local/sbin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
