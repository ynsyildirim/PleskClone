#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 50-git.sh — Plesk Git Extension klonlama
#
# Orijinal script Git ayarlarını tek bir "INSERT ... SELECT" ile kopyalıyordu;
# bu yalnızca aynı sunucuda çalışır. Burada kaynak SQLite kayıtları taşınabilir
# bir dosyaya aktarılır, hedefte yeniden kurulur. Böylece local ve remote akış
# aynı kodu kullanır.
# ---------------------------------------------------------------------------

GIT_DB_PATH="${GIT_DB_PATH:-/usr/local/psa/var/modules/git/git_db.db}"
GIT_KEYS_DIR="${GIT_KEYS_DIR:-/usr/local/psa/var/modules/git/keys}"

# hex -> düz metin (xxd/base64 bağımlılığı olmadan)
unhex() {
  local h="$1"
  [[ -z "$h" ]] && return 0
  printf '%b' "$(printf '%s' "$h" | sed 's/../\\x&/g')"
}

# Git 2.35.2+ "dubious ownership" koruması: root, başka bir kullanıcıya ait
# depoda çalışırken hata verir. Plesk depoları domain kullanıcısına aittir.
#
# safe.directory yalnizca "korumali" konfigurasyondan okunur: system, global ve
# komut satiri -c. Ortam degiskeni (GIT_CONFIG_*) bilerek yok sayilir. Burada
# yaptigimiz islemler (config/reset/clean) tek surecte kaldigi icin -c yeterli.
git_at() {
  local repo="$1"; shift
  git -c safe.directory="$repo" -c safe.directory='*' --git-dir="$repo" "$@"
}

git_sync() {
  local git_src="$VHOST_SRC/git"

  if [[ ! -d "$git_src" ]]; then
    warn "Kaynakta Plesk Git dizini yok: $git_src"
    return 0
  fi

  # 1) Git dosyalarını (bare repo'lar dahil) kopyala
  info "Git depoları kopyalanıyor: $git_src/ -> $(remote_label):$VHOST_TGT/git/"
  agent ensure-dir "$VHOST_TGT/git" || true
  rt_rsync_dir "$git_src/" "$VHOST_TGT/git/" \
    || { warn "Git dosyaları kopyalanamadı"; return 1; }

  local repo_count
  repo_count="$(find "$git_src" -maxdepth 2 -name '*.git' -type d 2>/dev/null | grep -c . || true)"
  info "Kaynakta $repo_count Git deposu bulundu"

  # 2) Git Extension SQLite kayıtlarını dışa aktar
  if [[ ! -f "$GIT_DB_PATH" ]]; then
    warn "Kaynakta Git Extension veritabanı yok: $GIT_DB_PATH (sadece dosyalar kopyalandı)"
    agent git-finalize || true
    return 0
  fi
  if ! has_cmd sqlite3; then
    warn "sqlite3 komutu yok; Git Extension ayarları aktarılamıyor (dosyalar kopyalandı)"
    agent git-finalize || true
    return 0
  fi

  local src_id; src_id="$(domain_id "$SOURCE")"
  [[ -z "$src_id" ]] && { warn "Kaynak domain ID bulunamadı; Git ayarları atlanıyor"; return 1; }

  init_tmp
  local export_file="$CLONE_TMP/git_repos.psv"
  sqlite3 "$GIT_DB_PATH" "
    SELECT hex(ifnull(name,''))                       || '|' ||
           hex(ifnull(type,''))                       || '|' ||
           hex(ifnull(deploymentMode,''))             || '|' ||
           hex(ifnull(branch,''))                     || '|' ||
           hex(ifnull(deploymentPath,''))             || '|' ||
           hex(ifnull(fetchUrl,''))                   || '|' ||
           hex(ifnull(skipSslVerification,0))         || '|' ||
           hex(ifnull(postDeploymentActionsEnabled,0))|| '|' ||
           hex(ifnull(deploymentsCounter,0))          || '|' ||
           hex(ifnull(postDeploymentActions,''))
    FROM Repositories WHERE domainId = $src_id;
  " >"$export_file" 2>/dev/null || true

  local rows; rows="$(grep -c . "$export_file" 2>/dev/null || printf '0')"
  if [[ "$rows" == "0" ]]; then
    info "Git Extension'da kayıtlı depo yok; sadece dosyalar taşındı"
    agent git-finalize || true
    return 0
  fi
  info "$rows Git deposu kaydı hedefe aktarılıyor"

  local remote_file="$AGENT_DIR/git_repos.psv"
  rt_put "$export_file" "$remote_file"
  agent git-import "$remote_file" || { warn "Git Extension ayarları aktarılamadı"; return 1; }
  ok "Git entegrasyonu tamamlandı"
}

# ---- agent tarafı ----

# Repo adı normalizasyonu: "app.git" -> "app"
_git_repo_basename() {
  local n="$1"
  printf '%s' "${n%.git}"
}

_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif has_cmd uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    printf '%s-%s-4%s-a%s-%s' "$(rand_hex 4)" "$(rand_hex 2)" \
      "$(rand_hex 2 | cut -c2-)" "$(rand_hex 2 | cut -c2-)" "$(rand_hex 6)"
  fi
}

agent_git_import() {
  local file="$1"
  [[ -f "$file" ]] || { err "Git kayıt dosyası yok: $file"; return 1; }
  [[ -f "$GIT_DB_PATH" ]] || { err "Git Extension veritabanı yok: $GIT_DB_PATH"; return 1; }
  has_cmd sqlite3 || { err "sqlite3 komutu yok"; return 1; }

  local tgt_id tgt_guid
  tgt_id="$(domain_id "$TARGET")"
  tgt_guid="$(domain_guid "$TARGET")"
  [[ -z "$tgt_id" ]] && { err "Domain ID bulunamadı: $TARGET"; return 1; }

  local imported=0 line
  while IFS='|' read -r h_name h_type h_mode h_branch h_path h_fetch h_skip h_actions_en h_counter h_actions; do
    [[ -z "$h_name" ]] && continue
    local name type mode branch dpath fetch skipssl actions_en counter actions
    name="$(unhex "$h_name")";           type="$(unhex "$h_type")"
    mode="$(unhex "$h_mode")";           branch="$(unhex "$h_branch")"
    dpath="$(unhex "$h_path")";          fetch="$(unhex "$h_fetch")"
    skipssl="$(unhex "$h_skip")";        actions_en="$(unhex "$h_actions_en")"
    counter="$(unhex "$h_counter")";     actions="$(unhex "$h_actions")"

    name="$(_git_repo_basename "$name")"
    # Yol ve aksiyonlardaki kaynak domain adını hedefe çevir
    if [[ "$SOURCE" != "$TARGET" ]]; then
      dpath="${dpath//$SOURCE/$TARGET}"
      actions="${actions//$SOURCE/$TARGET}"
    fi

    # Mevcut kayıt varsa uuid'leri koru
    local uuid dkuuid
    uuid="$(sqlite3 "$GIT_DB_PATH" \
      "SELECT uuid FROM Repositories WHERE domainId=$tgt_id AND name='$(sql_escape "$name")' LIMIT 1;" 2>/dev/null || true)"
    dkuuid="$(sqlite3 "$GIT_DB_PATH" \
      "SELECT deployKeyUuid FROM Repositories WHERE domainId=$tgt_id AND name='$(sql_escape "$name")' LIMIT 1;" 2>/dev/null || true)"
    [[ -z "$uuid" ]]   && uuid="$(_uuid)"
    [[ -z "$dkuuid" ]] && dkuuid="$(_uuid)"

    info "Git deposu: $name (branch=${branch:-?}, path=${dpath:-?})"
    if (( DRYRUN )); then imported=$((imported+1)); continue; fi

    local actions_sql="NULL"
    [[ -n "$actions" ]] && actions_sql="'$(sql_escape "$actions")'"

    sqlite3 "$GIT_DB_PATH" "
      INSERT OR REPLACE INTO Repositories
        (domainId, name, type, deploymentMode, branch, deploymentPath, fetchUrl, uuid,
         skipSslVerification, postDeploymentActionsEnabled, deploymentsCounter,
         deployKeyUuid, postDeploymentActions, httpUser, httpPassword, smbUserIds)
      VALUES
        ($tgt_id,
         '$(sql_escape "$name")',
         '$(sql_escape "$type")',
         '$(sql_escape "$mode")',
         '$(sql_escape "$branch")',
         '$(sql_escape "$dpath")',
         '$(sql_escape "$fetch")',
         '$uuid',
         ${skipssl:-0},
         ${actions_en:-0},
         ${counter:-0},
         '$dkuuid',
         $actions_sql,
         NULL, NULL, NULL);
    " 2>/dev/null || { warn "Kayıt eklenemedi: $name"; continue; }

    # Deploy key (SSH anahtar çifti)
    mkdir -p "$GIT_KEYS_DIR" 2>/dev/null || true
    local key_path="$GIT_KEYS_DIR/$dkuuid"
    if [[ ! -f "$key_path" ]] && has_cmd ssh-keygen; then
      if ssh-keygen -t rsa -b 4096 -f "$key_path" -N "" -C "plesk-git-${name}@${TARGET}" >/dev/null 2>&1; then
        chown root:root "$key_path" "$key_path.pub" 2>/dev/null || true
        chmod 600 "$key_path" 2>/dev/null || true
        chmod 644 "$key_path.pub" 2>/dev/null || true
        info "  deploy key oluşturuldu"
      else
        warn "  deploy key oluşturulamadı: $name"
      fi
    fi

    if [[ -n "$tgt_guid" ]]; then
      sqlite3 "$GIT_DB_PATH" \
        "INSERT OR REPLACE INTO DeployKeys (uuid, domainUuid, name, isDefault)
         VALUES ('$dkuuid', '$tgt_guid', '$(sql_escape "$name")', 1);" 2>/dev/null \
        || warn "  DeployKeys kaydı eklenemedi: $name"
    fi

    sqlite3 "$GIT_DB_PATH" \
      "INSERT OR REPLACE INTO RepositoryDeploymentInfo
       (repoUuid, lastCommitHash, deployedCommitHash, deployedCommitAuthor, deployedCommitDate, deployedCommitMessage)
       VALUES ('$uuid', NULL, NULL, NULL, NULL, NULL);" 2>/dev/null \
      || warn "  RepositoryDeploymentInfo kaydı eklenemedi: $name"

    # Anahtarı kullanıcıya göster
    if [[ -f "$key_path.pub" ]]; then
      info "  public key: $(cut -c1-60 <"$key_path.pub")..."
    fi

    imported=$((imported+1))
  done <"$file"

  agent_git_finalize
  ok "$imported Git deposu senkronize edildi"
}

# Sanal klasörler (Plesk Git arayüzünün beklediği symlink'ler) + sahiplik
agent_git_finalize() {
  local git_dir="$VHOST_TGT/git"
  [[ -d "$git_dir" ]] || return 0

  local created=0 total=0 repo_path
  for repo_path in "$git_dir"/*.git; do
    [[ -d "$repo_path" ]] || continue
    total=$((total+1))
    local repo_name base link
    repo_name="$(basename "$repo_path")"
    base="${repo_name%.git}"
    link="$git_dir/$base"
    if [[ ! -e "$link" ]]; then
      if (( DRYRUN )); then
        info "DRY: symlink $base -> $repo_name"; created=$((created+1))
      elif ln -sf "$repo_name" "$link" 2>/dev/null; then
        created=$((created+1)); info "  sanal klasör: $base -> $repo_name"
      else
        warn "  sanal klasör oluşturulamadı: $base"
      fi
    fi
  done

  if (( ! DRYRUN )); then
    local sys_tgt; sys_tgt="$(domain_system_user "$TARGET")"
    [[ -n "$sys_tgt" ]] && chown -R "$sys_tgt":psacln "$git_dir" 2>/dev/null || true
  fi

  info "Git sanal klasörler: $created yeni / $total depo"
}

# Bare olmayan depolar için çalışma dizinini hedefe göre yeniden kur
agent_git_reset_worktree() {
  local git_dir="$VHOST_TGT/git" repo_path found=0
  has_cmd git || { warn "git komutu yok; çalışma dizini kurulumu atlandı"; return 0; }
  for repo_path in "$git_dir"/*.git; do
    [[ -d "$repo_path" ]] || continue
    # Iki yerlesim de desteklenir: git dizininin kendisi (<ad>.git/config) ve
    # calisma agaci icinde .git bulunan yerlesim (<ad>.git/.git/config)
    local gd="$repo_path"
    [[ -f "$gd/config" ]] || { [[ -f "$gd/.git/config" ]] && gd="$gd/.git"; }
    [[ -f "$gd/config" ]] || continue
    found=1
    local is_bare
    is_bare="$(git_at "$gd" config --get core.bare 2>/dev/null || printf 'false')"
    if [[ "$is_bare" == "true" ]]; then
      info "Bare depo, çalışma dizini kurulmuyor: $(basename "$repo_path")"
      continue
    fi
    info "Çalışma dizini yeniden kuruluyor: $(basename "$repo_path")"
    (( DRYRUN )) && continue
    git_at "$gd" --work-tree="$DOCROOT_TGT" reset --hard HEAD >/dev/null 2>&1 \
      || warn "  git reset uyarı verdi"
    # 'git clean -fd' git'te izlenmeyen dosyaları SİLER (.env, yüklenen medya...).
    # Varsayılan olarak çalıştırılmaz; --git-clean ile açıkça istenmelidir.
    if (( ${GIT_CLEAN:-0} )); then
      warn "  git clean -fd çalıştırılıyor (izlenmeyen dosyalar silinecek)"
      git_at "$gd" --work-tree="$DOCROOT_TGT" clean -fd >/dev/null 2>&1 \
        || warn "  git clean uyarı verdi"
    else
      info "  izlenmeyen dosyalar korundu (silmek için --git-clean)"
    fi
  done
  (( found )) || info "Çalışma dizini kurulacak depo bulunamadı"
  return 0
}
