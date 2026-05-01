#!/bin/bash
# =============================================================
#  cPanel/WHM Pre-Update Fix
#  Universal: EL7 / EL8 / EL9 — cPanel semua versi
#
#  Filosofi: script tidak hardcode apapun tentang cPanel.
#  Hanya fix hal universal (disk/lock/config/EPEL/RPM),
#  lalu biarkan upcp yang tahu kebutuhannya sendiri.
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

FIXES=0; ERRORS=0

cat << 'BANNER'

  ╔═══════════════════════════════════════════════════╗
  ║      cPanel/WHM Pre-Update Fix  v2.0              ║
  ║      Universal — EL7/EL8/EL9 — All cPanel ver     ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

BANNER

# ── Sanity ────────────────────────────────────────────────────
[ "$EUID" -ne 0 ]                 && { err "Harus root"; exit 1; }
[ ! -f /usr/local/cpanel/cpanel ] && { err "cPanel tidak ditemukan"; exit 1; }

# ── Detect environment ────────────────────────────────────────
OS_NAME=$(cat /etc/redhat-release 2>/dev/null || echo "Unknown Linux")
OS_MAJOR=$(rpm -qf /etc/redhat-release --qf '%{version}' 2>/dev/null | grep -oE '^[0-9]+' || echo "7")
CPANEL_FULL=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo "unknown")
SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
PKG_MGR="yum"; [ "$OS_MAJOR" -ge 8 ] 2>/dev/null && PKG_MGR="dnf"

log "Server  : $(hostname) ($SERVER_IP)"
log "OS      : $OS_NAME (EL${OS_MAJOR})"
log "cPanel  : $CPANEL_FULL"
log "PkgMgr  : $PKG_MGR"

# ═══════════════════════════════════════════════════════════════
# STEP 1 — Upcp aktif?
# ═══════════════════════════════════════════════════════════════
section "STEP 1/6 — Cek Proses upcp"
SELF=$$
RUNNING=$(pgrep -af "upcp|updatenow" 2>/dev/null | grep -E "scripts/(upcp|updatenow)" | grep -v "$$\|preupdate\|--check" | grep -v "^$" || true)
if [ -n "$RUNNING" ]; then
    warn "upcp sedang berjalan:"
    echo "$RUNNING" | while IFS= read -r line; do warn "  $line"; done
    ACTIVE_LOG=$(ls -t /var/cpanel/updatelogs/*.log 2>/dev/null | /usr/bin/head -1)
    if [ -n "$ACTIVE_LOG" ]; then
        PROGRESS=$(grep -oE '[0-9]+% complete' "$ACTIVE_LOG" 2>/dev/null | /usr/bin/tail -1)
        warn "Log    : tail -f $ACTIVE_LOG"
        [ -n "$PROGRESS" ] && warn "Progress : $PROGRESS"
    fi
    echo ""; warn "Tunggu selesai lalu jalankan script ini lagi"; exit 0
else
    ok "Tidak ada upcp berjalan"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 2 — Disk space
# ═══════════════════════════════════════════════════════════════
section "STEP 2/6 — Disk Space"
for path in / /tmp /usr/local/cpanel /var; do
    avail=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4);print $4}')
    [ -z "$avail" ] && continue
    if [ "$avail" -lt 512 ]; then
        warn "$path hanya ${avail}MB — cleanup log lama..."
        find /var/cpanel/updatelogs -name "*.log" -mtime +7 -delete 2>/dev/null
        find /usr/local/cpanel/logs -name "*.log" -mtime +14 -delete 2>/dev/null
        find /tmp -maxdepth 1 \( -name "*.tmp" -o -name "cpanel-*" \) -mtime +1 -delete 2>/dev/null
        avail2=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4);print $4}')
        fixed "$path: ${avail}MB → ${avail2}MB"
        FIXES=$((FIXES+1))
        [ "$avail2" -lt 256 ] && { err "$path masih kritis — bersihkan manual"; ERRORS=$((ERRORS+1)); }
    else
        ok "$path : ${avail}MB"
    fi
done

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Config & blocking files
# ═══════════════════════════════════════════════════════════════
section "STEP 3/6 — Config & Lock Files"

# cpupdate.conf
CONF="/etc/cpupdate.conf"
if [ -f "$CONF" ]; then
    if grep -qi "^UPDATES=manual" "$CONF"; then
        sed -i 's/^UPDATES=manual/UPDATES=daily/I' "$CONF"
        fixed "UPDATES=manual → daily"; FIXES=$((FIXES+1))
    else
        ok "cpupdate.conf: $(grep -i '^UPDATES' "$CONF" | /usr/bin/head -1)"
    fi
    if grep -qi "^CPANEL=manual" "$CONF"; then
        CVER=$(/usr/local/cpanel/cpanel -V 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || echo "11.110")
        sed -i "s/^CPANEL=manual/CPANEL=${CVER}/I" "$CONF"
        fixed "CPANEL=manual → $CVER"; FIXES=$((FIXES+1))
    else
        ok "cpupdate.conf: $(grep -i '^CPANEL' "$CONF" | /usr/bin/head -1)"
    fi
else
    CVER=$(/usr/local/cpanel/cpanel -V 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || echo "11.110")
    printf "CPANEL=%s\nRPMUP=daily\nSARULESUP=daily\nUPDATES=daily\n" "$CVER" > "$CONF"
    fixed "cpupdate.conf dibuat"; FIXES=$((FIXES+1))
fi

# Touch files blocking update
for f in /etc/cpanelupdate /etc/nocpanelupdates /etc/cpanel_disable_update; do
    [ -f "$f" ] && { rm -f "$f"; fixed "Hapus blocking file: $f"; FIXES=$((FIXES+1)); }
done

# Stale lock
LOCK="/var/cpanel/updatenow.lock"
if [ -f "$LOCK" ]; then
    LPID=$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$LPID" ] && ! kill -0 "$LPID" 2>/dev/null; then
        rm -f "$LOCK"; fixed "Stale lock dihapus (PID $LPID tidak aktif)"; FIXES=$((FIXES+1))
    else
        warn "Lock aktif (PID $LPID masih jalan)"
    fi
else
    ok "Tidak ada lock file"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4 — EPEL (universal, dibutuhkan banyak dep cPanel)
# ═══════════════════════════════════════════════════════════════
section "STEP 4/6 — EPEL Repository"
if rpm -q epel-release &>/dev/null; then
    ok "EPEL terinstall: $(rpm -q epel-release)"
else
    warn "EPEL belum ada — install untuk EL${OS_MAJOR}..."
    if $PKG_MGR install -y epel-release &>/dev/null 2>&1; then
        fixed "EPEL terinstall"; FIXES=$((FIXES+1))
    else
        rpm -Uvh "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" &>/dev/null 2>&1 \
            && { fixed "EPEL terinstall via RPM"; FIXES=$((FIXES+1)); } \
            || { warn "EPEL gagal — beberapa dep mungkin tidak tersedia"; }
    fi
fi
# Aktifkan jika disabled
for repo in /etc/yum.repos.d/epel.repo /etc/yum.repos.d/epel-modular.repo; do
    [ -f "$repo" ] && grep -q "enabled=0" "$repo" && {
        sed -i 's/enabled=0/enabled=1/' "$repo"
        fixed "EPEL repo diaktifkan: $repo"; FIXES=$((FIXES+1))
    }
done

# ═══════════════════════════════════════════════════════════════
# STEP 5 — RPM database
# ═══════════════════════════════════════════════════════════════
section "STEP 5/6 — RPM Database"
rm -f /var/lib/rpm/__db* 2>/dev/null
rpm --rebuilddb &>/dev/null && ok "RPM database OK" || { warn "RPM rebuild gagal"; ERRORS=$((ERRORS+1)); }
[ "$OS_MAJOR" -le 7 ] && { yum-complete-transaction --cleanup-only &>/dev/null || true; }
$PKG_MGR clean expire-cache &>/dev/null || true
ok "Package cache refreshed"

# ═══════════════════════════════════════════════════════════════
# STEP 6 — Jalankan upcp --check, auto-fix apa yang dia minta
#           Tidak hardcode paket — biarkan cPanel yang tahu
# ═══════════════════════════════════════════════════════════════
section "STEP 6/6 — Pre-flight & Launch"

# Fungsi: install paket yang diminta oleh upcp --check output
fix_from_check() {
    local output="$1"

    # Pattern: "needed system packages were not installed: PKG1 PKG2 ..."
    echo "$output" | grep -oi "packages were not installed:.*" | sed 's/packages were not installed://I' | \
    while IFS= read -r pkgline; do
        pkgline=$(echo "$pkgline" | tr -d '\r' | xargs)
        [ -z "$pkgline" ] && continue
        warn "cPanel butuh paket: $pkgline"
        $PKG_MGR --enablerepo=epel install -y $pkgline &>/dev/null 2>&1 \
            && fixed "Installed: $pkgline" \
            || warn "Gagal install: $pkgline (mungkin tidak tersedia di EL${OS_MAJOR})"
    done

    # Pattern tunggal: "Cannot upgrade until ... package: PKG"
    echo "$output" | grep -oiE "package[s]?:? [a-zA-Z0-9_\.\-]+" | sed 's/package[s]*:* *//I' | \
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | xargs)
        [ -z "$pkg" ] && continue
        rpm -q "$pkg" &>/dev/null && continue
        $PKG_MGR --enablerepo=epel install -y "$pkg" &>/dev/null 2>&1 \
            && fixed "Installed: $pkg" || true
    done
}

# Jalankan upcp --check dengan spinner — tidak blocking karena ada timeout
CHECK_LOG=$(mktemp)
timeout 120 /usr/local/cpanel/scripts/upcp --check > "$CHECK_LOG" 2>&1 &
CHECK_PID=$!

printf "  Menjalankan upcp --check "
SPIN='-\|/'; i=0
while kill -0 "$CHECK_PID" 2>/dev/null; do
    printf "\b${SPIN:$((i%4)):1}"; i=$((i+1)); sleep 0.3
done
wait "$CHECK_PID"; CHECK_EXIT=$?; printf "\b \n"

if [ "$CHECK_EXIT" -eq 124 ]; then
    # Timeout — semua pre-check universal sudah passed → lanjut
    warn "upcp --check timeout — semua pre-check passed, langsung launch upcp"
    rm -f "$CHECK_LOG"
else
    CHECK_OUT=$(cat "$CHECK_LOG"); rm -f "$CHECK_LOG"
    BLOCKERS=$(echo "$CHECK_OUT" | grep -iE "\] E " | grep -v "^$" || true)

    if [ -n "$BLOCKERS" ]; then
        warn "Blocker ditemukan — auto-fix..."
        fix_from_check "$CHECK_OUT"

        # Satu re-check setelah fix
        printf "  Re-check "; CHECK_LOG2=$(mktemp)
        timeout 60 /usr/local/cpanel/scripts/upcp --check > "$CHECK_LOG2" 2>&1 &
        CP2=$!
        i=0; while kill -0 "$CP2" 2>/dev/null; do printf "\b${SPIN:$((i%4)):1}"; i=$((i+1)); sleep 0.3; done
        wait "$CP2"; EC2=$?; printf "\b \n"

        if [ "$EC2" -ne 124 ]; then
            REMAIN=$(cat "$CHECK_LOG2" | grep -iE "\] E Blocker" | grep -v "^$" || true)
            if [ -n "$REMAIN" ]; then
                err "Masih ada blocker:"; echo "$REMAIN" | while IFS= read -r l; do err "  → $l"; done
                warn "Cek manual: /usr/local/cpanel/scripts/upcp --check"
                rm -f "$CHECK_LOG2"; ERRORS=$((ERRORS+1))
            else
                ok "Blocker cleared!"
            fi
        else
            warn "Re-check timeout — lanjut saja"
        fi
        rm -f "$CHECK_LOG2"
    else
        ok "Tidak ada blocker"
    fi
fi

# ─── Summary & Launch ────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  ════════ SUMMARY ════════${NC}"
echo -e "  OS     : EL${OS_MAJOR} — $OS_NAME"
echo -e "  cPanel : $CPANEL_FULL"
echo -e "  Fixes  : ${GREEN}${BOLD}$FIXES item${NC}"
echo -e "  Errors : $([ "$ERRORS" -eq 0 ] \
    && echo "${GREEN}${BOLD}0${NC}" || echo "${RED}${BOLD}$ERRORS${NC}")"
echo ""

if [ "$ERRORS" -gt 0 ]; then
    err "Ada issue yang perlu fix manual — update tidak dijalankan"; exit 1
fi

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
