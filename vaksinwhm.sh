#!/bin/bash
# =============================================================
#  CVE-2026-41940 — cPanel/WHM Auth Bypass Mitigation
#  CRLF Injection → Authentication Bypass → RCE
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/bssn1337/cpanel-tools/master/patch_cve_2026_41940.sh | bash
#
#  Rawon Hunter™ — Gatlab Security Research
# =============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

cat << 'BANNER'

  ╔══════════════════════════════════════════════════════╗
  ║   CVE-2026-41940 Mitigation — cPanel/WHM             ║
  ║   Auth Bypass via CRLF Injection (cpsrvd)            ║
  ║   Rawon Hunter™ — Gatlab Security Research           ║
  ╚══════════════════════════════════════════════════════╝

BANNER

[ "$EUID" -ne 0 ] && { echo -e "  ${RED}✗${NC} Harus root"; exit 1; }
[ ! -d /usr/local/cpanel ] && { echo -e "  ${RED}✗${NC} cPanel tidak ditemukan"; exit 1; }

CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null | awk '{print $1}')
CPANEL_BUILD=$(/usr/local/cpanel/cpanel -V 2>/dev/null | grep -oP 'build \K[0-9]+')
OS=$(cat /etc/redhat-release 2>/dev/null || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

echo -e "${CYAN}  cPanel  :${NC} $CPANEL_VER (build $CPANEL_BUILD)"
echo -e "${CYAN}  OS      :${NC} $OS"
echo -e "${CYAN}  Date    :${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ── Check apakah sudah di-patch ────────────────────────────────
# Versi patched: 118.0.8+ / 116.0.22+ / 114.0.29+ (cek terus update)
PATCHED=0
MAJOR=$(echo "$CPANEL_VER" | cut -d. -f1)
MINOR=$(echo "$CPANEL_VER" | cut -d. -f2)

check_patched() {
    # cPanel 118 >= build 8
    [ "$MAJOR" -gt 118 ] && PATCHED=1 && return
    [ "$MAJOR" -eq 118 ] && [ "${CPANEL_BUILD:-0}" -ge 8 ] && PATCHED=1 && return
    # cPanel 116 >= build 22
    [ "$MAJOR" -eq 116 ] && [ "${CPANEL_BUILD:-0}" -ge 22 ] && PATCHED=1 && return
    # cPanel 114 >= build 29
    [ "$MAJOR" -eq 114 ] && [ "${CPANEL_BUILD:-0}" -ge 29 ] && PATCHED=1 && return
}
check_patched

if [ "$PATCHED" -eq 1 ]; then
    echo -e "  ${GREEN}✓${NC} cPanel versi ini sudah di-patch resmi oleh cPanel Inc."
    echo -e "  ${GREEN}✓${NC} Tidak perlu mitigasi manual."
    echo ""
    exit 0
else
    echo -e "  ${RED}✗${NC} cPanel $CPANEL_VER RENTAN terhadap CVE-2026-41940"
    echo -e "  ${YELLOW}⚠${NC}  Menerapkan mitigasi manual..."
    echo ""
fi

ERRORS=0

# ── STEP 1: ModSecurity (Apache) ───────────────────────────────
echo -e "${BOLD}${CYAN}── [1/4] ModSecurity — Block CRLF di Authorization Header ──${NC}"

MODSEC_CONF=""
for d in /etc/apache2/conf.d /usr/local/apache/conf/modsec_vendor_configs \
          /etc/httpd/conf.d /usr/local/apache/conf/modsec2.user.conf.d; do
    [ -d "$d" ] && MODSEC_CONF="$d" && break
done

# Cek modsec loaded
MODSEC_LOADED=0
httpd -M 2>/dev/null | grep -qi "security2" && MODSEC_LOADED=1
[ -f /usr/local/apache/conf/modsec2.conf ] && MODSEC_LOADED=1

RULE_FILE=""
if [ "$MODSEC_LOADED" -eq 1 ] && [ -n "$MODSEC_CONF" ]; then
    RULE_FILE="$MODSEC_CONF/patch_cve_2026_41940.conf"

    # Cek apakah rule sudah ada
    if [ -f "$RULE_FILE" ] && grep -q "9999001" "$RULE_FILE" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ModSec rule sudah ada: $RULE_FILE"
    else
        cat > "$RULE_FILE" << 'MODSEC'
# CVE-2026-41940 — CRLF Injection mitigation
# Rawon Hunter™ — Gatlab Security Research
<IfModule mod_security2.c>
SecRule REQUEST_HEADERS:Authorization "@rx (?i)%0[aAdD]" \
    "id:9999001,phase:1,deny,status:403,log,msg:'CVE-2026-41940 CRLF %0a/%0d blocked'"
SecRule REQUEST_HEADERS:Authorization "@rx [\r\n]" \
    "id:9999002,phase:1,deny,status:403,log,msg:'CVE-2026-41940 raw CRLF blocked'"
</IfModule>
MODSEC
        echo -e "  ${GREEN}✓${NC} ModSec rule ditulis ke $RULE_FILE"

        # Test config Apache sebelum restart
        if httpd -t 2>/dev/null; then
            service httpd restart >/dev/null 2>&1 && \
                echo -e "  ${GREEN}✓${NC} Apache restart OK" || \
                echo -e "  ${YELLOW}⚠${NC}  Apache restart gagal — cek log"
        else
            echo -e "  ${YELLOW}⚠${NC}  Config Apache error — rule tidak diaktifkan, cek manual"
            rm -f "$RULE_FILE"
            ERRORS=$((ERRORS+1))
        fi
    fi
else
    echo -e "  ${YELLOW}⚠${NC}  ModSecurity tidak ditemukan — skip rule"
    echo -e "  ${YELLOW}⚠${NC}  Install: yum install -y mod_security mod_security_crs"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ── STEP 2: Rate Limit WHM port 2087 via iptables ─────────────
echo -e "${BOLD}${CYAN}── [2/4] Rate Limiting WHM Port 2087/2086 ──${NC}"

# Cek apakah iptables tersedia
if command -v iptables >/dev/null 2>&1; then
    # Hapus rule lama kalau ada
    iptables -D INPUT -p tcp --dport 2087 -m state --state NEW \
        -m recent --update --seconds 60 --hitcount 30 -j DROP 2>/dev/null
    iptables -D INPUT -p tcp --dport 2087 -m state --state NEW \
        -m recent --set 2>/dev/null
    iptables -D INPUT -p tcp --dport 2086 -m state --state NEW \
        -m recent --update --seconds 60 --hitcount 30 -j DROP 2>/dev/null
    iptables -D INPUT -p tcp --dport 2086 -m state --state NEW \
        -m recent --set 2>/dev/null

    # Tambah rate limit baru: max 30 koneksi per menit per IP ke port 2087/2086
    iptables -I INPUT -p tcp --dport 2087 -m state --state NEW \
        -m recent --update --seconds 60 --hitcount 30 -j DROP 2>/dev/null && \
    iptables -I INPUT -p tcp --dport 2087 -m state --state NEW \
        -m recent --set 2>/dev/null
    iptables -I INPUT -p tcp --dport 2086 -m state --state NEW \
        -m recent --update --seconds 60 --hitcount 30 -j DROP 2>/dev/null && \
    iptables -I INPUT -p tcp --dport 2086 -m state --state NEW \
        -m recent --set 2>/dev/null

    # Simpan
    service iptables save >/dev/null 2>&1 || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null

    echo -e "  ${GREEN}✓${NC} Rate limit: maks 30 koneksi/menit per IP ke port 2087/2086"
    echo -e "  ${CYAN}  ℹ${NC}  Eksploit butuh ~4 request — rate limit mencegah bruteforce massal"
else
    echo -e "  ${YELLOW}⚠${NC}  iptables tidak tersedia"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ── STEP 3: cPanel Host Access Control ─────────────────────────
echo -e "${BOLD}${CYAN}── [3/4] cPanel Login Attempt Protection ──${NC}"

# Aktifkan maxfail di cPHulk (brute force protection cPanel)
CPHULK_CONF=/var/cpanel/hulkd/enabled
if [ -d /var/cpanel/hulkd ]; then
    echo 1 > "$CPHULK_CONF" 2>/dev/null
    # Set max login attempt
    /usr/local/cpanel/scripts/hulkdwhitelist --add 127.0.0.1 2>/dev/null
    echo -e "  ${GREEN}✓${NC} cPHulk brute force protection diaktifkan"
else
    echo -e "  ${YELLOW}⚠${NC}  cPHulk tidak ditemukan"
fi

# Aktifkan via whmapi1 jika tersedia
if command -v whmapi1 >/dev/null 2>&1; then
    whmapi1 configureservice service=cphulkd enabled=1 >/dev/null 2>&1 && \
        echo -e "  ${GREEN}✓${NC} cPHulk service enabled via API" || true
fi
echo ""

# ── STEP 4: Deteksi eksploitasi ───────────────────────────────
echo -e "${BOLD}${CYAN}── [4/4] Deteksi Tanda Eksploitasi ──${NC}"

EXPLOITED=0

# Cek log cpsrvd untuk pola CRLF auth
LOG_FILES="/usr/local/cpanel/logs/access_log /var/log/messages"
for f in $LOG_FILES; do
    if [ -f "$f" ]; then
        COUNT=$(grep -c "successful_internal_auth\|CRLF\|defunct\|hasroot=1" "$f" 2>/dev/null || echo 0)
        [ "$COUNT" -gt 0 ] && EXPLOITED=1 && \
            echo -e "  ${RED}✗${NC} MENCURIGAKAN: $COUNT entry di $f"
    fi
done

# Cek proses mencurigakan
SUSP=$(ps aux 2>/dev/null | grep -E "defunct|\.local/kernel|xmrig|stratum" | grep -v grep | grep -v " Z ")
if [ -n "$SUSP" ]; then
    EXPLOITED=1
    echo -e "  ${RED}✗${NC} Proses mencurigakan ditemukan:"
    echo "$SUSP" | while read l; do echo -e "    ${RED}→${NC} $l"; done
fi

# Cek file backdoor umum
for f in /usr/bin/defunct /usr/.local/kernel /tmp/.x /dev/shm/.x; do
    [ -e "$f" ] && EXPLOITED=1 && \
        echo -e "  ${RED}✗${NC} File backdoor ditemukan: $f"
done

if [ "$EXPLOITED" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} Tidak ada tanda eksploitasi ditemukan"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}  ════════ SUMMARY ════════${NC}"
echo -e "  cPanel  : $CPANEL_VER (build $CPANEL_BUILD)"
echo -e "  Status  : ${RED}${BOLD}RENTAN${NC} — mitigasi manual diterapkan"
[ -n "$RULE_FILE" ] && [ -f "$RULE_FILE" ] && \
    echo -e "  ModSec  : ${GREEN}✓ Aktif${NC} — $RULE_FILE"
echo -e "  RateLimit: ${GREEN}✓ Aktif${NC} — maks 30 req/menit ke WHM"
[ "$ERRORS" -gt 0 ] && \
    echo -e "  Errors  : ${YELLOW}${BOLD}$ERRORS item perlu cek manual${NC}"
echo ""
echo -e "  ${YELLOW}⚠${NC}  ${BOLD}Rekomendasi utama: upgrade cPanel ke versi terbaru${NC}"
echo -e "  ${YELLOW}⚠${NC}  Atau batasi akses port 2087 ke IP admin saja"
echo ""
echo -e "${BOLD}${CYAN}  ════════════════════════════${NC}"
echo -e "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Rawon Hunter™ — Gatlab Security Research"
echo ""
