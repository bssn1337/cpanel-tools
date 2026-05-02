#!/bin/bash
# =============================================================
#  CVE-2026-41940 — cPanel/WHM Auth Bypass Mitigation
#  CRLF Injection → Authentication Bypass → RCE
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/bssn1337/cpanel-tools/master/vaksinwhm.sh | bash
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
CPANEL_BUILD=$(/usr/local/cpanel/cpanel -V 2>/dev/null | grep -oP 'build \K[0-9]+' 2>/dev/null || \
               /usr/local/cpanel/cpanel -V 2>/dev/null | grep -o 'build [0-9]*' | awk '{print $2}')
OS=$(cat /etc/redhat-release 2>/dev/null || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

echo -e "${CYAN}  cPanel  :${NC} $CPANEL_VER (build $CPANEL_BUILD)"
echo -e "${CYAN}  OS      :${NC} $OS"
echo -e "${CYAN}  Date    :${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ── Check apakah sudah di-patch ────────────────────────────────
PATCHED=0
MAJOR=$(echo "$CPANEL_VER" | cut -d. -f1)

check_patched() {
    [ -z "$MAJOR" ] && return
    [ "$MAJOR" -gt 118 ] 2>/dev/null && PATCHED=1 && return
    [ "$MAJOR" -eq 118 ] 2>/dev/null && [ "${CPANEL_BUILD:-0}" -ge 8 ] && PATCHED=1 && return
    [ "$MAJOR" -eq 116 ] 2>/dev/null && [ "${CPANEL_BUILD:-0}" -ge 22 ] && PATCHED=1 && return
    [ "$MAJOR" -eq 114 ] 2>/dev/null && [ "${CPANEL_BUILD:-0}" -ge 29 ] && PATCHED=1 && return
}
check_patched

if [ "$PATCHED" -eq 1 ]; then
    echo -e "  ${GREEN}✓${NC} cPanel $CPANEL_VER sudah di-patch resmi — tidak perlu mitigasi manual."
    echo ""
    exit 0
else
    echo -e "  ${RED}✗${NC} cPanel $CPANEL_VER RENTAN terhadap CVE-2026-41940"
    echo -e "  ${YELLOW}⚠${NC}  Menerapkan mitigasi..."
    echo ""
fi

FIXES=0
ERRORS=0

# ── STEP 1: iptables String Matching (utama, tanpa perlu ModSec) ──
echo -e "${BOLD}${CYAN}── [1/4] iptables CRLF String Blocking (port 2087/2086) ──${NC}"

if command -v iptables >/dev/null 2>&1; then
    # Hapus rule lama biar tidak duplikat
    for PORT in 2087 2086; do
        iptables -D INPUT -p tcp --dport $PORT -m string --string "%0a" --algo bm -j DROP 2>/dev/null
        iptables -D INPUT -p tcp --dport $PORT -m string --string "%0d" --algo bm -j DROP 2>/dev/null
        iptables -D INPUT -p tcp --dport $PORT -m string --string "%0A" --algo bm -j DROP 2>/dev/null
        iptables -D INPUT -p tcp --dport $PORT -m string --string "%0D" --algo bm -j DROP 2>/dev/null
        iptables -D INPUT -p tcp --dport $PORT -m string --string "%0a%0d" --algo bm -j DROP 2>/dev/null
    done

    # Tambah rules baru
    OK=0
    for PORT in 2087 2086; do
        iptables -I INPUT -p tcp --dport $PORT -m string --string "%0a" --algo bm -j DROP 2>/dev/null && OK=$((OK+1))
        iptables -I INPUT -p tcp --dport $PORT -m string --string "%0d" --algo bm -j DROP 2>/dev/null
        iptables -I INPUT -p tcp --dport $PORT -m string --string "%0A" --algo bm -j DROP 2>/dev/null
        iptables -I INPUT -p tcp --dport $PORT -m string --string "%0D" --algo bm -j DROP 2>/dev/null
    done

    if [ "$OK" -gt 0 ]; then
        service iptables save >/dev/null 2>&1 || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        echo -e "  ${GREEN}✓${NC} iptables block %0a/%0d di port 2087/2086 — aktif"
        echo -e "  ${CYAN}  ℹ${NC}  Bekerja di kernel level, tidak butuh ModSecurity"
        FIXES=$((FIXES+1))
    else
        echo -e "  ${YELLOW}⚠${NC}  iptables string module tidak tersedia di kernel ini"
        ERRORS=$((ERRORS+1))
    fi

    # Rate limit tambahan
    for PORT in 2087 2086; do
        iptables -D INPUT -p tcp --dport $PORT -m state --state NEW \
            -m recent --update --seconds 60 --hitcount 30 -j DROP 2>/dev/null
        iptables -D INPUT -p tcp --dport $PORT -m state --state NEW \
            -m recent --set 2>/dev/null
        iptables -I INPUT -p tcp --dport $PORT -m state --state NEW \
            -m recent --update --seconds 60 --hitcount 30 -j DROP 2>/dev/null
        iptables -I INPUT -p tcp --dport $PORT -m state --state NEW \
            -m recent --set 2>/dev/null
    done
    echo -e "  ${GREEN}✓${NC} Rate limit: maks 30 koneksi/menit per IP ke WHM"
    service iptables save >/dev/null 2>&1 || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
else
    echo -e "  ${YELLOW}⚠${NC}  iptables tidak tersedia"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ── STEP 2: ModSecurity (fallback/tambahan untuk port 2082/2083) ──
echo -e "${BOLD}${CYAN}── [2/4] ModSecurity — CRLF Block (Apache layer) ──${NC}"

MODSEC_LOADED=0
httpd -M 2>/dev/null | grep -qi "security2" && MODSEC_LOADED=1
[ -f /usr/local/apache/conf/modsec2.conf ] && MODSEC_LOADED=1

MODSEC_CONF=""
for d in /usr/local/apache/conf/modsec2.user.conf.d \
          /etc/apache2/conf.d \
          /usr/local/apache/conf/modsec_vendor_configs \
          /etc/httpd/conf.d; do
    [ -d "$d" ] && MODSEC_CONF="$d" && break
done

if [ "$MODSEC_LOADED" -eq 1 ] && [ -n "$MODSEC_CONF" ]; then
    RULE_FILE="$MODSEC_CONF/vaksinwhm_cve_2026_41940.conf"
    if [ -f "$RULE_FILE" ] && grep -q "9999001" "$RULE_FILE" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ModSec rule sudah ada"
    else
        cat > "$RULE_FILE" << 'MODSEC'
# CVE-2026-41940 — CRLF Injection mitigation
# Rawon Hunter™ — Gatlab Security Research
<IfModule mod_security2.c>
SecRule REQUEST_HEADERS:Authorization "@rx (?i)%0[aAdD]" \
    "id:9999001,phase:1,deny,status:403,log,msg:'CVE-2026-41940 CRLF blocked'"
SecRule REQUEST_HEADERS:Authorization "@rx [\r\n]" \
    "id:9999002,phase:1,deny,status:403,log,msg:'CVE-2026-41940 raw CRLF blocked'"
</IfModule>
MODSEC
        if httpd -t 2>/dev/null; then
            service httpd restart >/dev/null 2>&1
            echo -e "  ${GREEN}✓${NC} ModSec rule aktif di $RULE_FILE"
            FIXES=$((FIXES+1))
        else
            rm -f "$RULE_FILE"
            echo -e "  ${YELLOW}⚠${NC}  Config Apache error — ModSec rule tidak diapply"
            ERRORS=$((ERRORS+1))
        fi
    fi
else
    echo -e "  ${YELLOW}⚠${NC}  ModSecurity tidak aktif — di-skip (iptables sudah cover)"
fi
echo ""

# ── STEP 3: cPHulk Brute Force Protection ─────────────────────
echo -e "${BOLD}${CYAN}── [3/4] cPHulk Brute Force Protection ──${NC}"

CPHULK_OK=0
if command -v whmapi1 >/dev/null 2>&1; then
    whmapi1 configureservice service=cphulkd enabled=1 >/dev/null 2>&1 && CPHULK_OK=1
fi
if [ -d /var/cpanel/hulkd ]; then
    echo 1 > /var/cpanel/hulkd/enabled 2>/dev/null && CPHULK_OK=1
    /usr/local/cpanel/scripts/hulkdwhitelist --add 127.0.0.1 >/dev/null 2>&1
fi

if [ "$CPHULK_OK" -eq 1 ]; then
    echo -e "  ${GREEN}✓${NC} cPHulk aktif — login gagal berulang akan di-ban otomatis"
    FIXES=$((FIXES+1))
else
    echo -e "  ${YELLOW}⚠${NC}  cPHulk tidak tersedia di versi ini"
fi
echo ""

# ── STEP 4: Scan tanda eksploitasi ────────────────────────────
echo -e "${BOLD}${CYAN}── [4/4] Scan Tanda Eksploitasi ──${NC}"

EXPLOITED=0

# Cek log akses cpsrvd
for f in /usr/local/cpanel/logs/access_log /var/log/messages /usr/local/cpanel/logs/error_log; do
    [ -f "$f" ] || continue
    COUNT=$(grep -c "successful_internal_auth\|hasroot=1\|tfa_verified=1" "$f" 2>/dev/null || echo 0)
    [ "$COUNT" -gt 0 ] && EXPLOITED=1 && \
        echo -e "  ${RED}✗${NC} Mencurigakan: $COUNT entri di $f"
done

# Cek proses mining/backdoor aktif
SUSP=$(ps aux 2>/dev/null | grep -E "defunct|\.local/kernel|xmrig|stratum\+tcp|minerd" \
       | grep -v grep | grep -v " Z ")
[ -n "$SUSP" ] && EXPLOITED=1 && \
    echo -e "  ${RED}✗${NC} Proses mencurigakan:" && \
    echo "$SUSP" | while IFS= read -r l; do echo -e "    ${RED}→${NC} $l"; done

# Cek file backdoor
for f in /usr/bin/defunct /usr/.local/kernel /etc/defunct.dat \
         /tmp/.x /dev/shm/.x /var/tmp/.x; do
    [ -e "$f" ] && EXPLOITED=1 && \
        echo -e "  ${RED}✗${NC} File backdoor: $f"
done

# Cek cronjob mencurigakan
SUSP_CRON=$(crontab -l 2>/dev/null | grep -E "base64|defunct|\.local/kernel" | head -3)
[ -n "$SUSP_CRON" ] && EXPLOITED=1 && \
    echo -e "  ${RED}✗${NC} Cronjob mencurigakan ditemukan"

[ "$EXPLOITED" -eq 0 ] && echo -e "  ${GREEN}✓${NC} Tidak ada tanda eksploitasi"
echo ""

# ── Summary ───────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}  ════════ SUMMARY ════════${NC}"
echo -e "  cPanel   : $CPANEL_VER (build $CPANEL_BUILD)"
echo -e "  Status   : ${RED}${BOLD}RENTAN${NC} — mitigasi diterapkan"
echo -e "  Fixes    : ${GREEN}${BOLD}$FIXES applied${NC}"
[ "$ERRORS" -gt 0 ] && echo -e "  Warnings : ${YELLOW}${BOLD}$ERRORS item${NC}"
[ "$EXPLOITED" -eq 1 ] && \
    echo -e "  ${RED}${BOLD}  !! Server kemungkinan sudah dieksploitasi — lakukan forensik!!${NC}"
echo ""
echo -e "  ${YELLOW}⚠${NC}  Upgrade cPanel ke versi terbaru untuk patch permanen"
echo ""
echo -e "${BOLD}${CYAN}  ════════════════════════════${NC}"
echo -e "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Rawon Hunter™ — Gatlab Security Research"
echo ""
