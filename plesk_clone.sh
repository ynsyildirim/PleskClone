#!/usr/bin/env bash
# ===========================================================================
# Plesk Clone / Migrate — tek giriş noktası
#
# Aynı sunucuda klonlama ve farklı sunucuya birebir taşıma için ortak akış.
# Hedef sunucudaki tüm işlemler "agent" modu üzerinden yapılır; böylece local
# ve remote senaryolar arasında mantık farkı yoktur.
#
# Kaynak: https://github.com/ynsyildirim/PleskClone
# ===========================================================================
set -euo pipefail

PLESK_CLONE_VERSION="2.0.0"

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF_PATH")"

# @@LIB_INJECT@@
if [[ ! -d "$SELF_DIR/lib" ]]; then
  printf 'HATA: lib/ dizini bulunamadı (%s).\n' "$SELF_DIR/lib" >&2
  printf 'Depoyu bütün olarak indirin: git clone https://github.com/ynsyildirim/PleskClone\n' >&2
  exit 1
fi
for _lib in "$SELF_DIR"/lib/*.sh; do
  # shellcheck source=/dev/null
  . "$_lib"
done
unset _lib
# @@LIB_INJECT_END@@

# ---- varsayılanlar ----
SOURCE=""
TARGET=""
OWNER=""
SERVICE_PLAN=""
TARGET_IP=""
SYS_USER=""
SYS_PASS=""
SYS_USER_SRC=""
IP_SRC=""
VHOST_SRC=""
VHOST_TGT=""
DOCROOT_SRC=""
DOCROOT_TGT=""
SSL_EMAIL=""
MOVE_MODE=0
FIX_GIT_ONLY=0
GIT_CLEAN=0
ACTION="clone"
PLESKCLONE_REF_OVERRIDE=""

usage() {
  cat <<EOF
Plesk Clone / Migrate v${PLESK_CLONE_VERSION}

KULLANIM
  $0 -s KAYNAK [-t HEDEF] [-o SAHİP] [seçenekler]

TEMEL
  -s, --source DOMAIN      Kaynak domain (zorunlu)
  -t, --target DOMAIN      Hedef domain (varsayılan: --move ile kaynağın aynısı)
  -o, --owner  LOGIN       Hedef domain sahibi (varsayılan: kaynağın sahibi)
      --move               Başka sunucuya BİREBİR taşıma kısayolu:
                           hedef = kaynak, DB bilgileri korunur, tüm bileşenler açılır
  -h, --help               Bu yardım
      --version            Sürüm

HEDEF SUNUCU (boş bırakılırsa aynı sunucuda klonlanır)
      --to-host HOST       Hedef sunucu IP/hostname (SSH)
      --ssh-user USER      SSH kullanıcısı (varsayılan: root)
      --ssh-port PORT      SSH portu (varsayılan: 22)
      --ssh-key FILE       SSH özel anahtarı

VERİTABANI  (asıl soru: bilgiler değişsin mi?)
      --keep-db            Ad + kullanıcı + parola BİREBİR korunur
                           (config dosyalarına dokunulmaz; sadece farklı sunucuda)
      --new-db             Ad + kullanıcı + parola yeniden üretilir (aynı sunucuda klon)
      --db-mode MOD        keep | suffix | prefix | map     (ad politikası)
      --db-suffix STR      suffix modunda kullanılacak sonek
      --db-prefix STR      prefix modunda kullanılacak önek
      --db-map  "a=b,c=d"  map modunda eski=yeni eşlemeleri
      --db-user-mode MOD   keep | new | map
      --db-user-map "a=b"  kullanıcı eşlemeleri
      --db-pass-mode MOD   keep | new | map
      --db-pass-map "u=p"  parola eşlemeleri
      --db-overwrite       Hedefte aynı adlı DB varsa üzerine yaz
      --no-db              Veritabanlarını hiç kopyalama

DOSYALAR
      --full-vhost         Tüm vhost dizinini kopyala (private, cgi-bin, .ssh ...)
      --docroot-only       Sadece document root (varsayılan)
      --no-delete          rsync --delete kullanma (hedefteki fazlalıkları silme)
      --no-config-rewrite  .env / wp-config.php gibi dosyalarda otomatik güncelleme yapma

BİLEŞENLER
      --full               Tüm bileşenleri aç (dns, mail, sertifika, alias, ftp, git ...)
      --only  a,b,c        Sadece bu bileşenleri çalıştır
      --skip  a,b,c        Bu bileşenleri atla
      --copy-git           Git depoları + Plesk Git Extension ayarları
      --git-worktree       Bare olmayan depolarda çalışma dizinini yeniden kur
                           (hedef docroot'ta 'git reset --hard' çalıştırır)
      --git-clean          --git-worktree + 'git clean -fd'
                           DİKKAT: git'te izlenmeyen dosyaları SİLER (.env dahil)
      --fix-git            Sadece Git entegrasyonunu onar (domain zaten varsa)
      --ssl                Let's Encrypt sertifikası al
      --ssl-email MAIL     Let's Encrypt e-posta adresi
  Bileşenler: $ALL_COMPONENTS

HEDEF DOMAIN AYARLARI
      --plan NAME          Servis planı (varsayılan: kaynağınki)
      --ip IP              Hedef IP adresi
      --sys-user LOGIN     Hedef sistem kullanıcısı (varsayılan: taşımada kaynakla aynı)
      --sys-pass PASS      Hedef sistem kullanıcı parolası

MOTOR
      --engine granular    Ayrıntılı klonlama (varsayılan) — yeniden adlandırma yapabilir
      --engine native      plesk pleskbackup/pleskrestore ile birebir taşıma
                           (sadece aynı isimle, farklı sunucuya)
      --keep-backup        native motorda yedek dosyalarını silme

KURULUM
      --update             Depodaki son sürüme güncelle (build otomatik)
      --ref REF            Güncellemede kullanılacak dal/etiket
      --where              Kurulum dizini ve sürüm bilgisi
      --uninstall          Kurulumu kaldır
  Kurulum tek satırla:
      curl -fsSL https://raw.githubusercontent.com/ynsyildirim/PleskClone/main/install.sh | bash

GENEL
  -y, --yes                Tüm onayları otomatik ver
      --non-interactive    Hiç soru sorma (varsayılanlarla devam et)
  -v, --verbose            Ayrıntılı çıktı
      --dry-run            Hiçbir değişiklik yapma, sadece ne yapılacağını göster
      --log-dir DIR        Log/kimlik bilgisi dizini (varsayılan: ./logs)

ÖRNEKLER
  # Aynı sunucuda staging klonu (DB adı/kullanıcı/parola yenilenir)
  $0 -s example.com -t staging.example.com --new-db --copy-git --ssl

  # Aynı sunucuda klon, ama DB kullanıcı/parolası aynı kalsın (sadece ad değişsin)
  $0 -s example.com -t staging.example.com --db-mode suffix --db-user-mode keep --db-pass-mode keep

  # Başka sunucuya BİREBİR taşıma — hiçbir bilgi değişmez
  $0 -s example.com --move --to-host 203.0.113.10

  # Başka sunucuya farklı isimle taşıma, DB bilgileri korunarak
  $0 -s example.com -t yeni.com --to-host 203.0.113.10 --keep-db --full

  # Plesk'in kendi yedek motoruyla birebir taşıma
  $0 -s example.com --move --to-host 203.0.113.10 --engine native

  # Ne olacağını gör
  $0 -s example.com -t test.example.com --dry-run
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -s|--source)   SOURCE="${2:-}"; shift 2 ;;
      -t|--target)   TARGET="${2:-}"; shift 2 ;;
      -o|--owner)    OWNER="${2:-}";  shift 2 ;;
      --move)        MOVE_MODE=1; shift ;;

      --to-host)     REMOTE_HOST="${2:-}"; TRANSPORT="remote"; TRANSPORT_SET=1; shift 2 ;;
      --ssh-user)    REMOTE_USER="${2:-}"; shift 2 ;;
      --ssh-port)    REMOTE_PORT="${2:-}"; shift 2 ;;
      --ssh-key)     REMOTE_KEY="${2:-}";  shift 2 ;;

      --keep-db)     DB_MODE="keep";   DB_USER_MODE="keep"; DB_PASS_MODE="keep"; DB_POLICY_SET=1; shift ;;
      --new-db)      DB_MODE="suffix"; DB_USER_MODE="new";  DB_PASS_MODE="new";  DB_POLICY_SET=1; shift ;;
      --db-mode)     DB_MODE="${2:-}";      DB_POLICY_SET=1; shift 2 ;;
      --db-suffix)   DB_SUFFIX="${2:-}";    DB_MODE="suffix"; DB_POLICY_SET=1; shift 2 ;;
      --db-prefix)   DB_PREFIX="${2:-}";    DB_MODE="prefix"; DB_POLICY_SET=1; shift 2 ;;
      --db-map)      DB_MAP="${2:-}";       DB_MODE="map";    DB_POLICY_SET=1; shift 2 ;;
      --db-user-mode) DB_USER_MODE="${2:-}"; DB_POLICY_SET=1; shift 2 ;;
      --db-user-map)  DB_USER_MAP="${2:-}"; DB_USER_MODE="map"; DB_POLICY_SET=1; shift 2 ;;
      --db-pass-mode) DB_PASS_MODE="${2:-}"; DB_POLICY_SET=1; shift 2 ;;
      --db-pass-map)  DB_PASS_MAP="${2:-}"; DB_PASS_MODE="map"; DB_POLICY_SET=1; shift 2 ;;
      --db-overwrite) DB_OVERWRITE=1; shift ;;
      --no-db)        COMPONENTS_SKIP="${COMPONENTS_SKIP},db"; DB_POLICY_SET=1; shift ;;

      --full-vhost)  FULL_VHOST=1; shift ;;
      --docroot-only) FULL_VHOST=0; shift ;;
      --no-delete)   RSYNC_DELETE=0; shift ;;
      --no-config-rewrite) CONFIG_REWRITE=0; shift ;;

      --full)        COMPONENTS_ON="$(all_components_csv)"; shift ;;
      --only)        COMPONENTS_ON="${2:-}"; ONLY_MODE=1; shift 2 ;;
      --skip)        COMPONENTS_SKIP="${COMPONENTS_SKIP},${2:-}"; shift 2 ;;
      --copy-git)    comp_add "git"; shift ;;
      --git-worktree) comp_add "worktree"; shift ;;
      --git-clean)   comp_add "worktree"; GIT_CLEAN=1; shift ;;
      --fix-git)     FIX_GIT_ONLY=1; comp_add "git"; shift ;;
      --ssl)         comp_add "ssl"; shift ;;
      --ssl-email)   SSL_EMAIL="${2:-}"; shift 2 ;;

      --plan)        SERVICE_PLAN="${2:-}"; shift 2 ;;
      --ip)          TARGET_IP="${2:-}"; shift 2 ;;
      --sys-user)    SYS_USER="${2:-}"; shift 2 ;;
      --sys-pass)    SYS_PASS="${2:-}"; shift 2 ;;

      --engine)      ENGINE="${2:-granular}"; shift 2 ;;
      --keep-backup) NATIVE_KEEP_BACKUP=1; shift ;;

      -y|--yes)      ASSUME_YES=1; shift ;;
      --non-interactive) INTERACTIVE=0; ASSUME_YES=1; shift ;;
      -v|--verbose)  VERBOSE=1; shift ;;
      --dry-run)     DRYRUN=1; shift ;;
      --log-dir)     LOG_DIR="${2:-}"; shift 2 ;;

      --update)      ACTION="update"; shift ;;
      --uninstall)   ACTION="uninstall"; shift ;;
      --where)       ACTION="where"; shift ;;
      --ref)         PLESKCLONE_REF_OVERRIDE="${2:-}"; shift 2 ;;

      --version)     printf 'plesk-clone %s\n' "$PLESK_CLONE_VERSION"; exit 0 ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "Bilinmeyen argüman: $1" ;;
    esac
  done

  # Sorular /dev/tty üzerinden sorulur; kontrol terminali yoksa etkileşimi kapat.
  # (stdin'in boru olması sorun değil — `curl ... | bash` kullanımı çalışmaya devam eder.)
  { [[ -t 0 ]] || { : </dev/tty; } 2>/dev/null; } || INTERACTIVE=0

  # --move: birebir taşıma kısayolu
  if (( MOVE_MODE )); then
    [[ -z "$TARGET" ]] && TARGET="$SOURCE"
    if (( ! DB_POLICY_SET )); then
      DB_MODE="keep"; DB_USER_MODE="keep"; DB_PASS_MODE="keep"; DB_POLICY_SET=1
    fi
    (( ONLY_MODE )) || COMPONENTS_ON="$(all_components_csv),${COMPONENTS_ON}"
    FULL_VHOST=1
  fi

  [[ -z "$TARGET" ]] && TARGET="$SOURCE"
  return 0
}

main() {
  # ---- agent modu: hedef sunucuda tek bir işlem çalıştır ----
  if [[ "${1:-}" == "--agent" ]]; then
    shift
    [[ $# -ge 1 ]] || { err "--agent için işlem adı gerekli"; exit 64; }
    agent_dispatch "$@"
    exit $?
  fi

  parse_args "$@"

  # ---- kurulum yonetimi (klonlamadan bagimsiz) ----
  case "$ACTION" in
    update)    do_update;    exit 0 ;;
    uninstall) do_uninstall; exit 0 ;;
    where)     show_where;   exit 0 ;;
  esac

  [[ -z "$SOURCE" ]] && { usage >&2; die "Kaynak domain (-s) zorunlu."; }

  init_logdir
  LOG_FILE="$LOG_DIR/${TARGET}_clone_$(date +%Y%m%d_%H%M%S).log"
  : >"$LOG_FILE"; chmod 600 "$LOG_FILE" 2>/dev/null || true

  bold "Plesk Clone v${PLESK_CLONE_VERSION} — $SOURCE -> $TARGET"
  info "Oturum logu: $LOG_FILE"

  install_cleanup_hook

  if (( FIX_GIT_ONLY )); then
    do_fix_git
  else
    do_clone
  fi
}

main "$@"
