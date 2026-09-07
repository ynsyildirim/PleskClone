#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-transport.sh — local/remote soyutlaması
#
# Tek bir kod yolu ile hem aynı sunucuda hem farklı sunucuda çalışabilmek için
# hedef taraftaki tüm işlemler "agent" üzerinden çağrılır:
# TRANSPORT=local   -> agent aynı makinede bash ile çalışır
# TRANSPORT=remote  -> agent ssh üzerinden hedef sunucuda çalışır
#
# Böylece local ve remote akışları arasında hiçbir mantık farkı kalmaz.
# ---------------------------------------------------------------------------

TRANSPORT="${TRANSPORT:-local}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_KEY="${REMOTE_KEY:-}"

AGENT_DIR=""          # agent'ın hedef sunucudaki dizini
AGENT_PATH=""         # agent script'inin hedef sunucudaki tam yolu
SSH_CTL=""            # ControlMaster soket yolu
declare -a SSH_OPTS=()

is_remote() { [[ "$TRANSPORT" == "remote" ]]; }

remote_label() {
  if is_remote; then printf '%s@%s:%s' "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT"
  else printf 'localhost'; fi
}

# ---- ssh kurulumu ----
transport_init() {
  init_tmp
  if ! is_remote; then
    debug "transport: local"
    return 0
  fi

  require_cmd ssh rsync
  # Soket yolu boşluk içermemeli: rsync -e dizgisini kabuk gibi ayrıştırmaz.
  SSH_CTL="/tmp/plesk-clone-ssh-$$-%C"
  SSH_OPTS=(
    -p "$REMOTE_PORT"
    -o ConnectTimeout=15
    -o ServerAliveInterval=30
    -o ControlMaster=auto
    -o ControlPersist=15m
    -o "ControlPath=$SSH_CTL"
  )
  [[ -n "$REMOTE_KEY" ]] && SSH_OPTS+=(-i "$REMOTE_KEY")

  info "SSH bağlantısı kuruluyor: $(remote_label)"
  if ! ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" true; then
    die "SSH bağlantısı kurulamadı: $(remote_label) (anahtar tabanlı kimlik doğrulama önerilir)"
  fi
  ok "SSH bağlantısı hazır (multiplexing aktif — tek kimlik doğrulama)"
}

transport_close() {
  if is_remote && [[ -n "$SSH_CTL" ]]; then
    ssh "${SSH_OPTS[@]}" -O exit "${REMOTE_USER}@${REMOTE_HOST}" >/dev/null 2>&1 || true
  fi
}

# rsync'in -e parametresi için: rsync bu dizgiyi kabuk gibi ayrıştırmaz,
# sadece boşluklardan böler. Bu yüzden tırnak KULLANILMAZ.
ssh_cmd_string() { printf 'ssh %s' "${SSH_OPTS[*]}"; }

# ---- uzak/yerel komut çalıştırma ----
_rt_exec_impl() {
  local nostdin="$1" cmd="$2"
  if is_remote; then
    if (( nostdin )); then
      ssh -n "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -c $(shq "$cmd")"
    else
      ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -c $(shq "$cmd")"
    fi
  else
    if (( nostdin )); then bash -c "$cmd" </dev/null
    else bash -c "$cmd"; fi
  fi
}

# rt_exec — stdin KAPALI çalıştırır.
# Kritik: `while read ... done <<<"$liste"` döngüleri içinden çağrıldığında
# ssh/bash döngünün girdisini yutmasın diye stdin /dev/null'a bağlanır.
rt_exec() { _rt_exec_impl 1 "$1"; }

# rt_exec_stdin — stdin'i hedefe akıtır (mysqldump | ... | agent db-import gibi)
rt_exec_stdin() { _rt_exec_impl 0 "$1"; }

# ---- dosya aktarımı ----
# rt_put <yerel-dosya> <hedef-yol>
rt_put() {
  local src="$1" dst="$2"
  if is_remote; then
    rsync -q -e "$(ssh_cmd_string)" "$src" "${REMOTE_USER}@${REMOTE_HOST}:$dst"
  else
    [[ "$src" == "$dst" ]] || cp -a "$src" "$dst"
  fi
}

# rt_get <hedefteki-dosya> <yerel-yol>
rt_get() {
  local src="$1" dst="$2"
  if is_remote; then
    rsync -q -e "$(ssh_cmd_string)" "${REMOTE_USER}@${REMOTE_HOST}:$src" "$dst"
  else
    [[ "$src" == "$dst" ]] || cp -a "$src" "$dst"
  fi
}

# rsync yetenek tespiti: eski sürümlerde -A/-X/-H yok, körlemesine kullanılamaz
RSYNC_BASE_FLAGS=""
_rsync_base_flags() {
  if [[ -z "$RSYNC_BASE_FLAGS" ]]; then
    local help; help="$(rsync --help 2>&1 || true)"
    local f="-a"
    [[ "$help" == *"--hard-links"* ]] && f+="H"
    [[ "$help" == *"--acls"* ]]       && f+="A"
    [[ "$help" == *"--xattrs"* ]]     && f+="X"
    RSYNC_BASE_FLAGS="$f"
    debug "rsync bayrakları: $RSYNC_BASE_FLAGS"
  fi
  printf '%s' "$RSYNC_BASE_FLAGS"
}

# rt_rsync_dir <yerel-kaynak-dizin/> <hedef-dizin/> [ekstra rsync argümanları...]
rt_rsync_dir() {
  local src="$1" dst="$2"; shift 2
  local -a extra=("$@")
  if (( DRYRUN )); then
    _log "${C_DIM}${LOG_PREFIX}[DRY  ] rsync ${extra[*]} $src -> $(is_remote && printf '%s:' "$REMOTE_HOST")$dst${C_RST}"
    return 0
  fi
  local base; base="$(_rsync_base_flags)"
  if is_remote; then
    rsync "$base" --numeric-ids "${extra[@]}" -e "$(ssh_cmd_string)" \
      "$src" "${REMOTE_USER}@${REMOTE_HOST}:$dst"
  else
    rsync "$base" "${extra[@]}" "$src" "$dst"
  fi
}

# ---- agent dağıtımı ----
# Çalışan script'in tek dosyalık bir kopyasını üretir (lib/ varsa birleştirilir).
build_self_bundle() {
  local out="$1"
  if [[ -n "${PLESK_CLONE_BUNDLED:-}" ]] || [[ ! -d "$SELF_DIR/lib" ]]; then
    cp -f "$SELF_PATH" "$out"
  else
    bundle_inline "$SELF_PATH" "$SELF_DIR/lib" "$out"
  fi
  chmod 700 "$out"
}

# Tek dosyalık kendi kendine yeten kopya üretir (lib/ içeriği gövdeye gömülür)
bundle_inline() {
  local entry="$1" libdir="$2" out="$3" f
  : >"$out"
  awk '/^# @@LIB_INJECT@@/{exit} {print}' "$entry" >>"$out"
  printf '\nPLESK_CLONE_BUNDLED=1\n' >>"$out"
  for f in "$libdir"/*.sh; do
    printf '\n# ===== %s =====\n' "$(basename "$f")" >>"$out"
    sed '1{/^#!/d;}' "$f" >>"$out"
  done
  awk 'f{print} /^# @@LIB_INJECT_END@@/{f=1}' "$entry" >>"$out"
}

# Agent'ı hedef sunucuya kurar ve bağlam dosyasını gönderir
agent_deploy() {
  local ctx_file="$1"
  init_tmp
  local bundle="$CLONE_TMP/plesk-clone-bundle.sh"
  build_self_bundle "$bundle"

  if is_remote; then
    AGENT_DIR="/tmp/plesk-clone-agent-$$-$(rand_hex 3)"
    rt_exec "mkdir -p $(shq "$AGENT_DIR") && chmod 700 $(shq "$AGENT_DIR")"
    rt_put "$bundle" "$AGENT_DIR/plesk-clone.sh"
    rt_put "$ctx_file" "$AGENT_DIR/ctx.env"
    rt_exec "chmod 700 $(shq "$AGENT_DIR/plesk-clone.sh"); chmod 600 $(shq "$AGENT_DIR/ctx.env")"
  else
    AGENT_DIR="$CLONE_TMP/agent"
    mkdir -p "$AGENT_DIR"
    cp -f "$bundle" "$AGENT_DIR/plesk-clone.sh"
    cp -f "$ctx_file" "$AGENT_DIR/ctx.env"
  fi
  AGENT_PATH="$AGENT_DIR/plesk-clone.sh"
  debug "agent kuruldu: $(remote_label):$AGENT_PATH"
}

agent_cleanup() {
  if is_remote && [[ -n "$AGENT_DIR" ]]; then
    rt_exec "rm -rf $(shq "$AGENT_DIR")" >/dev/null 2>&1 || true
  fi
}

# Bağlam dosyasını güncelleyip hedefe yeniden gönderir
agent_push_ctx() {
  local ctx_file="$1"
  [[ -n "$AGENT_DIR" ]] || return 0
  if is_remote; then
    rt_put "$ctx_file" "$AGENT_DIR/ctx.env"
  else
    cp -f "$ctx_file" "$AGENT_DIR/ctx.env"
  fi
}

# ---- agent çağrıları ----
_agent_cmd() {
  local op="$1"; shift
  local cmd="bash $(shq "$AGENT_PATH") --agent $(shq "$op")"
  [[ $# -gt 0 ]] && cmd+=" $(shq_cmd "$@")"
  printf '%s' "$cmd"
}

# agent <op> [args...] — hedef sunucuda bir işlem çalıştırır (stdin kapalı)
agent() {
  debug "agent[$1] ${*:2}"
  rt_exec "$(_agent_cmd "$@")"
}

# agent_stdin <op> [args...] — stdin'i hedefe akıtır (DB import, crontab)
agent_stdin() {
  debug "agent-stdin[$1] ${*:2}"
  rt_exec_stdin "$(_agent_cmd "$@")"
}

# agent_soft — hata durumunda uyarı verip devam eder
agent_soft() {
  local desc="$1"; shift
  if ! agent "$@"; then
    warn "$desc"
    return 1
  fi
  return 0
}
