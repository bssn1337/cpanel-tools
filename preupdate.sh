#!/bin/bash
# =============================================================
#  cPanel/WHM Pre-Update Fix
#  Auto-fix common blockers before running upcp
#  Usage: curl -sL https://raw.githubusercontent.com/bssn1337/cpanel-tools/main/preupdate.sh | bash
#
#  Rawon Hunter™ — Gatlab Security Research
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
head() { echo -e "\n${BOLD}${CYAN}  ── $* ──${NC}"; }

banner() {
cat << 'EOF'

  ╔═══════════════════════════════════════════════════╗
  ║      cPanel/WHM Pre-Update Fix                    ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

EOF
}

banner

# ── Root check ────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Script harus dijalankan sebagai root"
    exit 1
fi

# ── Detect OS & cPanel ────────────────────────────────────────
OS_NAME=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY | cut -d'"' -f2 || echo "Unknown")
CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo "unknown")

log "Server  : $(hostname)"
log "OS      : $OS_NAME"
log "cPanel  : $CPANEL_VER"
log "IP      : $(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""

# Pastikan ini server cPanel
if [ ! -f /usr/local/cpanel/cpanel ]; then
    err "cPanel tidak ditemukan di server ini"
    exit 1
fi

# ── STEP 1: Disk space ────────────────────────────────────────
head "STEP 1/6 — Disk Space"
CLEANED=0
for path in / /tmp /usr/local/cpanel /var; do
    avail=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
    if [ -z "$avail" ]; then continue; fi
    if [ "$avail" -lt 512 ]; then
        warn "$path hanya ${avail}MB — bersihkan log lama..."
        find /var/cpanel/updatelogs -name "*.log" -mtime +7 -delete 2>/dev/null && CLEANED=$((CLEANED+1))
        find /usr/local/cpanel/logs -name "*.log" -mtime +14 -delete 2>/dev/null && CLEANED=$((CLEANED+1))
        find /tmp -name "*.tmp" -mtime +1 -delete 2>/dev/null
        avail_new=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
        ok "$path setelah cleanup: ${avail_new}MB"
    else
        ok "$path : ${avail}MB tersedia"
    fi
done

# ── STEP 2: EPEL repo ─────────────────────────────────────────
head "STEP 2/6 — EPEL Repository"
if rpm -q epel-release &>/dev/null; then
    ok "EPEL sudah terinstall ($(rpm -q epel-release))"
else
    warn "EPEL belum ada, menginstall..."
    if yum install -y epel-release &>/dev/null; then
        ok "EPEL berhasil diinstall"
    else
        warn "Coba via RPM langsung..."
        rpm -Uvh "https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm" &>/dev/null \
            && ok "EPEL terinstall via RPM" \
            || warn "EPEL gagal — beberapa paket mungkin tidak tersedia"
    fi
fi

# ── STEP 3: Paket dependency ──────────────────────────────────
head "STEP 3/6 — System Packages"

# Semua paket yang diketahui jadi blocker cPanel
REQUIRED_PKGS="
boost169-program-options
boost169-atomic
boost169-chrono
boost169-date-time
boost169-filesystem
boost169-regex
boost169-serialization
boost169-system
boost169-thread
liblzf
perl-IO-Tty
libxml2
openssl
"

MISSING=""
for pkg in $REQUIRED_PKGS; do
    pkg=$(echo "$pkg" | tr -d '[:space:]')
    [ -z "$pkg" ] && continue
    if ! rpm -q "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    warn "Paket kurang:$MISSING"
    echo ""
    if yum --enablerepo=epel install -y $MISSING > /tmp/cpanel-preupdate-yum.log 2>&1; then
        ok "Semua paket berhasil diinstall"
    else
        warn "Beberapa paket mungkin tidak tersedia:"
        grep -iE "no package|error" /tmp/cpanel-preupdate-yum.log 2>/dev/null | grep -v "^$" | head -5 | while IFS= read -r line; do
            warn "  $line"
        done
    fi
    # Verifikasi ulang
    STILL_MISSING=""
    for pkg in $MISSING; do
        pkg=$(echo "$pkg" | tr -d '[:space:]')
        [ -z "$pkg" ] && continue
        if ! rpm -q "$pkg" &>/dev/null; then
            STILL_MISSING="$STILL_MISSING $pkg"
        fi
    done
    if [ -n "$STILL_MISSING" ]; then
        warn "Masih belum terinstall:$STILL_MISSING"
    else
        ok "Semua paket dependency terpenuhi"
    fi
else
    ok "Semua paket dependency sudah lengkap"
fi

# ── STEP 4: RPM & YUM consistency ────────────────────────────
head "STEP 4/6 — RPM Database & YUM"
yum-complete-transaction --cleanup-only &>/dev/null || true
if rpm --rebuilddb &>/dev/null; then
    ok "RPM database rebuilt"
else
    warn "RPM rebuild gagal — mungkin ada lock file"
    rm -f /var/lib/rpm/__db* 2>/dev/null
    rpm --rebuilddb &>/dev/null && ok "RPM database rebuilt (setelah clear lock)" || warn "RPM rebuild masih gagal"
fi
# Bersihkan yum cache kalau ada masalah
yum clean expire-cache &>/dev/null || true
ok "YUM cache refreshed"

# ── STEP 5: Cek proses upcp aktif ────────────────────────────
head "STEP 5/6 — Cek Proses upcp"
RUNNING_UPCP=$(pgrep -f "upcp|updatenow" 2>/dev/null | grep -v $$ | tr '\n' ' ' || true)
if [ -n "$RUNNING_UPCP" ]; then
    warn "Ada proses upcp yang sedang berjalan: PID $RUNNING_UPCP"
    ACTIVE_LOG=$(ls -t /var/cpanel/updatelogs/*.log 2>/dev/null | head -1)
    warn "Monitor log: tail -f $ACTIVE_LOG"
    warn ""
    warn "Tunggu proses ini selesai, lalu jalankan script ini lagi"
    echo ""
    exit 0
else
    ok "Tidak ada proses upcp yang berjalan"
fi

# ── STEP 6: Pre-flight check & update ────────────────────────
head "STEP 6/6 — Pre-flight Check"
CHECK_RESULT=$(/usr/local/cpanel/scripts/upcp --check 2>&1)
BLOCKERS=$(echo "$CHECK_RESULT" | grep -iE "^\[.*\] E (Blocker|.*error)" | grep -v "^$" || true)

if [ -n "$BLOCKERS" ]; then
    err "Masih ada blocker yang tidak bisa di-fix otomatis:"
    echo "$BLOCKERS" | while IFS= read -r line; do err "  $line"; done
    echo ""
    warn "Jalankan manual: /usr/local/cpanel/scripts/upcp --check"
    exit 1
fi

ok "Pre-flight check clear — tidak ada blocker!"
echo ""
echo -e "${BOLD}${GREEN}  ════ Semua check passed! Mulai update cPanel... ════${NC}"
echo ""

LOG_FILE="/var/cpanel/updatelogs/preupdate-$(date +%Y%m%d-%H%M%S).log"
nohup /usr/local/cpanel/scripts/upcp >> "$LOG_FILE" 2>&1 &
UPCP_PID=$!

echo -e "  ${GREEN}✓ upcp berjalan di background${NC}"
echo ""
echo -e "  PID      : ${BOLD}$UPCP_PID${NC}"
echo -e "  Log      : ${BOLD}$LOG_FILE${NC}"
echo ""
echo -e "  Monitor  : ${CYAN}tail -f $LOG_FILE${NC}"
echo -e "  Progress : ${CYAN}grep -E 'complete|ERROR' $LOG_FILE | tail -5${NC}"
echo -e "  Selesai? : ${CYAN}ps --pid $UPCP_PID${NC}"
echo ""
