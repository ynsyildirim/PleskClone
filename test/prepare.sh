#!/usr/bin/env bash
# Host tarafi: dugumler arasi ssh + pleskclone kurulumu (yeniden calistirilabilir)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

A="${1:-node-a}"
B="${2:-node-b}"
BIP="${3:-172.28.0.11}"

ok(){ printf '[hazirlik][OK] %s\n' "$*"; }
die(){ printf '[hazirlik][HATA] %s\n' "$*" >&2; exit 1; }

for c in "$A" "$B"; do
  docker exec "$c" bash -c 'mkdir -p /run/sshd /root/.ssh; chmod 700 /root/.ssh; pgrep -x sshd >/dev/null || /usr/sbin/sshd' \
    || die "$c: sshd baslatilamadi"
done
ok "sshd calisiyor"

docker exec "$A" bash -c '[[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C pleskclone-test >/dev/null'
PUB="$(docker exec "$A" cat /root/.ssh/id_ed25519.pub)"
docker exec "$B" bash -c "printf '%s\n' '$PUB' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
docker exec "$A" ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$BIP" true \
  || die "$A -> $B ssh kurulamadi"
ok "$A -> $B ssh calisiyor"

for c in "$A" "$B"; do
  docker exec "$c" bash -c 'PLESKCLONE_SRC=/opt/pleskclone-src bash /opt/pleskclone-src/install.sh --quiet' \
    || die "$c: install.sh basarisiz"
  ok "$c: $(docker exec "$c" pleskclone --version)"
done
