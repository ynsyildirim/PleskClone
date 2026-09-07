#!/usr/bin/env bash
# ===========================================================================
# Plesk Clone - kurulum betigi
#
# Tek satirla kurulum:
#   curl -fsSL https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/install.sh | bash
#
# Yaptigi is:
#   1. Depoyu indirir (tarball)
#   2. build.sh ile tek dosyalik surumu uretir
#   3. /usr/local/bin/pleskclone komutunu kurar
#   4. Surum bilgisini kaydeder (pleskclone --update icin)
#
# Ortam degiskenleri:
#   PLESKCLONE_HOME   Kurulum dizini (varsayilan: /usr/local/lib/pleskclone)
#   PLESKCLONE_BIN    Komut dizini   (varsayilan: /usr/local/bin)
#   PLESKCLONE_REPO   owner/repo     (varsayilan: ynsyildirim/PleskClone)
#   PLESKCLONE_REF    dal veya etiket (varsayilan: main)
#   PLESKCLONE_SRC    yerel kaynak dizin/tarball (internet olmadan kurulum)
#
# Gecici dizine kurmak icin:
#   PLESKCLONE_HOME=/tmp/pleskclone curl -fsSL .../install.sh | bash
# ===========================================================================
set -euo pipefail

PLESKCLONE_REPO="${PLESKCLONE_REPO:-ynsyildirim/PleskClone}"
PLESKCLONE_REF="${PLESKCLONE_REF:-main}"
PLESKCLONE_SRC="${PLESKCLONE_SRC:-}"
FROM_DIR=""
CLEANUP_DIR=""
ACTION="install"
QUIET=0

if [[ -t 2 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RST=""; C_B=""; C_GRN=""; C_YLW=""; C_RED=""
fi
say()  { (( QUIET )) || printf '%s\n' "$*" >&2; }
ok()   { (( QUIET )) || printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[UYARI]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[HATA]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Plesk Clone kurulum betigi

  --dir DIR        Kurulum dizini (varsayilan: /usr/local/lib/pleskclone)
  --bin-dir DIR    Komut dizini (varsayilan: /usr/local/bin)
  --repo O/R       GitHub deposu (varsayilan: $PLESKCLONE_REPO)
  --ref REF        Dal/etiket (varsayilan: $PLESKCLONE_REF)
  --src PATH       Yerel kaynak dizin veya .tar.gz (internetsiz kurulum)
  --from-dir DIR   Ic kullanim: hazir kaynaktan kurulumu tamamla
  --cleanup-dir D  Ic kullanim: bitince silinecek gecici dizin
  --uninstall      Kurulumu kaldir
  --quiet          Sessiz
  -h, --help       Bu yardim
EOF
}

while (( $# )); do
  case "$1" in
    --dir)       PLESKCLONE_HOME="${2:-}"; shift 2 ;;
    --bin-dir)   PLESKCLONE_BIN="${2:-}"; shift 2 ;;
    --repo)      PLESKCLONE_REPO="${2:-}"; shift 2 ;;
    --ref)       PLESKCLONE_REF="${2:-}"; shift 2 ;;
    --src)       PLESKCLONE_SRC="${2:-}"; shift 2 ;;
    --from-dir)  FROM_DIR="${2:-}"; shift 2 ;;
    --cleanup-dir) CLEANUP_DIR="${2:-}"; shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --quiet)     QUIET=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "Bilinmeyen argüman: $1" ;;
  esac
done

# ---- kurulum hedefini belirle ----
pick_home() {
  [[ -n "${PLESKCLONE_HOME:-}" ]] && { printf '%s' "$PLESKCLONE_HOME"; return; }
  if [[ "$(id -u)" == "0" ]]; then printf '/usr/local/lib/pleskclone'
  elif [[ -w "$HOME" ]]; then printf '%s/.local/lib/pleskclone' "$HOME"
  else printf '/tmp/pleskclone'; fi
}
pick_bin() {
  [[ -n "${PLESKCLONE_BIN:-}" ]] && { printf '%s' "$PLESKCLONE_BIN"; return; }
  if [[ "$(id -u)" == "0" ]]; then printf '/usr/local/bin'
  else printf '%s/.local/bin' "$HOME"; fi
}
HOME_DIR="$(pick_home)"
BIN_DIR="$(pick_bin)"

# ---- kaldirma ----
if [[ "$ACTION" == "uninstall" ]]; then
  [[ -e "$BIN_DIR/pleskclone" ]] && rm -f "$BIN_DIR/pleskclone" && ok "Komut silindi: $BIN_DIR/pleskclone"
  if [[ -d "$HOME_DIR" ]]; then
    rm -rf "$HOME_DIR"; ok "Dizin silindi: $HOME_DIR"
  fi
  say "Kaldirma tamamlandi."
  exit 0
fi

# ---- 1. asama: kaynagi getir, sonra yeni surumun install.sh'ini calistir ----
if [[ -z "$FROM_DIR" ]]; then
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/pleskclone-install.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT

  if [[ -n "$PLESKCLONE_SRC" ]]; then
    if [[ -d "$PLESKCLONE_SRC" ]]; then
      say "Yerel dizinden kuruluyor: $PLESKCLONE_SRC"
      cp -a "$PLESKCLONE_SRC/." "$TMP/"
    elif [[ -f "$PLESKCLONE_SRC" ]]; then
      say "Yerel arsivden kuruluyor: $PLESKCLONE_SRC"
      tar -xzf "$PLESKCLONE_SRC" --strip-components=1 -C "$TMP" \
        || tar -xzf "$PLESKCLONE_SRC" -C "$TMP"
    else
      die "Kaynak bulunamadi: $PLESKCLONE_SRC"
    fi
  else
    URL="https://codeload.github.com/${PLESKCLONE_REPO}/tar.gz/refs/heads/${PLESKCLONE_REF}"
    say "Indiriliyor: ${PLESKCLONE_REPO}@${PLESKCLONE_REF}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$URL" | tar -xz --strip-components=1 -C "$TMP" \
        || die "Indirme basarisiz: $URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- "$URL" | tar -xz --strip-components=1 -C "$TMP" \
        || die "Indirme basarisiz: $URL"
    else
      die "curl veya wget gerekli."
    fi
  fi

  [[ -f "$TMP/plesk_clone.sh" && -d "$TMP/lib" ]] \
    || die "Indirilen arsiv beklenen icerikte degil (plesk_clone.sh + lib/ yok)."

  # Yeni surumun kendi kurulum mantigini kullan.
  # NOT: exec surec goruntusunu degistirir, bu yuzden yukaridaki EXIT trap'i
  # ASLA calismaz. Gecici dizini 2. asamaya bildirip orada sildiriyoruz;
  # aksi halde her kurulum/guncelleme /tmp altinda tam bir depo kopyasi birakir.
  trap - EXIT
  exec bash "$TMP/install.sh" --from-dir "$TMP" --cleanup-dir "$TMP" \
       --dir "$HOME_DIR" --bin-dir "$BIN_DIR" \
       --repo "$PLESKCLONE_REPO" --ref "$PLESKCLONE_REF" \
       $( (( QUIET )) && printf -- '--quiet' )
fi

# ---- 2. asama: yerlestirme ----
# 1. asamanin gecici dizinini biz temizliyoruz (orada trap exec ile kayboldu)
[[ -n "$CLEANUP_DIR" ]] && trap 'rm -rf "$CLEANUP_DIR"' EXIT

SRC="$FROM_DIR"
[[ -f "$SRC/plesk_clone.sh" && -d "$SRC/lib" ]] || die "Gecersiz kaynak dizin: $SRC"

VERSION="$(awk -F'"' '/^PLESK_CLONE_VERSION=/{print $2; exit}' "$SRC/plesk_clone.sh")"
[[ -z "$VERSION" ]] && VERSION="bilinmiyor"

OLD_VERSION=""
[[ -f "$HOME_DIR/.install-info" ]] && \
  OLD_VERSION="$(awk -F= '/^version=/{print $2; exit}' "$HOME_DIR/.install-info")"

say "Kurulum dizini : $HOME_DIR"
say "Komut dizini   : $BIN_DIR"
say "Surum          : ${OLD_VERSION:+$OLD_VERSION -> }$VERSION"

mkdir -p "$(dirname "$HOME_DIR")" || die "Dizin olusturulamadi: $(dirname "$HOME_DIR")"
mkdir -p "$BIN_DIR"               || die "Dizin olusturulamadi: $BIN_DIR"

# Eski kurulumu yedekle, yeniyi atomik yerlestir
STAGE="${HOME_DIR}.new.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$SRC/plesk_clone.sh" "$SRC/lib" "$STAGE/"
[[ -f "$SRC/build.sh" ]]   && cp -a "$SRC/build.sh"   "$STAGE/"
[[ -f "$SRC/install.sh" ]] && cp -a "$SRC/install.sh" "$STAGE/"
[[ -f "$SRC/README.md" ]]  && cp -a "$SRC/README.md"  "$STAGE/"
chmod +x "$STAGE/plesk_clone.sh"
[[ -f "$STAGE/build.sh" ]] && chmod +x "$STAGE/build.sh"

# Tek dosyalik surumu uret (build otomatik)
if [[ -f "$STAGE/build.sh" ]]; then
  if bash "$STAGE/build.sh" "$STAGE/dist/plesk-clone.sh" >/dev/null 2>&1; then
    ok "Tek dosyalik surum uretildi: dist/plesk-clone.sh"
  else
    warn "build.sh calistirilamadi; lib/ uzerinden calisilacak."
  fi
fi

bash -n "$STAGE/plesk_clone.sh" || die "Sozdizimi hatasi: plesk_clone.sh"

# Takas: eski kurulumu yedekle, yeniyi yerleştir.
# Yerleştirme başarısız olursa eski kurulum GERİ ALINIR; aksi halde disk dolu
# gibi bir durumda kurulum dizini tamamen kaybolur ve pleskclone komutu
# çalışmayan bir yola işaret eder (--update ile de kurtarılamaz).
BACKED_UP=0
if [[ -d "$HOME_DIR" ]]; then
  rm -rf "${HOME_DIR}.bak"
  mv "$HOME_DIR" "${HOME_DIR}.bak" || die "Eski kurulum yedeklenemedi: $HOME_DIR"
  BACKED_UP=1
fi
if ! mv "$STAGE" "$HOME_DIR"; then
  warn "Yeni sürüm yerleştirilemedi."
  rm -rf "$STAGE"
  if (( BACKED_UP )); then
    mv "${HOME_DIR}.bak" "$HOME_DIR" && ok "Önceki sürüm geri alındı: $HOME_DIR"
  fi
  die "Güncelleme başarısız; mevcut kurulum korundu."
fi
rm -rf "${HOME_DIR}.bak"

# Log dizini kurulum dizininden bagimsiz olsun diye varsayilan birakilmaz;
# calisma dizinindeki ./logs kullanilir.

cat >"$HOME_DIR/.install-info" <<EOF
version=$VERSION
repo=$PLESKCLONE_REPO
ref=$PLESKCLONE_REF
installed_at=$(date '+%Y-%m-%d %H:%M:%S')
home=$HOME_DIR
bin=$BIN_DIR
EOF
chmod 600 "$HOME_DIR/.install-info"

# ---- komut (alias) ----
cat >"$BIN_DIR/pleskclone" <<EOF
#!/usr/bin/env bash
# pleskclone - Plesk Clone / Migrate baslatici (install.sh tarafindan uretildi)
export PLESKCLONE_HOME="$HOME_DIR"
export PLESKCLONE_BIN="$BIN_DIR"
exec bash "$HOME_DIR/plesk_clone.sh" "\$@"
EOF
chmod 755 "$BIN_DIR/pleskclone"
ok "Komut kuruldu: $BIN_DIR/pleskclone"

# PATH kontrolu - degilse alias oner/ekle
case ":${PATH}:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR PATH icinde degil."
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [[ -f "$rc" ]] || continue
      grep -q "alias pleskclone=" "$rc" 2>/dev/null && continue
      printf '\n# Plesk Clone\nalias pleskclone=%s\n' "'$BIN_DIR/pleskclone'" >>"$rc"
      ok "Alias eklendi: $rc"
    done
    say "Yeni kabuk acin veya: export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

say ""
ok "Kurulum tamam. Surum: $VERSION"
say ""
say "  ${C_B}pleskclone --help${C_RST}      Kullanim"
say "  ${C_B}pleskclone --update${C_RST}    Depodaki son surume guncelle"
say "  ${C_B}pleskclone --where${C_RST}     Kurulum bilgisi"
say ""
