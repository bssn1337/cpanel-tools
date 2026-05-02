#!/bin/bash
# =============================================================
#  WHM Domain & SSL Checker
#  Cek semua domain aktif di WHM beserta status SSL-nya
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
  ║      WHM Domain & SSL Checker  v1.0               ║
  ║      Rawon Hunter™ — Gatlab Security Research     ║
  ╚═══════════════════════════════════════════════════╝

BANNER

[ "$EUID" -ne 0 ]                 && { echo -e "  ${RED}✗${NC} Harus root"; exit 1; }
[ ! -f /usr/local/cpanel/cpanel ] && { echo -e "  ${RED}✗${NC} cPanel tidak ditemukan"; exit 1; }

SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo "unknown")
echo -e "${CYAN}  Server  :${NC} $(hostname) ($SERVER_IP)"
echo -e "${CYAN}  cPanel  :${NC} $CPANEL_VER"
echo -e "${CYAN}  Date    :${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ── Ambil data akun & SSL via Python ──────────────────────────
TMP_JSON=$(mktemp)
whmapi1 --output=json listaccts > "$TMP_JSON" 2>/dev/null

python3 - "$TMP_JSON" << 'PYEOF'
import json, sys, os, datetime, subprocess

data_file = sys.argv[1]
ssl_dir = "/var/cpanel/ssl/apache_tls"
today = datetime.datetime.utcnow()

RED    = '\033[0;31m'
GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
CYAN   = '\033[0;36m'
DIM    = '\033[2m'
BOLD   = '\033[1m'
NC     = '\033[0m'

try:
    d = json.load(open(data_file))
    all_accts = d['data']['acct']
except:
    print(RED + "  ✗ Gagal baca data akun dari whmapi1" + NC)
    sys.exit(1)

active  = [a for a in all_accts if a.get('suspended', 1) == 0]
suspended = [a for a in all_accts if a.get('suspended', 1) != 0]

ssl_valid   = []
ssl_expired = []
ssl_none    = []

for a in active:
    dom = a['domain']
    cert_file = os.path.join(ssl_dir, dom, 'certificates')
    if not os.path.isfile(cert_file):
        ssl_none.append((dom, a.get('user',''), a.get('ip','')))
        continue
    try:
        r = subprocess.Popen(
            ['openssl','x509','-noout','-enddate','-in', cert_file],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        out, _ = r.communicate()
        line = out.decode().strip()
        date_str = line.split('=', 1)[1].strip()
        exp = datetime.datetime.strptime(date_str, '%b %d %H:%M:%S %Y %Z')
        days = (exp - today).days
        if days > 0:
            ssl_valid.append((dom, days, a.get('user',''), a.get('ip','')))
        else:
            ssl_expired.append((dom, abs(days), a.get('user',''), a.get('ip','')))
    except:
        ssl_none.append((dom, a.get('user',''), a.get('ip','')))

# ── Summary ──
print(BOLD + CYAN + "  ════════ SUMMARY ════════" + NC)
print(f"  Total akun    : {BOLD}{len(all_accts)}{NC}")
print(f"  Aktif         : {GREEN}{BOLD}{len(active)}{NC}")
print(f"  Suspended     : {YELLOW}{BOLD}{len(suspended)}{NC}")
print(f"  SSL Valid     : {GREEN}{BOLD}{len(ssl_valid)}{NC}")
print(f"  SSL Expired   : {RED}{BOLD}{len(ssl_expired)}{NC}")
print(f"  Tanpa SSL     : {YELLOW}{BOLD}{len(ssl_none)}{NC}")
print("")

# ── SSL Valid ──
print(BOLD + GREEN + f"  ── SSL VALID ({len(ssl_valid)}) ──" + NC)
if ssl_valid:
    for dom, days, user, ip in sorted(ssl_valid, key=lambda x: x[1]):
        warn = YELLOW + "  !! <30 hari" + NC if days < 30 else ""
        bar_len = min(int(days / 3), 30)
        bar = GREEN + "█" * bar_len + DIM + "░" * (30 - bar_len) + NC
        print(f"  {GREEN}✓{NC} {BOLD}{dom:<45}{NC}  {bar}  {days} hari{warn}")
else:
    print(f"  {DIM}  (tidak ada){NC}")
print("")

# ── SSL Expired ──
print(BOLD + RED + f"  ── SSL EXPIRED ({len(ssl_expired)}) ──" + NC)
if ssl_expired:
    for dom, days, user, ip in sorted(ssl_expired, key=lambda x: x[1]):
        print(f"  {RED}✗{NC} {BOLD}{dom:<45}{NC}  expired {RED}{days}{NC} hari lalu")
else:
    print(f"  {DIM}  (tidak ada){NC}")
print("")

# ── Tanpa SSL ──
print(BOLD + YELLOW + f"  ── TANPA SSL ({len(ssl_none)}) ──" + NC)
if ssl_none:
    for dom, user, ip in ssl_none:
        print(f"  {YELLOW}⚠{NC} {dom:<45}  user: {DIM}{user}{NC}")
else:
    print(f"  {DIM}  (tidak ada){NC}")
print("")

# ── Suspended (ringkas) ──
if suspended:
    print(BOLD + f"  ── SUSPENDED ({len(suspended)}) ──" + NC)
    for a in suspended:
        print(f"  {DIM}  {a['domain']}{NC}")
    print("")

print(BOLD + CYAN + "  ════════════════════════════" + NC)
print(f"  Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("")
PYEOF

rm -f "$TMP_JSON"
