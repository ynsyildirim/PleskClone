#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Plesk Obsidian kurulumu (Ubuntu 22.04 ARM64 - native, emulasyon yok)
#
# Kullanim:  sudo /opt/pleskclone-src/test/lima/install-plesk.sh
#
# Kurulum sonrasi Plesk otomatik olarak 14 gunluk deneme lisansi yukler
# (3 domain'e kadar). Panel: https://127.0.0.1:8443
# ---------------------------------------------------------------------------
set -uo pipefail

log()  { printf '[plesk-kurulum] %s\n' "$*"; }
die()  { printf '[plesk-kurulum][HATA] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "root gerekli (sudo ile calistirin)"

if command -v plesk >/dev/null 2>&1; then
  log "Plesk zaten kurulu: $(plesk version 2>/dev/null | head -1)"
  exit 0
fi

log "Mimari: $(uname -m)  |  OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
[[ "$(uname -m)" == "aarch64" ]] || log "UYARI: aarch64 beklenmisti"

# Plesk swap ister
if [[ "$(free -m | awk '/Swap:/{print $2}')" -lt 900 ]]; then
  log "Swap olusturuluyor"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
fi

export DEBIAN_FRONTEND=noninteractive
log "Bagimliliklar kuruluyor"
apt-get update -qq
apt-get install -y -qq wget curl ca-certificates >/dev/null

log "Plesk one-click installer indiriliyor ve calistiriliyor (15-30 dk surebilir)"
cd /root
if ! wget -q -O plesk-installer https://autoinstall.plesk.com/one-click-installer; then
  die "Installer indirilemedi"
fi
chmod +x plesk-installer

# Tam cikti /var/log/plesk-oneclick.log'a yazilir
if ! ./plesk-installer >/var/log/plesk-oneclick.log 2>&1; then
  log "Kurulum hata verdi, log son satirlari:"
  tail -40 /var/log/plesk-oneclick.log
  die "Plesk kurulumu basarisiz (bkz. /var/log/plesk-oneclick.log)"
fi

command -v plesk >/dev/null 2>&1 || die "plesk komutu bulunamadi, kurulum tamamlanmamis"

log "Kurulum tamam: $(plesk version | awk -F': *' '/Product version/{print $2}')"

# Panelin dinledigini dogrula
for i in $(seq 1 30); do
  if curl -sk -o /dev/null --max-time 5 https://127.0.0.1:8443/; then
    log "Panel 8443'te yanit veriyor"
    break
  fi
  sleep 5
done

log "Lisans durumu:"
plesk bin license --check-installed-license >/dev/null 2>&1 \
  && log "  gecerli lisans var" \
  || log "  lisans yok/gecersiz - panelden deneme lisansi alinabilir"

log "Bitti. Panel: https://127.0.0.1:PORT  (giris linki icin: plesk login)"
