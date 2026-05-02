#!/bin/bash
# =============================================================
#  WHM Domain & SSL Checker  v2.0
#  Pure bash — tanpa Python, tanpa jq, universal semua OS
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/bssn1337/cpanel-tools/master/sslcheck.sh | bash
#
#  Rawon Hunter™ — Gatlab Security Research
# =============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'

cat << 'BANNER'

  ╔═══════════════════════════════════════════════════╗
  ║      WHM Domain & SSL Checker  v2.0               ║
  ║      Pure Bash — Universal EL7/EL8/EL9            ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

BANNER

[ "$EUID" -ne 0 ]                 && { echo -e "  ${RED}✗${NC} Harus root"; exit 1; }
[ ! -d /var/cpanel/users ]        && { echo -e "  ${RED}✗${NC} cPanel tidak ditemukan"; exit 1; }

SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo "unknown")
NOW=$(date +%s)

echo -e "${CYAN}  Server  :${NC} $(hostname) ($SERVER_IP)"
echo -e "${CYAN}  cPanel  :${NC} $CPANEL_VER"
echo -e "${CYAN}  Date    :${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ── Counters ──────────────────────────────────────────────────
SSL_DIR="/var/cpanel/ssl/apache_tls"
USERS_DIR="/var/cpanel/users"
SUSPEND_DIR="/var/cpanel/suspended"

CNT_TOTAL=0; CNT_ACTIVE=0; CNT_SUSPENDED=0
CNT_VALID=0; CNT_EXPIRED=0; CNT_NOSSL=0

# ── Collect data ──────────────────────────────────────────────
VALID_LIST=""; EXPIRED_LIST=""; NOSSL_LIST=""; SUSPENDED_LIST=""

for user_file in "$USERS_DIR"/*; do
    [ -f "$user_file" ] || continue
    user=$(basename "$user_file")
    # Skip system/reseller meta files
    [[ "$user" == *.* ]] && continue

    domain=$(grep "^DNS=" "$user_file" 2>/dev/null | head -1 | cut -d= -f2)
    [ -z "$domain" ] && continue

    CNT_TOTAL=$((CNT_TOTAL+1))

    # Cek suspended
    if [ -f "$SUSPEND_DIR/$user" ]; then
        CNT_SUSPENDED=$((CNT_SUSPENDED+1))
        SUSPENDED_LIST="$SUSPENDED_LIST\n  ${DIM}  $domain${NC}"
        continue
    fi

    CNT_ACTIVE=$((CNT_ACTIVE+1))

    # Cek SSL cert
    CERT="$SSL_DIR/$domain/certificates"
    if [ ! -f "$CERT" ]; then
        CNT_NOSSL=$((CNT_NOSSL+1))
        NOSSL_LIST="$NOSSL_LIST\n  ${YELLOW}⚠${NC} $(printf '%-45s' "$domain")  user: ${DIM}$user${NC}"
        continue
    fi

    # Parse expiry date
    END_DATE=$(openssl x509 -noout -enddate -in "$CERT" 2>/dev/null | cut -d= -f2)
    if [ -z "$END_DATE" ]; then
        CNT_NOSSL=$((CNT_NOSSL+1))
        NOSSL_LIST="$NOSSL_LIST\n  ${YELLOW}⚠${NC} $(printf '%-45s' "$domain")  (cert error)"
        continue
    fi

    EXP=$(date -d "$END_DATE" +%s 2>/dev/null)
    if [ -z "$EXP" ]; then
        # Fallback untuk format date berbeda
        EXP=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" +%s 2>/dev/null || echo 0)
    fi

    DAYS=$(( (EXP - NOW) / 86400 ))

    if [ "$DAYS" -gt 0 ]; then
        CNT_VALID=$((CNT_VALID+1))
        # Progress bar
        BAR_LEN=$(( DAYS / 3 > 25 ? 25 : DAYS / 3 ))
        BAR=$(printf "${GREEN}%${BAR_LEN}s${NC}" | tr ' ' '█')
        [ "$BAR_LEN" -lt 25 ] && BAR="${BAR}$(printf "${DIM}%$((25 - BAR_LEN))s${NC}" | tr ' ' '░')"
        if [ "$DAYS" -lt 15 ]; then
            WARN="  ${RED}!! KRITIS${NC}"
        elif [ "$DAYS" -lt 30 ]; then
            WARN="  ${YELLOW}!! <30 hari${NC}"
        else
            WARN=""
        fi
        VALID_LIST="$VALID_LIST\n  ${GREEN}✓${NC} $(printf '%-45s' "$domain")  ${DAYS} hari${WARN}|$DAYS"
    else
        CNT_EXPIRED=$((CNT_EXPIRED+1))
        DAYS_AGO=$(( -DAYS ))
        EXPIRED_LIST="$EXPIRED_LIST\n  ${RED}✗${NC} $(printf '%-45s' "$domain")  expired ${RED}${DAYS_AGO}${NC} hari lalu|$DAYS_AGO"
    fi
done

# ── Sort & Print ───────────────────────────────────────────────
echo -e "${BOLD}${CYAN}  ════════ SUMMARY ════════${NC}"
echo -e "  Total akun    : ${BOLD}$CNT_TOTAL${NC}"
echo -e "  Aktif         : ${GREEN}${BOLD}$CNT_ACTIVE${NC}"
echo -e "  Suspended     : ${YELLOW}${BOLD}$CNT_SUSPENDED${NC}"
echo -e "  SSL Valid     : ${GREEN}${BOLD}$CNT_VALID${NC}"
echo -e "  SSL Expired   : ${RED}${BOLD}$CNT_EXPIRED${NC}"
echo -e "  Tanpa SSL     : ${YELLOW}${BOLD}$CNT_NOSSL${NC}"
echo ""

echo -e "${BOLD}${GREEN}  ── SSL VALID ($CNT_VALID) ──${NC}"
if [ -n "$VALID_LIST" ]; then
    # Sort by days (field after |)
    echo -e "$VALID_LIST" | grep -v '^$' | sort -t'|' -k2 -n | sed 's/|[0-9]*//'
else
    echo -e "  ${DIM}  (tidak ada)${NC}"
fi
echo ""

echo -e "${BOLD}${RED}  ── SSL EXPIRED ($CNT_EXPIRED) ──${NC}"
if [ -n "$EXPIRED_LIST" ]; then
    echo -e "$EXPIRED_LIST" | grep -v '^$' | sort -t'|' -k2 -n | sed 's/|[0-9]*//'
else
    echo -e "  ${DIM}  (tidak ada)${NC}"
fi
echo ""

echo -e "${BOLD}${YELLOW}  ── TANPA SSL ($CNT_NOSSL) ──${NC}"
if [ -n "$NOSSL_LIST" ]; then
    echo -e "$NOSSL_LIST" | grep -v '^$'
else
    echo -e "  ${DIM}  (tidak ada)${NC}"
fi
echo ""

if [ -n "$SUSPENDED_LIST" ]; then
    echo -e "${BOLD}  ── SUSPENDED ($CNT_SUSPENDED) ──${NC}"
    echo -e "$SUSPENDED_LIST" | grep -v '^$'
    echo ""
fi

echo -e "${BOLD}${CYAN}  ════════════════════════════${NC}"
echo -e "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
