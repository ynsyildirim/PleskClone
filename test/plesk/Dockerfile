# ---------------------------------------------------------------------------
# Test dugumu: gercek Plesk Obsidian + plesk_clone.sh'in ihtiyac duydugu araclar
#
# plesk/plesk imajinda hazir gelenler : rsync, sqlite3, curl, crontab,
#                                       mysqldump, tar, gzip, openssl
# Bu katmanda eklenenler              : openssh-server/client, git, php-cli
#
# Not: imaj sadece linux/amd64 yayinlanir. Apple Silicon uzerinde qemu-x86_64
# binfmt handler'i gerekir:  docker run --privileged --rm tonistiigi/binfmt --install amd64
# ---------------------------------------------------------------------------
FROM plesk/plesk:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server openssh-client git \
 && rm -rf /var/lib/apt/lists/*

# SSH: test ortami icin sadece anahtarla root erisimi
RUN mkdir -p /run/sshd /root/.ssh \
 && chmod 700 /root/.ssh \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config \
 && sed -i 's/^#\?UseDNS.*/UseDNS no/'                                   /etc/ssh/sshd_config \
 && printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\nLogLevel ERROR\n' > /root/.ssh/config \
 && chmod 600 /root/.ssh/config

# Plesk imajinin kendi init'i (systemd) korunur
