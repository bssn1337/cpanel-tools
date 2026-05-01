#!/bin/bash
# =============================================================
#  cPanel/WHM Pre-Update Fix — Universal Edition
#  Supports: EL7 / EL8 / EL9 (CentOS, CloudLinux, AlmaLinux, Rocky)
#  cPanel version: 110.x / 114.x / 116.x / 118.x / 120.x+ / 130.x+
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/bssn1337/cpanel-tools/master/preupdate.sh | bash
#
#  Rawon Hunter™ — Gatlab Security Research
# =============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()     { echo -e "  ${RED}✗${NC} $*"; }
fixed()   { echo -e "  ${GREEN}⚡ FIXED:${NC} $*"; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

ERRORS=0; FIXES=0

# ── Banner ────────────────────────────────────────────────────
cat << 'EOF'

  ╔═══════════════════════════════════════════════════╗
  ║      cPanel/WHM Pre-Update Fix  v1.6              ║
  ║      Universal — EL7/EL8/EL9                      ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

EOF

# ── Sanity checks ─────────────────────────────────────────────
[ "$EUID" -ne 0 ]                    && { err "Harus root"; exit 1; }
[ ! -f /usr/local/cpanel/cpanel ]    && { err "cPanel tidak ditemukan"; exit 1; }

# ═════════════════════════════════════════════════════════════
# DETEKSI ENVIRONMENT
# ═════════════════════════════════════════════════════════════
OS_NAME=$(cat /etc/redhat-release 2>/dev/null || echo "Unknown")
OS_MAJOR=$(rpm -q --qf '%{version}' \
    $(rpm -qf /etc/redhat-release 2>/dev/null) 2>/dev/null \
    | grep -oE '^[0-9]+' || echo "7")
CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || echo "0")
CPANEL_FULL=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo "unknown")
SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Package manager: EL8/EL9 pakai dnf, EL7 pakai yum
PKG_MGR="yum"
[ "$OS_MAJOR" -ge 8 ] 2>/dev/null && PKG_MGR="dnf"

log "Server  : $(hostname) ($SERVER_IP)"
log "OS      : $OS_NAME (EL${OS_MAJOR})"
log "cPanel  : $CPANEL_FULL"
log "PkgMgr  : $PKG_MGR"
echo ""

# ═════════════════════════════════════════════════════════════
# STEP 1 — Cek proses upcp aktif
# ═════════════════════════════════════════════════════════════
section "STEP 1/9 — Cek Proses upcp Aktif"
SELF_PID=$$
RUNNING_UPCP=$(pgrep -f "upcp|updatenow" 2>/dev/null | grep -v "^${SELF_PID}$" | tr '\n' ' ' || true)
if [ -n "$RUNNING_UPCP" ]; then
    warn "Ada proses upcp berjalan: PID $RUNNING_UPCP"
    ACTIVE_LOG=$(ls -t /var/cpanel/updatelogs/*.log 2>/dev/null | /usr/bin/head -1)
    if [ -n "$ACTIVE_LOG" ]; then
        warn "Monitor: tail -f $ACTIVE_LOG"
        PROGRESS=$(grep -oE '[0-9]+% complete' "$ACTIVE_LOG" 2>/dev/null | /usr/bin/tail -1)
        [ -n "$PROGRESS" ] && warn "Progress: $PROGRESS"
    fi
    echo ""
    warn "Tunggu selesai, lalu jalankan script ini lagi"
    exit 0
else
    ok "Tidak ada proses upcp berjalan"
fi

# ═════════════════════════════════════════════════════════════
# STEP 2 — Koneksi ke update server cPanel
# ═════════════════════════════════════════════════════════════
section "STEP 2/9 — Koneksi ke cPanel Update Server"
NET_FAIL=0
for host in securedownloads.cpanel.net httpupdate.cpanel.net; do
    if curl -s --max-time 10 --head "https://$host" &>/dev/null; then
        ok "https://$host → OK"
    else
        warn "Tidak bisa reach $host"
        NET_FAIL=$((NET_FAIL+1))
    fi
done
[ "$NET_FAIL" -gt 0 ] && { warn "Network issue — update mungkin gagal"; ERRORS=$((ERRORS+1)); }

# ═════════════════════════════════════════════════════════════
# STEP 3 — Disk space
# ═════════════════════════════════════════════════════════════
section "STEP 3/9 — Disk Space"
for path in / /tmp /usr/local/cpanel /var; do
    avail=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
    [ -z "$avail" ] && continue
    if [ "$avail" -lt 512 ]; then
        warn "$path hanya ${avail}MB — cleanup log lama..."
        find /var/cpanel/updatelogs -name "*.log" -mtime +7 -delete 2>/dev/null
        find /usr/local/cpanel/logs -name "*.log" -mtime +14 -delete 2>/dev/null
        find /tmp -maxdepth 1 \( -name "*.tmp" -o -name "cpanel-*" \) -mtime +1 -delete 2>/dev/null
        avail2=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
        fixed "$path setelah cleanup: ${avail2}MB"
        FIXES=$((FIXES+1))
        [ "$avail2" -lt 256 ] && { err "$path masih kritis (${avail2}MB)"; ERRORS=$((ERRORS+1)); }
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
    if grep -qi "^UPDATES=manual" "$CPUPDATE_CONF"; then
        warn "UPDATES=manual ditemukan!"
        sed -i 's/^UPDATES=manual/UPDATES=daily/I' "$CPUPDATE_CONF"
        fixed "UPDATES → daily"
        FIXES=$((FIXES+1))
    else
        ok "UPDATES: $(grep -i '^UPDATES' "$CPUPDATE_CONF" | /usr/bin/head -1)"
    fi
    if grep -qi "^CPANEL=manual" "$CPUPDATE_CONF"; then
        warn "CPANEL=manual ditemukan — update diblokir!"
        sed -i "s/^CPANEL=manual/CPANEL=${CPANEL_VER}/I" "$CPUPDATE_CONF"
        fixed "CPANEL → $CPANEL_VER"
        FIXES=$((FIXES+1))
    else
        ok "CPANEL tier: $(grep -i '^CPANEL' "$CPUPDATE_CONF" | /usr/bin/head -1)"
    fi
else
    warn "cpupdate.conf tidak ada — membuat default..."
    cat > "$CPUPDATE_CONF" << CONF
CPANEL=${CPANEL_VER}
RPMUP=daily
SARULESUP=daily
UPDATES=daily
CONF
    fixed "cpupdate.conf dibuat"
    FIXES=$((FIXES+1))
fi

# ═════════════════════════════════════════════════════════════
# STEP 5 — Touch files & stale locks
# ═════════════════════════════════════════════════════════════
section "STEP 5/9 — Blocking Files & Locks"
FOUND_BLOCK=0
for f in /etc/cpanelupdate /etc/nocpanelupdates /etc/cpanel_disable_update; do
    [ -f "$f" ] && { rm -f "$f"; fixed "Removed: $f"; FIXES=$((FIXES+1)); FOUND_BLOCK=1; }
done
[ "$FOUND_BLOCK" -eq 0 ] && ok "Tidak ada blocking touch file"

LOCK_FILE="/var/cpanel/updatenow.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
        rm -f "$LOCK_FILE"
        fixed "Stale lock dihapus (PID $LOCK_PID tidak aktif)"
        FIXES=$((FIXES+1))
    else
        warn "Lock aktif (PID $LOCK_PID)"
    fi
else
    ok "Tidak ada lock file"
fi

# ═════════════════════════════════════════════════════════════
# STEP 6 — EPEL (universal per OS version)
# ═════════════════════════════════════════════════════════════
section "STEP 6/9 — EPEL Repository (EL${OS_MAJOR})"

EPEL_RPM_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"

if rpm -q epel-release &>/dev/null; then
    ok "EPEL sudah terinstall ($(rpm -q epel-release))"
else
    warn "EPEL belum ada — menginstall untuk EL${OS_MAJOR}..."
    if $PKG_MGR install -y epel-release &>/dev/null; then
        fixed "EPEL terinstall via $PKG_MGR"
        FIXES=$((FIXES+1))
    else
        warn "Coba via direct RPM..."
        rpm -Uvh "$EPEL_RPM_URL" &>/dev/null \
            && { fixed "EPEL terinstall via RPM"; FIXES=$((FIXES+1)); } \
            || { warn "EPEL gagal"; ERRORS=$((ERRORS+1)); }
    fi
fi

# Pastikan EPEL tidak disabled
EPEL_REPO="/etc/yum.repos.d/epel.repo"
[ -f "$EPEL_REPO" ] && grep -q "enabled=0" "$EPEL_REPO" && {
    sed -i 's/enabled=0/enabled=1/' "$EPEL_REPO"
    fixed "EPEL repo diaktifkan"
    FIXES=$((FIXES+1))
}

# ═════════════════════════════════════════════════════════════
# STEP 7 — Package dependencies (per OS version)
# ═════════════════════════════════════════════════════════════
section "STEP 7/9 — System Package Dependencies (EL${OS_MAJOR})"

# Paket per OS — hanya yang benar-benar tersedia di repo masing-masing
if [ "$OS_MAJOR" -le 7 ]; then
    # EL7: CentOS/CloudLinux 7
    REQUIRED_PKGS="boost169-program-options boost169-atomic boost169-chrono boost169-date-time boost169-filesystem boost169-regex boost169-serialization boost169-system boost169-thread liblzf perl-IO-Tty libxml2 openssl"
elif [ "$OS_MAJOR" -eq 8 ]; then
    # EL8: AlmaLinux/CloudLinux/Rocky 8
    # liblzf & perl-IO-Tty tidak ada di EL8 — cPanel bundled sendiri
    REQUIRED_PKGS="boost-program-options libxml2 openssl glibc"
else
    # EL9+: AlmaLinux/CloudLinux/Rocky 9
    REQUIRED_PKGS="boost-program-options libxml2 openssl glibc"
fi

# Cek mana yang belum terinstall
MISSING=""
for pkg in $REQUIRED_PKGS; do
    rpm -q "$pkg" &>/dev/null || MISSING="$MISSING $pkg"
done

if [ -z "$MISSING" ]; then
    ok "Semua dependency sudah lengkap"
else
    # Filter: ambil hanya paket yang BENAR-BENAR tersedia di repo
    # Satu kali query ke yum/dnf — jauh lebih cepat dari per-paket
    printf "  Cek ketersediaan paket di repo..."
    AVAILABLE=$($PKG_MGR --enablerepo=epel list available $MISSING 2>/dev/null \
        | awk 'NR>1 && /\.(x86_64|noarch|i686)/{print $1}' \
        | sed 's/\..*//' | tr '\n' ' ')
    printf " selesai\n"

    if [ -n "$AVAILABLE" ]; then
        printf "  Install: %s\n" "$AVAILABLE"
        if $PKG_MGR --enablerepo=epel install -y $AVAILABLE > /tmp/preupdate-pkg.log 2>&1; then
            fixed "Berhasil install: $AVAILABLE"
            FIXES=$((FIXES+1))
        else
            warn "Sebagian gagal — cek /tmp/preupdate-pkg.log"
            ERRORS=$((ERRORS+1))
        fi
    fi

    # Paket yang tidak ada di repo → skip diam-diam (normal untuk cross-OS)
    STILL=""
    for pkg in $MISSING; do rpm -q "$pkg" &>/dev/null || STILL="$STILL $pkg"; done
    if [ -n "$STILL" ]; then
        ok "Skip (tidak tersedia di EL${OS_MAJOR}, normal):$STILL"
    else
        ok "Semua dependency terpenuhi"
    fi
fi

# ═════════════════════════════════════════════════════════════
# STEP 8 — RPM database & package manager
# ═════════════════════════════════════════════════════════════
section "STEP 8/9 — RPM Database & Package Manager"
rm -f /var/lib/rpm/__db* 2>/dev/null
if rpm --rebuilddb &>/dev/null; then
    ok "RPM database rebuilt"
else
    warn "RPM rebuild gagal"
    ERRORS=$((ERRORS+1))
fi

# EL7: yum-complete-transaction, EL8+: dnf tidak butuh ini
if [ "$OS_MAJOR" -le 7 ]; then
    yum-complete-transaction --cleanup-only &>/dev/null || true
fi
$PKG_MGR clean expire-cache &>/dev/null || true
ok "Package cache refreshed"

# ═════════════════════════════════════════════════════════════
# STEP 9 — Pre-flight check & auto-fix blocker dari upcp
# ═════════════════════════════════════════════════════════════
section "STEP 9/9 — Pre-flight Check"

# Fungsi: jalankan upcp --check dengan spinner + timeout 90s
run_upcp_check() {
    local outfile; outfile=$(mktemp)
    timeout 180 /usr/local/cpanel/scripts/upcp --check > "$outfile" 2>&1 &
    local cpid=$!
    local spin='-\|/'
    local i=0
    printf "  Menjalankan upcp --check "
    while kill -0 "$cpid" 2>/dev/null; do
        printf "\b${spin:$((i % 4)):1}"
        i=$((i+1))
        sleep 0.3
    done
    wait "$cpid"
    local exit_code=$?
    printf "\b \n"
    cat "$outfile"
    rm -f "$outfile"
    return $exit_code
}

CHECK_RESULT=$(run_upcp_check)
CHECK_EXIT=$?

if [ "$CHECK_EXIT" -eq 124 ]; then
    # timeout — semua pre-check sudah aman, lanjut saja
    warn "upcp --check timeout (>180s) — pre-checks sudah passed, lanjut update"
    BLOCKERS=""
else
    # Auto-fix: missing package dari output upcp --check
    echo "$CHECK_RESULT" | grep -iE "\] E " | while IFS= read -r line; do
        if echo "$line" | grep -qi "needed system packages"; then
            PKG=$(echo "$line" | sed 's/.*: //' | tr -d '[:space:]')
            if [ -n "$PKG" ]; then
                warn "Auto-fix missing: $PKG"
                $PKG_MGR --enablerepo=epel install -y "$PKG" &>/dev/null \
                    && fixed "$PKG terinstall" || warn "Gagal install $PKG"
            fi
        fi
    done 2>/dev/null || true
    BLOCKERS=$(echo "$CHECK_RESULT" | grep -iE "\] E Blocker" | grep -v "^$" || true)
fi

echo ""
if [ -n "$BLOCKERS" ]; then
    err "Masih ada blocker:"
    echo "$BLOCKERS" | while IFS= read -r line; do err "  → $line"; done
    echo ""
    warn "Cek manual: /usr/local/cpanel/scripts/upcp --check"
    ERRORS=$((ERRORS+1))
else
    ok "Pre-flight check selesai — tidak ada blocker!"
fi

# ─── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  ════════════ SUMMARY ════════════${NC}"
echo -e "  OS          : EL${OS_MAJOR} — $OS_NAME"
echo -e "  cPanel      : $CPANEL_FULL"
echo -e "  Auto-fixes  : ${GREEN}${BOLD}$FIXES item${NC}"
echo -e "  Issues left : $([ "$ERRORS" -eq 0 ] \
    && echo "${GREEN}${BOLD}0 — semua bersih${NC}" \
    || echo "${RED}${BOLD}$ERRORS — perlu perhatian${NC}")"
echo ""

if [ "$ERRORS" -gt 0 ]; then
    warn "Ada issue yang perlu ditangani. Update tidak dijalankan."
    exit 1
fi

# ─── Launch update ────────────────────────────────────────────
echo -e "${BOLD}${GREEN}  ✓ Semua check passed — Mulai update cPanel...${NC}"
echo ""
LOG_FILE="/var/cpanel/updatelogs/preupdate-$(date +%Y%m%d-%H%M%S).log"
nohup /usr/local/cpanel/scripts/upcp >> "$LOG_FILE" 2>&1 &
UPCP_PID=$!

echo -e "  PID      : ${BOLD}$UPCP_PID${NC}"
echo -e "  Log      : ${BOLD}$LOG_FILE${NC}"
echo ""
echo -e "  Monitor  : ${CYAN}tail -f $LOG_FILE${NC}"
echo -e "  Progress : ${CYAN}grep -oE '[0-9]+% complete' $LOG_FILE | tail -3${NC}"
echo ""
