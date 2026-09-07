#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Iki Plesk VM'ini taşımaya hazırlar:
#   - VM'lerin birbirini gorup gormedigini tespit eder
#   - plesk-a -> plesk-b icin root SSH anahtari kurar
#   - iki VM'e de pleskclone kurar
#
# Kullanim: ./prepare-vms.sh
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

A=plesk-a
B=plesk-b

ok()   { printf '[hazirlik][OK] %s\n' "$*"; }
warn() { printf '[hazirlik][UYARI] %s\n' "$*"; }
die()  { printf '[hazirlik][HATA] %s\n' "$*" >&2; exit 1; }

vm() { local n="$1"; shift; limactl shell "$n" -- "$@"; }
vmroot() { local n="$1"; shift; limactl shell "$n" -- sudo bash -c "$*"; }

# ---- VM IP'leri ----
ip_of() {
  limactl shell "$1" -- bash -c "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null | tr -d '\r'
}
A_IP="$(ip_of "$A")"
B_IP="$(ip_of "$B")"
[[ -n "$A_IP" && -n "$B_IP" ]] || die "VM IP'leri okunamadi"
ok "$A -> $A_IP"
ok "$B -> $B_IP"

# ---- birbirlerini goruyorlar mi ----
if vm "$A" bash -c "ping -c1 -W2 $B_IP >/dev/null 2>&1"; then
  ok "$A, $B'ye dogrudan ulasiyor"
  DIRECT=1
else
  warn "$A, $B'ye dogrudan ulasamiyor - vzNAT gerekiyor olabilir"
  DIRECT=0
fi

# ---- root SSH ----
vmroot "$B" "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config; \
             mkdir -p /root/.ssh && chmod 700 /root/.ssh; \
             systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true"
ok "$B: root SSH (anahtar ile) acildi"

vmroot "$A" "[[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C pleskclone >/dev/null; \
             printf 'StrictHostKeyChecking no\\nUserKnownHostsFile /dev/null\\nLogLevel ERROR\\n' > /root/.ssh/config; \
             chmod 600 /root/.ssh/config"
PUB="$(vmroot "$A" "cat /root/.ssh/id_ed25519.pub" | tr -d '\r')"
[[ -n "$PUB" ]] || die "$A public key okunamadi"
vmroot "$B" "printf '%s\\n' '$PUB' >> /root/.ssh/authorized_keys; \
             sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys; \
             chmod 600 /root/.ssh/authorized_keys"
ok "anahtar $B'ye kuruldu"

if vmroot "$A" "ssh -o BatchMode=yes -o ConnectTimeout=10 root@$B_IP 'hostname'" >/dev/null 2>&1; then
  ok "$A -> $B root SSH CALISIYOR"
else
  die "$A -> $B root SSH kurulamadi (VM'ler birbirini gormuyor olabilir)"
fi

# ---- pleskclone kurulumu ----
for n in "$A" "$B"; do
  vmroot "$n" "PLESKCLONE_SRC=/opt/pleskclone-src bash /opt/pleskclone-src/install.sh --quiet" \
    || die "$n: pleskclone kurulamadi"
  ok "$n: $(vmroot "$n" "pleskclone --version" | tr -d '\r')"
done

printf '\n'
ok "Hazir. Hedef sunucu IP'si: $B_IP"
printf '\nTasima komutu (%s uzerinde calisir):\n' "$A"
printf '  limactl shell %s -- sudo pleskclone -s <DOMAIN> --move --to-host %s\n\n' "$A" "$B_IP"
