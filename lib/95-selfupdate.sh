#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 95-selfupdate.sh - kurulum bilgisi, guncelleme ve kaldirma
#
# pleskclone --update    : depodaki son surumu ceker, build eder, yerine koyar
# pleskclone --where     : kurulum dizini ve surum bilgisi
# pleskclone --uninstall : kurulumu kaldirir
# ---------------------------------------------------------------------------

PLESKCLONE_REPO="${PLESKCLONE_REPO:-ynsyildirim/PleskClone}"
PLESKCLONE_REF="${PLESKCLONE_REF:-main}"

# Kurulum kokunu bul: once launcher'in verdigi degisken, sonra script'in yeri
install_home() {
  if [[ -n "${PLESKCLONE_HOME:-}" && -d "$PLESKCLONE_HOME" ]]; then
    printf '%s' "$PLESKCLONE_HOME"
  else
    printf '%s' "$SELF_DIR"
  fi
}

# Bu dizin install.sh tarafından yönetilen bir kurulum mu?
#
# Kritik: install_home() kurulu değilken SELF_DIR'e düşer. Bu kontrol olmadan
# depo klasöründen çalıştırılan --uninstall, kullanıcının git checkout'unu
# (commit edilmemiş çalışması dahil) siler; --update ise üzerine yazar.
is_managed_install() { [[ -f "$(install_home)/.install-info" ]]; }

require_managed_install() {
  local what="$1" home; home="$(install_home)"
  is_managed_install && return 0
  err "'$what' yalnızca install.sh ile kurulmuş bir dizinde çalışır."
  err "Bu dizin yönetilen bir kurulum değil: $home"
  err "(.install-info bulunamadı — burası muhtemelen depo çalışma kopyanız.)"
  info "Kurmak için:  bash $home/install.sh"
  die "İşlem yapılmadı."
}

install_info_get() {
  local key="$1" f; f="$(install_home)/.install-info"
  [[ -f "$f" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}' "$f"
}

show_where() {
  local home; home="$(install_home)"
  bold "Plesk Clone kurulum bilgisi"
  printf '  Surum        : %s\n' "$PLESK_CLONE_VERSION"
  printf '  Kurulum yeri : %s\n' "$home"
  printf '  Giris betigi : %s\n' "$SELF_PATH"
  if [[ -f "$home/.install-info" ]]; then
    printf '  Depo         : %s\n' "$(install_info_get repo || printf '?')"
    printf '  Dal/etiket   : %s\n' "$(install_info_get ref || printf '?')"
    printf '  Kurulum tar. : %s\n' "$(install_info_get installed_at || printf '?')"
    printf '  Komut        : %s/pleskclone\n' "$(install_info_get bin || printf '?')"
  else
    printf '  Not          : install.sh ile kurulmamis (depo dizininden calisiyor)\n'
  fi
  printf '  Bundled      : %s\n' "$( [[ -n "${PLESK_CLONE_BUNDLED:-}" ]] && printf 'evet (tek dosya)' || printf 'hayir (lib/ ile)' )"
}

do_uninstall() {
  require_managed_install "--uninstall"
  local home; home="$(install_home)"
  local bin; bin="$(install_info_get bin 2>/dev/null || printf '/usr/local/bin')"
  warn "Kaldirilacak: $home ve $bin/pleskclone"
  confirm "Devam edilsin mi?" "h" || die "Iptal edildi."
  if [[ -f "$home/install.sh" ]]; then
    bash "$home/install.sh" --uninstall --dir "$home" --bin-dir "$bin"
  else
    rm -f "$bin/pleskclone"
    rm -rf "$home"
    ok "Kaldirildi."
  fi
}

do_update() {
  require_managed_install "--update"
  local home; home="$(install_home)"
  local bin;  bin="$(install_info_get bin 2>/dev/null || printf '')"
  [[ -z "$bin" ]] && bin="$(dirname "$(command -v pleskclone 2>/dev/null || printf '/usr/local/bin/pleskclone')")"
  local repo ref
  repo="$(install_info_get repo 2>/dev/null || printf '%s' "$PLESKCLONE_REPO")"
  ref="${PLESKCLONE_REF_OVERRIDE:-$(install_info_get ref 2>/dev/null || printf '%s' "$PLESKCLONE_REF")}"

  bold "Plesk Clone guncelleme"
  info "Mevcut surum : $PLESK_CLONE_VERSION"
  info "Depo         : ${repo}@${ref}"
  info "Kurulum yeri : $home"

  [[ -w "$home" || "$(id -u)" == "0" ]] \
    || die "Kurulum dizinine yazma izni yok: $home (root olarak calistirin)"

  # Kurulum betigi elimizde varsa onu kullan; yoksa depodan cek
  if [[ -f "$home/install.sh" ]]; then
    info "install.sh calistiriliyor..."
    bash "$home/install.sh" --dir "$home" --bin-dir "$bin" --repo "$repo" --ref "$ref" \
      || die "Guncelleme basarisiz."
  else
    local url="https://raw.githubusercontent.com/${repo}/${ref}/install.sh"
    info "Kurulum betigi indiriliyor: $url"
    if has_cmd curl; then
      curl -fsSL "$url" | bash -s -- --dir "$home" --bin-dir "$bin" --repo "$repo" --ref "$ref" \
        || die "Guncelleme basarisiz."
    elif has_cmd wget; then
      wget -qO- "$url" | bash -s -- --dir "$home" --bin-dir "$bin" --repo "$repo" --ref "$ref" \
        || die "Guncelleme basarisiz."
    else
      die "curl veya wget gerekli."
    fi
  fi

  local newver
  newver="$(awk -F'\"' '/^PLESK_CLONE_VERSION=/{print $2; exit}' "$home/plesk_clone.sh" 2>/dev/null || true)"
  if [[ -n "$newver" && "$newver" != "$PLESK_CLONE_VERSION" ]]; then
    ok "Guncellendi: $PLESK_CLONE_VERSION -> $newver"
  else
    ok "Zaten guncel (surum $PLESK_CLONE_VERSION)."
  fi
}
