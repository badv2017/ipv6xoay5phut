#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR=/home/anhhungproxy
RAW_PREFIX=${1:-}
START_PORT=10000
END_PORT=14999
THREEPROXY_VERSION=0.9.4

if [[ -z $RAW_PREFIX && -t 0 ]]; then
    read -r -p "Nhập subnet IPv6 /48 (ví dụ 2a0a:8dc0:1f1::/48): " RAW_PREFIX
fi
if [[ -z $RAW_PREFIX ]]; then
    echo "Cách dùng: $0 <subnet-ipv6-/48>" >&2
    echo "Ví dụ: $0 2a0a:8dc0:1f1::/48" >&2
    exit 1
fi

# Chuẩn hóa mọi cách viết IPv6 hợp lệ thành ba hextet của network /48.
# Cũng chấp nhận dạng cũ chỉ có ba hextet, ví dụ: 2a0a:8dc0:1f1.
PREFIX=$(python - "$RAW_PREFIX" <<'PY'
# -*- coding: utf-8 -*-
from __future__ import print_function
import binascii
import socket
import sys

raw = sys.argv[1].strip().lower()
if '/' in raw:
    address, length = raw.rsplit('/', 1)
    if length != '48':
        sys.stderr.write('Subnet phải có prefix length /48\n')
        sys.exit(1)
else:
    address = raw
if address.count(':') == 2:
    address += '::'
try:
    packed = socket.inet_pton(socket.AF_INET6, address)
except socket.error:
    sys.stderr.write('IPv6 không hợp lệ: %s\n' % raw)
    sys.exit(1)
if int(binascii.hexlify(packed[6:]), 16) != 0:
    sys.stderr.write('Địa chỉ phải là network /48, các bit sau 48 phải bằng 0\n')
    sys.exit(1)
hex48 = binascii.hexlify(packed[:6]).decode('ascii')
print(':'.join(format(int(hex48[i:i+4], 16), 'x') for i in range(0, 12, 4)))
PY
)

IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
[[ -n $IFACE ]] || { echo "Không xác định được interface mặc định" >&2; exit 1; }
IFCFG="/etc/sysconfig/network-scripts/ifcfg-${IFACE}"
TRANSIT_ADDR=${TRANSIT_ADDR:-$(awk -F= '/^IPV6ADDR=/ {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$IFCFG" 2>/dev/null || true)}
TRANSIT_ADDR=${TRANSIT_ADDR:-$(ip -6 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')}
TRANSIT_GW=${TRANSIT_GW:-$(ip -6 route show default | awk '/default/ {print $3; exit}')}
[[ -n $TRANSIT_ADDR ]] || { echo "Không tìm thấy IPv6 transit trên $IFACE; đặt biến TRANSIT_ADDR=.../prefix" >&2; exit 1; }
[[ -n $TRANSIT_GW ]] || { echo "Không tìm thấy IPv6 gateway; đặt biến TRANSIT_GW=..." >&2; exit 1; }
IP4=$(curl -4fsS --max-time 15 https://ifconfig.co/ip | tr -d '[:space:]')
[[ $IP4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Không lấy được IPv4 public" >&2; exit 1; }

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[1/8] Cài gói hệ thống"
yum install -y gcc make wget curl cronie psmisc unbound firewalld

echo "[2/8] Cấu hình kernel và giới hạn file"
cat > /etc/sysctl.d/99-proxy-tune.conf <<'EOF'
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1000000
net.core.somaxconn = 65535
EOF
sysctl -p /etc/sysctl.d/99-proxy-tune.conf

echo "[3/8] Cấu hình và kiểm tra IPv6"
echo "Subnet proxy: ${PREFIX}::/48"
echo "Transit: $TRANSIT_ADDR via $TRANSIT_GW dev $IFACE"
ip -6 addr show dev "$IFACE" | grep -Fq "${TRANSIT_ADDR%/*}/" || ip -6 addr add "$TRANSIT_ADDR" dev "$IFACE"
ip -6 route replace default via "$TRANSIT_GW" dev "$IFACE" metric 1
ping6 -c 2 -W 3 "$TRANSIT_GW" >/dev/null

echo "[4/8] Cấu hình Unbound"
cp -a /etc/unbound/unbound.conf "/etc/unbound/unbound.conf.backup.$(date +%Y%m%d%H%M%S)"
cat > /etc/unbound/unbound.conf <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    access-control: 0.0.0.0/0 refuse
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes

forward-zone:
    name: "."
    forward-ssl-upstream: yes
    forward-first: no
    forward-addr: 1.1.1.1@853
    forward-addr: 1.0.0.1@853
EOF
unbound-checkconf
systemctl enable --now unbound

echo "[5/8] Biên dịch 3proxy"
if [[ ! -x /usr/local/etc/3proxy/bin/3proxy ]]; then
    archive="3proxy-${THREEPROXY_VERSION}.tar.gz"
    wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/${THREEPROXY_VERSION}.tar.gz" -O "$archive"
    tar -xzf "$archive"
    make -C "3proxy-${THREEPROXY_VERSION}" -f Makefile.Linux
    install -d /usr/local/etc/3proxy/{bin,logs,stat}
    if [[ -x 3proxy-${THREEPROXY_VERSION}/bin/3proxy ]]; then
        install -m 0755 "3proxy-${THREEPROXY_VERSION}/bin/3proxy" /usr/local/etc/3proxy/bin/3proxy
    else
        install -m 0755 "3proxy-${THREEPROXY_VERSION}/src/3proxy" /usr/local/etc/3proxy/bin/3proxy
    fi
fi

echo "[6/8] Sinh 5.000 tài khoản, IPv6 và cấu hình"
if [[ -s $WORKDIR/data_static.txt ]]; then
    echo "Gỡ các IPv6 proxy của lần cài trước"
    awk -F/ '{print $5}' "$WORKDIR/data_static.txt" | while IFS= read -r old_ip6; do
        [[ -n $old_ip6 ]] && ip -6 addr del "$old_ip6/128" dev "$IFACE" 2>/dev/null || true
    done
fi
: > "$WORKDIR/data_static.txt"
cat > "$WORKDIR/add_ipv6.sh" <<EOF
#!/usr/bin/env bash
set -e
IFACE='$IFACE'
EOF

# Sinh ngẫu nhiên đủ 80 bit (5 hextet) sau prefix /48. Hextet thứ 4
# được lấy không lặp, vì vậy 5.000 proxy cũng thuộc 5.000 subnet /64 khác nhau.
python - "$PREFIX" "$IP4" "$START_PORT" "$END_PORT" > "$WORKDIR/data_static.txt" <<'PY'
# -*- coding: utf-8 -*-
from __future__ import print_function
import binascii
import os
import random
import string
import sys

prefix, ipv4 = sys.argv[1], sys.argv[2]
start_port, end_port = int(sys.argv[3]), int(sys.argv[4])
count = end_port - start_port + 1
if count > 65536:
    raise SystemExit('Không thể tạo hơn 65.536 subnet /64 duy nhất trong một /48')

rng = random.SystemRandom()
fourth_hextets = rng.sample(range(65536), count)
alphabet = string.ascii_letters + string.digits

for offset, fourth in enumerate(fourth_hextets):
    port = start_port + offset
    password = ''.join(rng.choice(alphabet) for _ in range(12))
    tail_hex = binascii.hexlify(os.urandom(8)).decode('ascii')
    tail = [int(tail_hex[i:i + 4], 16) for i in range(0, 16, 4)]
    ipv6 = '%s:%x:%x:%x:%x:%x' % (
        prefix, fourth, tail[0], tail[1], tail[2], tail[3])
    print('user%d/%s/%s/%d/%s' % (port, password, ipv4, port, ipv6))
PY

awk -F/ '{print "ip -6 addr replace " $5 "/128 dev \"$IFACE\""}' \
    "$WORKDIR/data_static.txt" >> "$WORKDIR/add_ipv6.sh"
chmod 0700 "$WORKDIR/add_ipv6.sh"
"$WORKDIR/add_ipv6.sh"
awk -F/ '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDIR/data_static.txt" > "$WORKDIR/proxy.txt"
chmod 0600 "$WORKDIR/data_static.txt" "$WORKDIR/proxy.txt"

cfg=/usr/local/etc/3proxy/3proxy.cfg
cat > "$cfg" <<'EOF'
daemon
maxconn 10000
nserver 127.0.0.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65534
setuid 65534
auth strong
EOF
awk -F/ '{print "users " $1 ":CL:" $2}' "$WORKDIR/data_static.txt" >> "$cfg"
awk -F/ '{print "allow " $1; print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5; print "flush"}' "$WORKDIR/data_static.txt" >> "$cfg"

echo "[7/8] Cấu hình firewall và systemd"
systemctl enable --now firewalld
firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/tcp
firewall-cmd --add-port=${START_PORT}-${END_PORT}/tcp

cat > /etc/systemd/system/ipv6-proxy-addresses.service <<EOF
[Unit]
Description=Assign routed IPv6 addresses for 3proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$WORKDIR/add_ipv6.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/3proxy.service <<'EOF'
[Unit]
Description=3proxy proxy server
After=network-online.target unbound.service ipv6-proxy-addresses.service
Wants=network-online.target
Requires=ipv6-proxy-addresses.service

[Service]
Type=forking
ExecStartPre=/usr/bin/install -d -o 65534 -g 65534 -m 0755 /run/3proxy
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -USR1 $MAINPID
PIDFile=/var/run/3proxy/3proxy.pid
LimitNOFILE=200000
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# The pidfile directive lets systemd track the daemon reliably.
sed -i '2i pidfile /var/run/3proxy/3proxy.pid' "$cfg"
mkdir -p /var/run/3proxy
chown 65534:65534 /var/run/3proxy
systemctl daemon-reload
systemctl enable ipv6-proxy-addresses.service 3proxy.service

echo "[8/8] Khởi động và xác minh"
systemctl restart ipv6-proxy-addresses.service
systemctl restart 3proxy.service
for attempt in $(seq 1 30); do
    count=$(ss -lnt4 | awk '$4 ~ /:(1[0-4][0-9][0-9][0-9])$/ {n++} END {print n+0}')
    [[ $count -eq 5000 ]] && break
    sleep 1
done
systemctl --no-pager --full status 3proxy.service
[[ $count -eq 5000 ]] || { echo "Chỉ thấy $count/5000 cổng IPv6 listener" >&2; exit 1; }
unique_ip6=$(cut -d/ -f5 "$WORKDIR/data_static.txt" | sort -u | wc -l)
unique_64=$(cut -d/ -f5 "$WORKDIR/data_static.txt" | cut -d: -f1-4 | sort -u | wc -l)
[[ $unique_ip6 -eq 5000 ]] || { echo "Chỉ có $unique_ip6/5000 IPv6 duy nhất" >&2; exit 1; }
[[ $unique_64 -eq 5000 ]] || { echo "Chỉ có $unique_64/5000 subnet /64 duy nhất" >&2; exit 1; }

echo "Hoàn tất: $count proxy, $unique_ip6 IPv6 và $unique_64 subnet /64 duy nhất"
echo "Danh sách tại $WORKDIR/proxy.txt"
head -n 5 "$WORKDIR/proxy.txt"
