#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test surucusu (host tarafi)
#
#   ./run.sh all [sim|real]     ortami kur + tohumla + tum senaryolari calistir
#   ./run.sh up  [sim|real]     konteynerleri ayaga kaldir ve hazirla
#   ./run.sh seed               kaynak dugumu demo veriyle doldur
#   ./run.sh test               senaryolari calistir
#   ./run.sh sync               kaynak kod degisikligini dugumlere yeniden kur
#   ./run.sh ui                 (real) panel giris linkleri
#   ./run.sh sh a|b             dugume kabuk
#   ./run.sh logs               ozet + log listesi
#   ./run.sh down               kaldir (volume dahil)
#
# Profiller:
#   sim  (varsayilan) native mimari, lisans gerektirmez, hizli
#   real gercek Plesk Obsidian + panel UI (on kosullar icin docker-compose.yml)
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE="${PROFILE:-sim}"
case "${2:-}" in sim|real) PROFILE="$2" ;; esac

if [[ "$PROFILE" == "real" ]]; then A=plesk-a; B=plesk-b; BIP=172.28.0.21
else                                A=node-a;  B=node-b;  BIP=172.28.0.11; fi

if [[ -t 1 ]]; then C_RST=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'
else C_RST=""; C_B=""; C_G=""; C_Y=""; C_R=""; fi
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_RST"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[UYARI]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[HATA]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

dc() { docker compose --profile "$PROFILE" "$@"; }

need_binfmt() {
  [[ "$PROFILE" == "real" ]] || return 0
  if ! docker run --rm --privileged tonistiigi/binfmt:latest 2>/dev/null | grep -q qemu-x86_64; then
    warn "amd64 emulasyonu kayitli degil, kuruluyor..."
    docker run --privileged --rm tonistiigi/binfmt --install amd64 >/dev/null 2>&1 \
      || die "binfmt kurulamadi."
    ok "qemu-x86_64 kuruldu"
  fi
}

db_ready() {
  [[ "$(docker exec "$1" plesk db -Ne "SELECT 1" 2>/dev/null | tr -d '[:space:]')" == "1" ]]
}
node_ready() {
  if [[ "$PROFILE" == "real" ]]; then db_ready "$1"
  else docker exec "$1" test -f /run/node-ready 2>/dev/null && db_ready "$1"; fi
}

wait_nodes() {
  local tries="${1:-120}" i
  printf 'Dugumler hazir olmasi bekleniyor: '
  for (( i=1; i<=tries; i++ )); do
    if node_ready "$A" && node_ready "$B"; then printf ' hazir\n'; return 0; fi
    printf '.'; sleep 10
  done
  printf '\n'; return 1
}

cmd_up() {
  need_binfmt
  head1 "Konteynerler ayaga kaldiriliyor (profil: $PROFILE)"
  mkdir -p logs shared
  dc up -d --build || die "compose up basarisiz"
  wait_nodes 120 || die "dugumler hazir olmadi"
  cmd_prepare
}

cmd_prepare() {
  head1 "Dugumler hazirlaniyor"
  ./prepare.sh "$A" "$B" "$BIP" || die "hazirlik basarisiz"
}

cmd_sync() {
  head1 "Kaynak kod dugumlere yeniden kuruluyor"
  local c
  for c in "$A" "$B"; do
    docker exec "$c" bash -c 'PLESKCLONE_SRC=/opt/pleskclone-src bash /opt/pleskclone-src/install.sh --quiet' \
      || die "$c: yeniden kurulum basarisiz"
    ok "$c: $(docker exec "$c" pleskclone --version)"
  done
}

cmd_seed() {
  head1 "Kaynak dugum tohumlaniyor"
  docker exec "$A" bash /opt/pleskclone-src/test/seed.sh 2>&1 | tee logs/00-seed.log | tail -20
  return "${PIPESTATUS[0]}"
}

cmd_test() {
  head1 "Senaryolar calistiriliyor"
  docker exec "$A" bash /opt/pleskclone-src/test/scenarios.sh 2>&1 | tee logs/99-run.log | tail -35
  return "${PIPESTATUS[0]}"
}

cmd_ui() {
  head1 "Plesk panel erisimi"
  if [[ "$PROFILE" != "real" ]]; then
    warn "Panel UI yalnizca 'real' profilinde vardir: ./run.sh up real"
    return 0
  fi
  say "plesk-a  https://localhost:8443   (kaynak sunucu)"
  say "plesk-b  https://localhost:8444   (hedef sunucu)"
  say ""
  local pair name port link
  for pair in "plesk-a:8443" "plesk-b:8444"; do
    name="${pair%%:*}"; port="${pair##*:}"
    link="$(docker exec "$name" plesk login 2>/dev/null | grep -o 'https://[^ ]*' | head -1)"
    if [[ -n "$link" ]]; then
      printf '  %-8s %s\n' "$name" "$(printf '%s' "$link" | sed -E "s#https://[^/]+#https://localhost:${port}#")"
    else
      printf '  %-8s (giris linki alinamadi - lisans/panel servisi kontrol edin)\n' "$name"
    fi
  done
}

cmd_sh()  { docker exec -it "$( [[ "${2:-a}" == b ]] && echo "$B" || echo "$A" )" bash; }

cmd_logs(){
  head1 "Test loglari"
  ls -1 logs/ 2>/dev/null | sed 's/^/  logs\//'
  [[ -f logs/SUMMARY.txt ]] && { say ""; cat logs/SUMMARY.txt; }
}

cmd_down(){ head1 "Kaldiriliyor"; dc down -v; ok "temizlendi"; }

case "${1:-all}" in
  up)      cmd_up ;;
  prepare) cmd_prepare ;;
  sync)    cmd_sync ;;
  seed)    cmd_seed ;;
  test)    cmd_test ;;
  all)     cmd_up && cmd_seed && cmd_test ;;
  ui)      cmd_ui ;;
  sh)      cmd_sh "$@" ;;
  logs)    cmd_logs ;;
  down)    cmd_down ;;
  *)       die "Bilinmeyen komut: $1" ;;
esac
