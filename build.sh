#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh — lib/ içeriğini plesk_clone.sh gövdesine gömerek tek dosyalık,
# kendi kendine yeten bir sürüm üretir (curl | bash kullanımı için).
#
# ./build.sh                 -> dist/plesk-clone.sh
# ./build.sh /tmp/out.sh     -> belirtilen yola
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="$SELF_DIR/plesk_clone.sh"
LIBDIR="$SELF_DIR/lib"
OUT="${1:-$SELF_DIR/dist/plesk-clone.sh}"

[[ -f "$ENTRY" ]] || { echo "plesk_clone.sh bulunamadı" >&2; exit 1; }
[[ -d "$LIBDIR" ]] || { echo "lib/ bulunamadı" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
: >"$OUT"

# 1) Giriş dosyasının @@LIB_INJECT@@ işaretine kadar olan kısmı
awk '/^# @@LIB_INJECT@@/{exit} {print}' "$ENTRY" >>"$OUT"

printf '\n# ---- bundled build (build.sh tarafından üretildi) ----\n' >>"$OUT"
printf 'PLESK_CLONE_BUNDLED=1\n' >>"$OUT"

# 2) lib/*.sh (shebang satırları çıkarılır)
for f in "$LIBDIR"/*.sh; do
  printf '\n# ===== lib/%s =====\n' "$(basename "$f")" >>"$OUT"
  sed '1{/^#!/d;}' "$f" >>"$OUT"
done

# 3) @@LIB_INJECT_END@@ sonrası kalan gövde
awk 'f{print} /^# @@LIB_INJECT_END@@/{f=1}' "$ENTRY" >>"$OUT"

chmod +x "$OUT"
bash -n "$OUT" || { echo "Sözdizimi hatası: $OUT" >&2; exit 1; }

echo "Üretildi: $OUT ($(wc -l <"$OUT") satır)"
