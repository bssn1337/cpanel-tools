#!/bin/bash
# =============================================================
#  WHM Domain & SSL Checker v3.0
#  DNS + HTTP/HTTPS + SSL Checker
#  Pure Bash — tanpa Python, tanpa jq
#
#  Usage:
#    bash sslcheck.sh
#
#  Fungsi:
#    - Membaca domain dari /etc/userdomains
#    - Validasi DNS publik
#    - Mendeteksi NXDOMAIN / DNS tidak resolve
#    - Cek HTTPS dan fallback HTTP
#    - Membedakan DNS aktif dan Web aktif
#    - Cek SSL certificate dan expiry
#    - Deteksi suspended account
#
#  Rawon Hunter™ — Gatlab Security Research
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

cat << 'BANNER'

  ╔═══════════════════════════════════════════════════╗
  ║      WHM Domain & SSL Checker  v3.0               ║
  ║      DNS + HTTP/HTTPS + SSL Checker               ║
  ║      Pure Bash — Universal EL7/EL8/EL9            ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

BANNER


# =============================================================
# REQUIREMENTS
# =============================================================

[ "$EUID" -ne 0 ] && {
    echo -e "  ${RED}✗${NC} Harus root"
    exit 1
}

[ ! -d /var/cpanel/users ] && {
    echo -e "  ${RED}✗${NC} cPanel tidak ditemukan"
    exit 1
}

[ ! -f /etc/userdomains ] && {
    echo -e "  ${RED}✗${NC} /etc/userdomains tidak ditemukan"
    exit 1
}


# =============================================================
# SERVER INFORMATION
# =============================================================

SERVER_IP=$(curl -s4 \
    --connect-timeout 5 \
    ifconfig.me 2>/dev/null)

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

CPANEL_VER=$(
    /usr/local/cpanel/cpanel -V 2>/dev/null ||
    echo "unknown"
)

NOW=$(date +%s)


echo -e "${CYAN}  Server  :${NC} $(hostname) ($SERVER_IP)"
echo -e "${CYAN}  cPanel  :${NC} $CPANEL_VER"
echo -e "${CYAN}  Date    :${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""


# =============================================================
# CONFIGURATION
# =============================================================

SSL_DIR="/var/cpanel/ssl/apache_tls"
USERS_DIR="/var/cpanel/users"
SUSPEND_DIR="/var/cpanel/suspended"

DNS_TIMEOUT=3
HTTP_TIMEOUT=10

# Public DNS resolver
DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="8.8.8.8"


# =============================================================
# COUNTERS
# =============================================================

CNT_TOTAL=0

CNT_DNS_ACTIVE=0
CNT_DNS_DEAD=0

CNT_HTTP_ACTIVE=0
CNT_HTTP_DEAD=0

CNT_SUSPENDED=0

CNT_VALID=0
CNT_EXPIRED=0
CNT_NOSSL=0


# =============================================================
# LIST STORAGE
# =============================================================

VALID_LIST=""
EXPIRED_LIST=""
NOSSL_LIST=""

DNS_DEAD_LIST=""
HTTP_DEAD_LIST=""

SUSPENDED_LIST=""

SEEN_USERS=""


# =============================================================
# CHECK DNS
# =============================================================

check_dns() {

    local domain="$1"
    local result=""

    # ---------------------------------------------------------
    # Prefer dig
    # ---------------------------------------------------------

    if command -v dig >/dev/null 2>&1; then

        # A record
        result=$(
            dig \
                @"$DNS_PRIMARY" \
                "$domain" \
                A \
                +short \
                +time="$DNS_TIMEOUT" \
                +tries=1 \
                2>/dev/null
        )

        if [ -n "$result" ]; then
            return 0
        fi


        # AAAA record
        result=$(
            dig \
                @"$DNS_PRIMARY" \
                "$domain" \
                AAAA \
                +short \
                +time="$DNS_TIMEOUT" \
                +tries=1 \
                2>/dev/null
        )

        if [ -n "$result" ]; then
            return 0
        fi


        # Secondary DNS - A
        result=$(
            dig \
                @"$DNS_SECONDARY" \
                "$domain" \
                A \
                +short \
                +time="$DNS_TIMEOUT" \
                +tries=1 \
                2>/dev/null
        )

        if [ -n "$result" ]; then
            return 0
        fi


        # Secondary DNS - AAAA
        result=$(
            dig \
                @"$DNS_SECONDARY" \
                "$domain" \
                AAAA \
                +short \
                +time="$DNS_TIMEOUT" \
                +tries=1 \
                2>/dev/null
        )

        if [ -n "$result" ]; then
            return 0
        fi


        return 1
    fi


    # =========================================================
    # Fallback: getent
    # =========================================================

    if command -v getent >/dev/null 2>&1; then

        if getent ahosts "$domain" >/dev/null 2>&1; then
            return 0
        fi

    fi


    # =========================================================
    # Fallback: host
    # =========================================================

    if command -v host >/dev/null 2>&1; then

        if host "$domain" >/dev/null 2>&1; then
            return 0
        fi

    fi


    return 1
}


# =============================================================
# CHECK HTTP / HTTPS
# =============================================================

check_http() {

    local domain="$1"

    HTTP_CODE=""
    REMOTE_IP=""
    FINAL_URL=""
    PROTOCOL=""


    # =========================================================
    # HTTPS
    # =========================================================

    HTTP_RESULT=$(
        curl \
            -k \
            -L \
            -sS \
            -o /dev/null \
            -w '%{http_code}|%{remote_ip}|%{url_effective}' \
            --connect-timeout "$HTTP_TIMEOUT" \
            --max-time "$HTTP_TIMEOUT" \
            "https://$domain" \
            2>/dev/null
    )


    HTTP_CODE=$(echo "$HTTP_RESULT" | cut -d'|' -f1)
    REMOTE_IP=$(echo "$HTTP_RESULT" | cut -d'|' -f2)
    FINAL_URL=$(echo "$HTTP_RESULT" | cut -d'|' -f3)


    case "$HTTP_CODE" in

        2*|3*|4*|5*)

            PROTOCOL="HTTPS"

            return 0

            ;;

    esac


    # =========================================================
    # HTTP FALLBACK
    # =========================================================

    HTTP_RESULT=$(
        curl \
            -L \
            -sS \
            -o /dev/null \
            -w '%{http_code}|%{remote_ip}|%{url_effective}' \
            --connect-timeout "$HTTP_TIMEOUT" \
            --max-time "$HTTP_TIMEOUT" \
            "http://$domain" \
            2>/dev/null
    )


    HTTP_CODE=$(echo "$HTTP_RESULT" | cut -d'|' -f1)
    REMOTE_IP=$(echo "$HTTP_RESULT" | cut -d'|' -f2)
    FINAL_URL=$(echo "$HTTP_RESULT" | cut -d'|' -f3)


    case "$HTTP_CODE" in

        2*|3*|4*|5*)

            PROTOCOL="HTTP"

            return 0

            ;;

    esac


    return 1
}


# =============================================================
# START SCANNING
# =============================================================

echo -e "${BOLD}${CYAN}  ── SCANNING DOMAINS ──${NC}"
echo ""


while IFS=': ' read -r domain user _; do

    # ---------------------------------------------------------
    # Basic validation
    # ---------------------------------------------------------

    [ -z "$domain" ] && continue
    [ -z "$user" ] && continue

    [ "$user" = "nobody" ] && continue

    [[ "$domain" == \#* ]] && continue


    # ---------------------------------------------------------
    # Suspended account
    # ---------------------------------------------------------

    if [ -f "$SUSPEND_DIR/$user" ]; then

        if ! echo "$SEEN_USERS" | grep -qx "SUSP_$user"; then

            CNT_SUSPENDED=$((CNT_SUSPENDED + 1))

            SEEN_USERS="$SEEN_USERS
SUSP_$user"


            MAIN_DOM=$(
                grep "^DNS=" "$USERS_DIR/$user" 2>/dev/null |
                head -1 |
                cut -d= -f2
            )


            SUSPENDED_LIST="$SUSPENDED_LIST
  ${DIM}  ${MAIN_DOM:-$user}${NC}"

        fi

        continue

    fi


    CNT_TOTAL=$((CNT_TOTAL + 1))


    # =========================================================
    # DNS CHECK
    # =========================================================

    if ! check_dns "$domain"; then

        CNT_DNS_DEAD=$((CNT_DNS_DEAD + 1))


        DNS_DEAD_LIST="$DNS_DEAD_LIST
  ${RED}✗${NC} $(printf '%-50s' "$domain")  ${RED}DNS tidak resolve${NC}"


        continue

    fi


    CNT_DNS_ACTIVE=$((CNT_DNS_ACTIVE + 1))


    # =========================================================
    # HTTP / HTTPS CHECK
    # =========================================================

    if check_http "$domain"; then

        CNT_HTTP_ACTIVE=$((CNT_HTTP_ACTIVE + 1))

        WEB_STATUS="${GREEN}${PROTOCOL} ${HTTP_CODE}${NC}"

    else

        CNT_HTTP_DEAD=$((CNT_HTTP_DEAD + 1))


        HTTP_DEAD_LIST="$HTTP_DEAD_LIST
  ${YELLOW}⚠${NC} $(printf '%-50s' "$domain")  ${YELLOW}DNS OK, WEB tidak merespons${NC}"


        WEB_STATUS="${YELLOW}WEB DOWN${NC}"

    fi


    # =========================================================
    # SSL CERTIFICATE CHECK
    # =========================================================

    CERT="$SSL_DIR/$domain/certificates"


    if [ ! -f "$CERT" ]; then

        CNT_NOSSL=$((CNT_NOSSL + 1))


        NOSSL_LIST="$NOSSL_LIST
  ${YELLOW}⚠${NC} $(printf '%-50s' "$domain")  ${WEB_STATUS}  user: ${DIM}$user${NC}"


        continue

    fi


    # =========================================================
    # PARSE SSL EXPIRY
    # =========================================================

    END_DATE=$(
        openssl x509 \
            -noout \
            -enddate \
            -in "$CERT" \
            2>/dev/null |
        cut -d= -f2
    )


    if [ -z "$END_DATE" ]; then

        CNT_NOSSL=$((CNT_NOSSL + 1))


        NOSSL_LIST="$NOSSL_LIST
  ${YELLOW}⚠${NC} $(printf '%-50s' "$domain")  ${WEB_STATUS}  ${RED}cert error${NC}"


        continue

    fi


    # =========================================================
    # CONVERT EXPIRY DATE
    # =========================================================

    EXP=$(date -d "$END_DATE" +%s 2>/dev/null)


    if [ -z "$EXP" ]; then

        EXP=$(
            date \
                -j \
                -f "%b %d %T %Y %Z" \
                "$END_DATE" \
                +%s \
                2>/dev/null
        )

    fi


    [ -z "$EXP" ] && EXP=0


    DAYS=$(( (EXP - NOW) / 86400 ))


    # =========================================================
    # SSL VALID
    # =========================================================

    if [ "$DAYS" -gt 0 ]; then

        CNT_VALID=$((CNT_VALID + 1))


        # -----------------------------------------------------
        # Progress bar
        # -----------------------------------------------------

        BAR_LEN=$(( DAYS / 3 ))

        if [ "$BAR_LEN" -gt 25 ]; then
            BAR_LEN=25
        fi

        if [ "$BAR_LEN" -lt 0 ]; then
            BAR_LEN=0
        fi


        BAR=$(printf "%${BAR_LEN}s" "" | tr ' ' '█')


        REMAINING=$((25 - BAR_LEN))


        if [ "$REMAINING" -gt 0 ]; then

            BAR="${BAR}$(printf "%${REMAINING}s" "" | tr ' ' '░')"

        fi


        # -----------------------------------------------------
        # Warning
        # -----------------------------------------------------

        WARN=""


        if [ "$DAYS" -lt 15 ]; then

            WARN="  ${RED}!! KRITIS${NC}"

        elif [ "$DAYS" -lt 30 ]; then

            WARN="  ${YELLOW}!! <30 hari${NC}"

        fi


        VALID_LIST="$VALID_LIST
  ${GREEN}✓${NC} $(printf '%-50s' "$domain")  ${DAYS} hari  ${WEB_STATUS}${WARN}|$DAYS"


    else

        # =====================================================
        # SSL EXPIRED
        # =====================================================

        CNT_EXPIRED=$((CNT_EXPIRED + 1))


        DAYS_AGO=$(( -DAYS ))


        EXPIRED_LIST="$EXPIRED_LIST
  ${RED}✗${NC} $(printf '%-50s' "$domain")  expired ${RED}${DAYS_AGO}${NC} hari lalu  ${WEB_STATUS}|$DAYS_AGO"


    fi


done < /etc/userdomains


# =============================================================
# SUMMARY
# =============================================================

echo ""
echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}                 SUMMARY                      ${NC}"
echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════${NC}"

echo -e "  Total domain       : ${BOLD}$CNT_TOTAL${NC}"
echo -e "  DNS aktif          : ${GREEN}${BOLD}$CNT_DNS_ACTIVE${NC}"
echo -e "  DNS tidak resolve  : ${RED}${BOLD}$CNT_DNS_DEAD${NC}"
echo -e "  Web aktif          : ${GREEN}${BOLD}$CNT_HTTP_ACTIVE${NC}"
echo -e "  Web tidak respon   : ${YELLOW}${BOLD}$CNT_HTTP_DEAD${NC}"
echo -e "  Akun suspend       : ${YELLOW}${BOLD}$CNT_SUSPENDED${NC}"
echo -e "  SSL Valid          : ${GREEN}${BOLD}$CNT_VALID${NC}"
echo -e "  SSL Expired        : ${RED}${BOLD}$CNT_EXPIRED${NC}"
echo -e "  Tanpa SSL          : ${YELLOW}${BOLD}$CNT_NOSSL${NC}"

echo ""


# =============================================================
# DNS DEAD
# =============================================================

echo -e "${BOLD}${RED}  ── DNS TIDAK RESOLVE ($CNT_DNS_DEAD) ──${NC}"


if [ -n "$DNS_DEAD_LIST" ]; then

    echo -e "$DNS_DEAD_LIST" |
        grep -v '^$'

else

    echo -e "  ${DIM}(tidak ada)${NC}"

fi


echo ""


# =============================================================
# WEB DEAD
# =============================================================

echo -e "${BOLD}${YELLOW}  ── DNS OK, WEB TIDAK MERESPONS ($CNT_HTTP_DEAD) ──${NC}"


if [ -n "$HTTP_DEAD_LIST" ]; then

    echo -e "$HTTP_DEAD_LIST" |
        grep -v '^$'

else

    echo -e "  ${DIM}(tidak ada)${NC}"

fi


echo ""


# =============================================================
# SSL VALID
# =============================================================

echo -e "${BOLD}${GREEN}  ── SSL VALID ($CNT_VALID) ──${NC}"


if [ -n "$VALID_LIST" ]; then

    echo -e "$VALID_LIST" |
        grep -v '^$' |
        sort -t'|' -k2 -n |
        sed 's/|[0-9]*$//'

else

    echo -e "  ${DIM}(tidak ada)${NC}"

fi


echo ""


# =============================================================
# SSL EXPIRED
# =============================================================

echo -e "${BOLD}${RED}  ── SSL EXPIRED ($CNT_EXPIRED) ──${NC}"


if [ -n "$EXPIRED_LIST" ]; then

    echo -e "$EXPIRED_LIST" |
        grep -v '^$' |
        sort -t'|' -k2 -n |
        sed 's/|[0-9]*$//'

else

    echo -e "  ${DIM}(tidak ada)${NC}"

fi


echo ""


# =============================================================
# NO SSL
# =============================================================

echo -e "${BOLD}${YELLOW}  ── TANPA SSL ($CNT_NOSSL) ──${NC}"


if [ -n "$NOSSL_LIST" ]; then

    echo -e "$NOSSL_LIST" |
        grep -v '^$'

else

    echo -e "  ${DIM}(tidak ada)${NC}"

fi


echo ""


# =============================================================
# SUSPENDED
# =============================================================

if [ -n "$SUSPENDED_LIST" ]; then

    echo -e "${BOLD}  ── SUSPENDED ($CNT_SUSPENDED) ──${NC}"

    echo -e "$SUSPENDED_LIST" |
        grep -v '^$'

    echo ""

fi


# =============================================================
# FINISH
# =============================================================

echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════${NC}"
echo -e "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════${NC}"
echo ""
