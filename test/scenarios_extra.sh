#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ek senaryolar - scenarios.sh tarafindan source edilir (cerceve paylasilir)
# ---------------------------------------------------------------------------

# ===========================================================================
# S15 - Parola duz metin okunamadiginda MySQL hash'i kopyalanmali
#       (gercek Plesk'te parolalar sifreli saklanabilir; bu yolun calismasi
#        birebir tasimanin sartidir)
# ===========================================================================
T=hash.test
scenario S15 "uzak-parola-hash-kopyalama"
cleanup_remote "$T"
# On kosul: kaynakta parolayi geri okunamaz yap
psa "UPDATE accounts a JOIN db_users du ON du.account_id=a.id SET a.type='sym' WHERE du.login='shopuser';" >/dev/null
check "on kosul: duz metin parola artik okunamiyor" \
  bash -c "[[ \"\$(plesk db -Ne \"SELECT a.type FROM accounts a JOIN db_users du ON du.account_id=a.id WHERE du.login='shopuser'\")\" == 'sym' ]]"

$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                       test "$RC" -eq 0
check "hash kopyalama yolu kullanildi"              grep -qi "hash" "$CUR_LOG"
BD="$(docroot_of_b "$T")"
check "DB kullanicisi korundu"                      bash -c "[[ \"\$(SSHQ \"sed -n 's/^DB_USERNAME=//p' '$BD/.env'\")\" == 'shopuser' ]]"
check "config'teki parola DEGISMEDI"                bash -c "[[ \"\$(SSHQ \"sed -n 's/^DB_PASSWORD=//p' '$BD/.env'\")\" == 'ShopPass#2026a' ]]"
check "HEDEFTE ESKI PAROLAYLA BAGLANTI CALISIYOR"   health_remote "$BD"
# Geri al
psa "UPDATE accounts a JOIN db_users du ON du.account_id=a.id SET a.type='plain' WHERE du.login='shopuser';" >/dev/null
scenario_end

# ===========================================================================
# S16 - Gercek deploy dongusu: kaynakta yeni commit -> hedefte deploy
# ===========================================================================
T=deploy.test
scenario S16 "gercek-deploy-dongusu"
cleanup_remote "$T"

# Kaynakta yeni bir surum yayinla.
# GIT: root, domain kullanicisina ait depoda calistigi icin safe.directory sart.
# safe.directory yalnizca korumali config'ten okunur (-c veya global dosya).
# clone/push alt surec baslattigi icin -c yetmez; test kosumuna ozel bir global
# config dosyasi kullaniyoruz. Bu SADECE test harness icin; urun kodu kendi
# -c safe.directory duzeltmesiyle calisir ve o duzeltme burada maskelenmez.
# NOT: degisken export EDILMEZ - aksi halde pleskclone da devralir ve urunun
# kendi -c safe.directory duzeltmesi maskelenirdi.
tgit()  { GIT_CONFIG_GLOBAL=/opt/testgitconfig git "$@"; }
rtgit() { SSHQ "GIT_CONFIG_GLOBAL=/opt/testgitconfig git $*"; }
export -f tgit
GITS="tgit"
W=/tmp/deploy-cycle; rm -rf "$W"
$GITS clone -q "/var/www/vhosts/$SRC_DOMAIN/git/app.git" "$W" >>"$CUR_LOG" 2>&1
( cd "$W" && tgit config user.email t@t.local && tgit config user.name T \
  && printf '<?php\n// surum 2\necho "v2";\n' > app.php \
  && echo "surum-2" > VERSION \
  && tgit add -A && tgit commit -q -m "surum 2" && $GITS push -q origin main ) >>"$CUR_LOG" 2>&1
check "kaynak depoya yeni commit atildi" \
  bash -c "tgit --git-dir='/var/www/vhosts/$SRC_DOMAIN/git/app.git' log --oneline | grep -q 'surum 2'"

$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --full --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "klonlama basarili"                            test "$RC" -eq 0
BD="$(docroot_of_b "$T")"

check "yeni commit hedef depoda var" \
  bash -c "SSHQ \"GIT_CONFIG_GLOBAL=/opt/testgitconfig git --git-dir='/var/www/vhosts/$T/git/app.git' log --oneline\" | grep -q 'surum 2'"
check "calisma dizini kurulumu hatasiz gecti"        bash -c "! grep -q 'git reset uyari\|git reset uyarı' '$CUR_LOG'"

# Plesk'in deploy adiminin esdegeri: bare depodan docroot'a checkout
check "hedefte depodan docroot'a deploy" \
  bash -c "SSHQ \"GIT_CONFIG_GLOBAL=/opt/testgitconfig git --git-dir='/var/www/vhosts/$T/git/app.git' --work-tree='$BD' checkout -f main\""
check "yeni surum dosyasi docroot'a dustu" \
  bash -c "[[ \"\$(SSHQ \"cat '$BD/VERSION'\")\" == 'surum-2' ]]"

# .env git'te olmadigi icin deploy sonrasi KORUNMALI - uygulamanin
# deploy'dan sonra da calismasinin sarti budur.
check "deploy sonrasi .env korundu (hedef degerleri)" \
  bash -c "[[ \"\$(SSHQ \"sed -n 's/^APP_URL=//p' '$BD/.env'\")\" == 'https://$T' ]]"
check "DEPLOY SONRASI UYGULAMA CALISIYOR"            health_remote "$BD"

# Plesk'in post-deployment action'i (sqlite'tan okunur)
check "post-deployment komutu hedef domaini gosteriyor" \
  bash -c "BID=\$(SSHQ \"plesk db -Ne \\\"SELECT id FROM domains WHERE name='$T' LIMIT 1\\\"\"); \
           SSHQ \"sqlite3 /usr/local/psa/var/modules/git/git_db.db \\\"SELECT postDeploymentActions FROM Repositories WHERE domainId=\$BID\\\"\" | grep -q '$T'"
check "POST-DEPLOYMENT KOMUTU HEDEFTE CALISIYOR VE DB'YE BAGLANIYOR" \
  bash -c "BID=\$(SSHQ \"plesk db -Ne \\\"SELECT id FROM domains WHERE name='$T' LIMIT 1\\\"\"); \
           CMD=\$(SSHQ \"sqlite3 /usr/local/psa/var/modules/git/git_db.db \\\"SELECT postDeploymentActions FROM Repositories WHERE domainId=\$BID\\\"\"); \
           SSHQ \"\$CMD\" | grep -q '^OK ana'"
rm -rf "$W"
scenario_end

# ===========================================================================
# S17 - Ayni klonu iki kez calistirmak (idempotenslik)
# ===========================================================================
T=tekrar.test
scenario S17 "ayni-klonu-iki-kez-calistir"
cleanup_remote "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --non-interactive -y >>"$CUR_LOG" 2>&1
R1=$?
check "1. calistirma basarili"                       test "$R1" -eq 0
BD="$(docroot_of_b "$T")"
check "1. calistirma sonrasi uygulama calisiyor"     health_remote "$BD"

printf '\n--- ikinci calistirma ---\n' >>"$CUR_LOG"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --non-interactive -y >>"$CUR_LOG" 2>&1
R2=$?
check "2. calistirma basarili"                       test "$R2" -eq 0
check "mevcut domain icin uyari verildi"             grep -qi "zaten mevcut" "$CUR_LOG"
check "mevcut DB uzerine yazilmadi (uyari)"          grep -qi "zaten var" "$CUR_LOG"
check "2. calistirma sonrasi uygulama HALA calisiyor" health_remote "$BD"
check "veri bozulmadi (3 satir)" \
  bash -c "[[ \"\$(SSHQ 'MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"SELECT COUNT(*) FROM items\" shopdb' | tr -d '[:space:]')\" == '$SRC_ROWS1' ]]"
scenario_end

# ===========================================================================
# S18 - --db-overwrite ile mevcut veritabaninin uzerine yazma
# ===========================================================================
scenario S18 "db-overwrite"
T=tekrar.test
# Hedefteki veriyi boz
SSHQ "MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -e 'DELETE FROM items WHERE id>1' shopdb" >/dev/null 2>&1
check "on kosul: hedef veri bozuldu" \
  bash -c "[[ \"\$(SSHQ 'MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"SELECT COUNT(*) FROM items\" shopdb' | tr -d '[:space:]')\" == '1' ]]"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --db-overwrite --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                        test "$RC" -eq 0
check "VERI YENIDEN AKTARILDI ($SRC_ROWS1 satir)" \
  bash -c "[[ \"\$(SSHQ 'MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"SELECT COUNT(*) FROM items\" shopdb' | tr -d '[:space:]')\" == '$SRC_ROWS1' ]]"
BD="$(docroot_of_b "$T")"
check "uygulama calisiyor"                           health_remote "$BD"
scenario_end

# ===========================================================================
# S19 - Plesk'in kendi yedek motoru (--engine native)
# ===========================================================================
T="$SRC_DOMAIN"
scenario S19 "native-motor-birebir-tasima"
cleanup_remote "$T"
$PC -s "$SRC_DOMAIN" --move --to-host "$REMOTE_IP" --engine native --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti (rc=$RC)"               test "$RC" -eq 0
check "hedef sunucuda domain olustu"                 assert_domain_remote "$T"
BD="$(docroot_of_b "$T")"
check "dosyalar geri yuklendi"                       assert_file_remote "$BD/index.php"
check "veritabani geri yuklendi"                     bash -c "[[ \"\$(SSHQ 'MYSQL_PWD=\$(cat /etc/psa/.psa.shadow) mysql -uadmin -N -B -e \"SELECT COUNT(*) FROM items\" shopdb' | tr -d '[:space:]')\" == '$SRC_ROWS1' ]]"
check "UYGULAMA HEDEFTE CALISIYOR"                   health_remote "$BD"
check "crontab geri yuklendi" \
  bash -c "TS=\$(SSHQ \"plesk db -Ne \\\"SELECT su.login FROM sys_users su JOIN hosting h ON h.sys_user_id=su.id JOIN domains d ON d.id=h.dom_id WHERE d.name='$T' LIMIT 1\\\"\"); \
           [[ \"\$(SSHQ \"crontab -l -u \$TS 2>/dev/null | grep -c '^[^#]'\" | tr -d '[:space:]')\" == '$SRC_CRON' ]]"
check "gecici yedek dosyalari silindi"               bash -c "! ls /tmp/plesk-clone-*.tar >/dev/null 2>&1"
scenario_end

# ===========================================================================
# S20 - Guncelleme gercekten dosyalari degistiriyor mu
# ===========================================================================
scenario S20 "guncelleme-dosyalari-degistiriyor"
SRCCOPY=/tmp/pc-newver
rm -rf "$SRCCOPY"; cp -a /opt/pleskclone-src "$SRCCOPY" 2>/dev/null
sed -i 's/^PLESK_CLONE_VERSION="2.0.0"/PLESK_CLONE_VERSION="2.0.1-test"/' "$SRCCOPY/plesk_clone.sh"
check "on kosul: yeni surum kaynagi hazir"           grep -q '2.0.1-test' "$SRCCOPY/plesk_clone.sh"
check "mevcut surum 2.0.0"                           bash -c "pleskclone --version | grep -q '2.0.0'"
PLESKCLONE_SRC="$SRCCOPY" pleskclone --update >>"$CUR_LOG" 2>&1
RC=$?
check "guncelleme komutu basarili"                   test "$RC" -eq 0
check "SURUM GERCEKTEN DEGISTI (2.0.1-test)"         bash -c "pleskclone --version | grep -q '2.0.1-test'"
check "tek dosyalik surum de guncellendi"            bash -c "bash /usr/local/lib/pleskclone/dist/plesk-clone.sh --version | grep -q '2.0.1-test'"
check "--where yeni surumu gosteriyor"               bash -c "pleskclone --where | grep -q '2.0.1-test'"
# Geri al
PLESKCLONE_SRC=/opt/pleskclone-src pleskclone --update >>"$CUR_LOG" 2>&1
check "eski surume geri donuldu"                     bash -c "pleskclone --version | grep -q '2.0.0'"
rm -rf "$SRCCOPY"
scenario_end

# ===========================================================================
# S21 - --no-delete: hedefteki fazla dosyalar korunmali
# ===========================================================================
T=nodelete.test
scenario S21 "no-delete-hedef-dosyasi-korunur"
cleanup_remote "$T"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --non-interactive -y >>"$CUR_LOG" 2>&1
BD="$(docroot_of_b "$T")"
SSHQ "echo 'hedefe-ozel' > '$BD/sadece-hedefte.txt'" >/dev/null
check "on kosul: hedefe ozel dosya olusturuldu"      assert_file_remote "$BD/sadece-hedefte.txt"

$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --no-delete --non-interactive -y >>"$CUR_LOG" 2>&1
check "--no-delete ile dosya KORUNDU"                assert_file_remote "$BD/sadece-hedefte.txt"

$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --non-interactive -y >>"$CUR_LOG" 2>&1
check "varsayilan (--delete) ile dosya SILINDI"      bash -c "! SSHQ \"test -f '$BD/sadece-hedefte.txt'\""
scenario_end

# ===========================================================================
# S23 - worktree bileseni: izlenmeyen dosyalar (.env) SILINMEMELI
#       'git clean -fd' varsayilan olarak calismamali, --git-clean ile istenmeli
# ===========================================================================
T=worktree.test
scenario S23 "worktree-izlenmeyen-dosya-korunur"
cleanup_remote "$T"
check "on kosul: kaynakta bare OLMAYAN depo var" \
  bash -c "[[ \"\$(tgit --git-dir='/var/www/vhosts/$SRC_DOMAIN/git/site.git/.git' config --get core.bare 2>/dev/null || tgit --git-dir='/var/www/vhosts/$SRC_DOMAIN/git/site.git' config --get core.bare)\" != 'true' ]] || \
           [[ -d '/var/www/vhosts/$SRC_DOMAIN/git/site.git/.git' ]]"

# --full worktree'yi ACMAMALI (veri kaybi riski nedeniyle opt-in)
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --full --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "komut basariyla bitti"                        test "$RC" -eq 0
check "--full worktree bilesenini ACMADI"            grep -q "bileşen kapalı: worktree\|bilesen kapali: worktree" "$CUR_LOG"
BD="$(docroot_of_b "$T")"
check ".env yerinde"                                 assert_file_remote "$BD/.env"
check "UYGULAMA CALISIYOR"                           health_remote "$BD"

# Simdi worktree'yi acikca iste: .env yine de KORUNMALI (clean yok)
printf '\n--- --git-worktree ile ---\n' >>"$CUR_LOG"
$PC -s "$SRC_DOMAIN" -t "$T" --to-host "$REMOTE_IP" --keep-db --full --git-worktree --non-interactive -y >>"$CUR_LOG" 2>&1
RC=$?
check "--git-worktree ile komut basarili"            test "$RC" -eq 0
check "worktree bileseni bu kez calisti"             grep -qi "Çalışma dizini\|Calisma dizini\|Bare depo" "$CUR_LOG"
check "izlenmeyen dosyalar korundu mesaji"           grep -qi "izlenmeyen dosyalar korundu" "$CUR_LOG"
check "GIT CLEAN CALISTIRILMADI"                     bash -c "! grep -qi 'git clean -fd çalıştırılıyor' '$CUR_LOG'"
check ".ENV HALA DURUYOR (veri kaybi yok)"           assert_file_remote "$BD/.env"
check "UYGULAMA HALA CALISIYOR"                      health_remote "$BD"
scenario_end

# ===========================================================================
# S22 - Tum senaryolardan sonra KAYNAK bozulmamis olmali
# ===========================================================================
scenario S22 "kaynak-butunlugu"
check "kaynak domain hala var"                       assert_domain_local "$SRC_DOMAIN"
check "kaynak .env degismedi"                        bash -c "[[ \"\$(sed -n 's/^DB_DATABASE=//p' '$SRC_DOCROOT/.env')\" == 'shopdb' ]]"
check "kaynak DB kullanicisi degismedi"              bash -c "[[ \"\$(sed -n 's/^DB_USERNAME=//p' '$SRC_DOCROOT/.env')\" == 'shopuser' ]]"
check "kaynak DB parolasi degismedi"                 bash -c "[[ \"\$(sed -n 's/^DB_PASSWORD=//p' '$SRC_DOCROOT/.env')\" == 'ShopPass#2026a' ]]"
check "KAYNAK UYGULAMA HALA CALISIYOR"               health_local "$SRC_DOCROOT"
check "kaynak veri satir sayisi degismedi"           bash -c "[[ \"\$(rowcount_local shopdb)\" == '$SRC_ROWS1' ]]"
check "kaynak cron degismedi"                        bash -c "[[ \"\$(crontab -l -u '$SRC_SYSUSER' 2>/dev/null | grep -c '^[^#]')\" == '$SRC_CRON' ]]"
check "kaynak git deposu saglam (fsck)"              bash -c "tgit --git-dir='/var/www/vhosts/$SRC_DOMAIN/git/app.git' fsck --no-progress"
check "kaynak deploy script'i hala kaynagi gosteriyor" bash -c "grep -q 'DOMAIN_NAME=\"$SRC_DOMAIN\"' '$SRC_DOCROOT/deploy.sh'"
check "kaynakta yedek dizini olusturulmadi"          bash -c "[[ ! -d '/var/www/vhosts/$SRC_DOMAIN/.plesk-clone-backup' ]]"
scenario_end
