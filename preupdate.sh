#!/bin/bash
# =============================================================
#  cPanel/WHM Pre-Update Fix — Fully Automatic
#  Auto-detect & fix semua blocker sebelum upcp
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/bssn1337/cpanel-tools/master/preupdate.sh | bash
#
#  Rawon Hunter™ — Gatlab Security Research
# =============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()    { echo -e "  ${RED}✗${NC} $*"; }
fixed()  { echo -e "  ${GREEN}⚡ FIXED:${NC} $*"; }
section(){ echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

ERRORS=0
FIXES=0

banner() {
cat << 'EOF'

  ╔═══════════════════════════════════════════════════╗
  ║      cPanel/WHM Pre-Update Fix  v1.2              ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

EOF
}

banner

# ── Pastikan root ─────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Harus dijalankan sebagai root"; exit 1
fi

# ── Pastikan ini server cPanel ────────────────────────────────
if [ ! -f /usr/local/cpanel/cpanel ]; then
    err "cPanel tidak ditemukan di server ini"; exit 1
fi

OS_NAME=$(cat /etc/redhat-release 2>/dev/null || echo "Unknown")
CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo "unknown")
SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

log "Server  : $(hostname) ($SERVER_IP)"
log "OS      : $OS_NAME"
log "cPanel  : $CPANEL_VER"
echo ""

# ═════════════════════════════════════════════════════════════
# STEP 1 — Cek proses upcp aktif (prioritas pertama)
# ═════════════════════════════════════════════════════════════
section "STEP 1/9 — Cek Proses upcp Aktif"
RUNNING_UPCP=$(pgrep -f "upcp|updatenow" 2>/dev/null | grep -v "^$$\$" | tr '\n' ' ' || true)
if [ -n "$RUNNING_UPCP" ]; then
    warn "Ada proses upcp yang sedang berjalan: PID $RUNNING_UPCP"
    ACTIVE_LOG=$(ls -t /var/cpanel/updatelogs/*.log 2>/dev/null | head -1)
    warn "Monitor: tail -f $ACTIVE_LOG"
    echo ""
    warn "Tunggu proses ini selesai, lalu jalankan script ini lagi"
    exit 0
else
    ok "Tidak ada proses upcp yang berjalan"
fi

# ═════════════════════════════════════════════════════════════
# STEP 2 — Koneksi ke server cPanel
# ═════════════════════════════════════════════════════════════
section "STEP 2/9 — Koneksi ke cPanel Update Server"
CPANEL_HOSTS="securedownloads.cpanel.net httpupdate.cpanel.net"
NET_OK=1
for host in $CPANEL_HOSTS; do
    if curl -s --max-time 10 --head "https://$host" &>/dev/null; then
        ok "Koneksi ke $host OK"
    else
        warn "Tidak bisa reach $host"
        NET_OK=0
    fi
done
if [ "$NET_OK" -eq 0 ]; then
    warn "Network issue — cek firewall/DNS. Update mungkin gagal."
    ERRORS=$((ERRORS+1))
fi

# ═════════════════════════════════════════════════════════════
# STEP 3 — Disk space & cleanup
# ═════════════════════════════════════════════════════════════
section "STEP 3/9 — Disk Space"
for path in / /tmp /usr/local/cpanel /var; do
    avail=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
    [ -z "$avail" ] && continue
    if [ "$avail" -lt 512 ]; then
        warn "$path hanya ${avail}MB — bersihkan log lama..."
        find /var/cpanel/updatelogs -name "*.log" -mtime +7 -delete 2>/dev/null
        find /usr/local/cpanel/logs -name "*.log" -mtime +14 -delete 2>/dev/null
        find /tmp -maxdepth 1 -name "*.tmp" -mtime +1 -delete 2>/dev/null
        find /tmp -maxdepth 1 -name "cpanel-*" -mtime +1 -delete 2>/dev/null
        avail_new=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
        fixed "$path setelah cleanup: ${avail_new}MB"
        FIXES=$((FIXES+1))
        if [ "$avail_new" -lt 256 ]; then
            err "$path masih kurang (${avail_new}MB) — perlu manual cleanup"
            ERRORS=$((ERRORS+1))
        fi
    else
        ok "$path : ${avail}MB tersedia"
    fi
done

# ═════════════════════════════════════════════════════════════
# STEP 4 — cpupdate.conf
# ═════════════════════════════════════════════════════════════
section "STEP 4/9 — Konfigurasi cpupdate.conf"
CPUPDATE_CONF="/etc/cpupdate.conf"
if [ -f "$CPUPDATE_CONF" ]; then
    # Cek apakah UPDATES=manual (block auto update)
    if grep -qi "^UPDATES=manual" "$CPUPDATE_CONF"; then
        warn "UPDATES=manual ditemukan — update diblokir oleh config!"
        sed -i 's/^UPDATES=manual/UPDATES=daily/i' "$CPUPDATE_CONF"
        fixed "UPDATES diubah ke daily"
        FIXES=$((FIXES+1))
    else
        ok "UPDATES: $(grep -i ^UPDATES "$CPUPDATE_CONF" | head -1)"
    fi

    # Cek CPANEL=manual
    if grep -qi "^CPANEL=manual" "$CPUPDATE_CONF"; then
        warn "CPANEL=manual ditemukan — update cPanel diblokir!"
        CURRENT_MAJOR=$(/usr/local/cpanel/cpanel -V 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+')
        sed -i "s/^CPANEL=manual/CPANEL=${CURRENT_MAJOR}/i" "$CPUPDATE_CONF"
        fixed "CPANEL diubah ke $CURRENT_MAJOR"
        FIXES=$((FIXES+1))
    else
        ok "CPANEL tier: $(grep -i ^CPANEL "$CPUPDATE_CONF" | head -1)"
    fi
else
    warn "cpupdate.conf tidak ada — membuat default..."
    cat > "$CPUPDATE_CONF" << 'CONF'
CPANEL=11.110
RPMUP=daily
SARULESUP=daily
UPDATES=daily
CONF
    fixed "cpupdate.conf dibuat"
    FIXES=$((FIXES+1))
fi

# ═════════════════════════════════════════════════════════════
# STEP 5 — Touch file & lock yang memblokir update
# ═════════════════════════════════════════════════════════════
section "STEP 5/9 — Touch Files & Lock Files"
BLOCK_FILES="
/etc/cpanelupdate
/etc/nocpanelupdates
/var/cpanel/dnsonly
/tmp/updatenow.lock
"
for f in $BLOCK_FILES; do
    f=$(echo "$f" | tr -d '[:space:]')
    [ -z "$f" ] && continue
    if [ -f "$f" ]; then
        warn "Blocking file ditemukan: $f"
        rm -f "$f"
        fixed "Dihapus: $f"
        FIXES=$((FIXES+1))
    fi
done

# Hapus stale lock jika proses tidak berjalan
LOCK_FILE="/var/cpanel/updatenow.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
        rm -f "$LOCK_FILE"
        fixed "Stale lock dihapus (PID $LOCK_PID sudah tidak aktif)"
        FIXES=$((FIXES+1))
    else
        warn "Lock file aktif (PID $LOCK_PID masih berjalan)"
    fi
else
    ok "Tidak ada lock file"
fi

# ═════════════════════════════════════════════════════════════
# STEP 6 — EPEL repo
# ═════════════════════════════════════════════════════════════
section "STEP 6/9 — EPEL Repository"
if rpm -q epel-release &>/dev/null; then
    ok "EPEL sudah terinstall ($(rpm -q epel-release))"
else
    warn "EPEL belum ada — menginstall..."
    if yum install -y epel-release &>/dev/null; then
        fixed "EPEL terinstall via yum"
        FIXES=$((FIXES+1))
    else
        rpm -Uvh "https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm" &>/dev/null \
            && { fixed "EPEL terinstall via RPM"; FIXES=$((FIXES+1)); } \
            || { warn "EPEL gagal diinstall — beberapa paket mungkin tidak tersedia"; ERRORS=$((ERRORS+1)); }
    fi
fi

# Pastikan EPEL tidak disabled
if [ -f /etc/yum.repos.d/epel.repo ]; then
    if grep -q "enabled=0" /etc/yum.repos.d/epel.repo; then
        warn "EPEL repo di-disabled — mengaktifkan..."
        sed -i 's/enabled=0/enabled=1/' /etc/yum.repos.d/epel.repo
        fixed "EPEL repo diaktifkan"
        FIXES=$((FIXES+1))
    fi
fi

# ═════════════════════════════════════════════════════════════
# STEP 7 — Paket sistem yang sering jadi blocker
# ═════════════════════════════════════════════════════════════
section "STEP 7/9 — System Package Dependencies"

REQUIRED_PKGS="boost169-program-options boost169-atomic boost169-chrono boost169-date-time boost169-filesystem boost169-regex boost169-serialization boost169-system boost169-thread liblzf perl-IO-Tty libxml2 openssl"

MISSING=""
for pkg in $REQUIRED_PKGS; do
    if ! rpm -q "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    warn "Paket kurang:$MISSING"
    if yum --enablerepo=epel install -y $MISSING > /tmp/preupdate-yum.log 2>&1; then
        fixed "Semua paket berhasil diinstall"
        FIXES=$((FIXES+1))
    else
        warn "Beberapa paket gagal:"
        grep -iE "no package|error" /tmp/preupdate-yum.log 2>/dev/null | grep -v "^Loading\|^Loaded\|^$" | head -5 | while IFS= read -r line; do
            warn "  → $line"
        done
    fi
    # Verifikasi ulang
    STILL_MISSING=""
    for pkg in $MISSING; do
        ! rpm -q "$pkg" &>/dev/null && STILL_MISSING="$STILL_MISSING $pkg"
    done
    [ -n "$STILL_MISSING" ] && warn "Masih tidak tersedia (skip):$STILL_MISSING" || ok "Semua dependency terpenuhi"
else
    ok "Semua paket dependency sudah lengkap"
fi

# ═════════════════════════════════════════════════════════════
# STEP 8 — RPM & YUM consistency
# ═════════════════════════════════════════════════════════════
section "STEP 8/9 — RPM Database & YUM"
# Hapus lock jika ada
rm -f /var/lib/rpm/__db* 2>/dev/null
if rpm --rebuilddb &>/dev/null; then
    ok "RPM database rebuilt"
else
    warn "RPM rebuild gagal"
    ERRORS=$((ERRORS+1))
fi
yum-complete-transaction --cleanup-only &>/dev/null || true
yum clean expire-cache &>/dev/null || true
ok "YUM cache refreshed"

# ═════════════════════════════════════════════════════════════
# STEP 9 — Pre-flight check & auto-fix blocker dari upcp
# ═════════════════════════════════════════════════════════════
section "STEP 9/9 — Pre-flight Check & Launch Update"

CHECK_RESULT=$(/usr/local/cpanel/scripts/upcp --check 2>&1)

# Parse setiap baris blocker dan coba auto-fix
echo "$CHECK_RESULT" | grep -iE "\] E " | while IFS= read -r line; do

    # Blocker: missing package
    if echo "$line" | grep -qi "needed system packages"; then
        PKG=$(echo "$line" | grep -oE "packages.*: (.+)$" | sed 's/.*: //')
        if [ -n "$PKG" ]; then
            warn "Auto-fix: install missing package '$PKG'..."
            yum --enablerepo=epel install -y "$PKG" &>/dev/null \
                && fixed "Package '$PKG' terinstall" \
                || warn "Gagal install '$PKG'"
        fi
    fi

    # Blocker: MySQL version
    if echo "$line" | grep -qi "mysql\|mariadb"; then
        warn "MySQL/MariaDB blocker: $line"
        warn "Cek: whmapi1 get_available_mysql_upgrades"
    fi

done 2>/dev/null || true

# Re-check setelah auto-fix
CHECK_RESULT2=$(/usr/local/cpanel/scripts/upcp --check 2>&1)
REMAINING=$(echo "$CHECK_RESULT2" | grep -iE "\] E Blocker" | grep -v "^$" || true)

echo ""
if [ -n "$REMAINING" ]; then
    err "Masih ada blocker yang tidak bisa di-fix otomatis:"
    echo "$REMAINING" | while IFS= read -r line; do err "  → $line"; done
    echo ""
    warn "Jalankan manual: /usr/local/cpanel/scripts/upcp --check"
    ERRORS=$((ERRORS+1))
else
    ok "Pre-flight check clear — tidak ada blocker!"
fi

# ─── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  ════════════ SUMMARY ════════════${NC}"
echo -e "  Auto-fixes  : ${GREEN}${BOLD}$FIXES item diperbaiki${NC}"
echo -e "  Errors left : $([ "$ERRORS" -eq 0 ] && echo "${GREEN}${BOLD}0${NC}" || echo "${RED}${BOLD}$ERRORS${NC}")"
echo ""

if [ "$ERRORS" -gt 0 ]; then
    warn "Ada issue yang perlu fix manual. Update tidak dijalankan."
    echo ""
    exit 1
fi

# ─── Jalankan update ─────────────────────────────────────────
echo -e "${BOLD}${GREEN}  ✓ Semua check passed — Mulai update cPanel...${NC}"
echo ""
LOG_FILE="/var/cpanel/updatelogs/preupdate-$(date +%Y%m%d-%H%M%S).log"
nohup /usr/local/cpanel/scripts/upcp >> "$LOG_FILE" 2>&1 &
UPCP_PID=$!

echo -e "  PID      : ${BOLD}$UPCP_PID${NC}"
echo -e "  Log      : ${BOLD}$LOG_FILE${NC}"
echo ""
echo -e "  Monitor  : ${CYAN}tail -f $LOG_FILE${NC}"
echo -e "  Progress : ${CYAN}grep -E 'complete|ERROR' $LOG_FILE | tail -5${NC}"
echo ""
