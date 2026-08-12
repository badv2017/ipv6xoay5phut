#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

RAW_IP6="$1"

# Kiểm tra đầu vào IPv6
while [ -z "$RAW_IP6" ]; do
    read -p "Nhập subnet IPv6 /48 (ví dụ 2a0a:8dc0:276): " RAW_IP6
    RAW_IP6=$(echo "$RAW_IP6" | xargs)
done

IP6=$(echo $RAW_IP6 | sed 's/:*$//')

IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
[ -z "$IFACE" ] && IFACE="eth0"

echo "Đang cài đặt các thư viện hệ thống & Unbound DNS..."
yum install -y gcc make wget net-tools curl cronie psmisc unbound >/dev/null 2>&1

# --- Tối ưu hóa Kernel System ---
cat <<EOF > /etc/sysctl.d/99-proxy-tune.conf
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1000000
net.core.somaxconn = 65535
EOF
sysctl -p /etc/sysctl.d/99-proxy-tune.conf >/dev/null 2>&1

# --- Cấu hình Unbound Local DNS Resolver ---
systemctl stop unbound 2>/dev/null
cat <<EOF > /etc/unbound/unbound.conf
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
EOF
systemctl restart unbound && systemctl enable unbound >/dev/null 2>&1

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c8
    echo
}

# Hàm sinh IPv6 ngẫu nhiên chuẩn từ dải /48
gen64() {
    printf "$1:%x:%x:%x:%x:%x\n" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# --- Cài đặt 3proxy ---
install_3proxy() {
    if [ ! -f /usr/local/etc/3proxy/bin/3proxy ]; then
        echo "Đang tải và biên dịch 3proxy..."
        VERSION="0.9.4"
        URL="https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz"
        
        rm -rf 3proxy-${VERSION}
        wget -qO- $URL | tar -xz
        cd 3proxy-${VERSION}
        
        make -f Makefile.Linux clean >/dev/null 2>&1
        make -f Makefile.Linux
        
        mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
        
        if [ -f bin/3proxy ]; then
            cp bin/3proxy /usr/local/etc/3proxy/bin/
        elif [ -f src/3proxy ]; then
            cp src/3proxy /usr/local/etc/3proxy/bin/
        fi
        
        cd ..
        rm -rf 3proxy-${VERSION}
    fi
}

# --- MAIN ---
IP4=$(curl -4 -s ifconfig.co)

# Thiết lập dải 5000 Proxy (ví dụ từ 10000 đến 14999)
START_PORT=10000
END_PORT=14999

install_3proxy

# Xóa các cronjob cũ liên quan tới rotate nếu có
crontab -l 2>/dev/null | grep -v "rotate_ipv6.sh" | crontab -

echo "Đang khởi tạo 5000 IPv6 tĩnh và cấu hình 3proxy..."

> $WORKDIR/data_static.txt
> $WORKDIR/add_ipv6.sh

echo "#!/bin/bash" > $WORKDIR/add_ipv6.sh

for port in $(seq $START_PORT $END_PORT); do
    user="user$port"
    pass=$(random)
    ip6=$(gen64 $IP6)
    
    # Lưu thông tin theo định dạng: user/pass/ip4/port/ip6
    echo "$user/$pass/$IP4/$port/$ip6" >> $WORKDIR/data_static.txt
    
    # Ghi lệnh gán IP vào script khởi động
    echo "ip -6 addr add $ip6/64 dev $IFACE 2>/dev/null" >> $WORKDIR/add_ipv6.sh
done

chmod +x $WORKDIR/add_ipv6.sh

# Chạy gán 5000 IPv6 lên Card mạng
echo "Đang gán 5000 IPv6 vào card mạng $IFACE..."
bash $WORKDIR/add_ipv6.sh

# Tạo file xuất danh sách Proxy cho người dùng (IP4:PORT:USER:PASS)
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data_static.txt > $WORKDIR/proxy.txt

# --- Ghi cấu hình 3proxy tĩnh ---
echo "Đang ghi cấu hình 3proxy..."
cat <<CFG > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 2000

nserver 127.0.0.1
nscache 65536

timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535

auth strong
users $(awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data_static.txt | paste -sd " ")

$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' $WORKDIR/data_static.txt)
CFG

# Mở Firewall cho 5000 cổng
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT

# Khởi chạy 3proxy
pkill -9 3proxy 2>/dev/null
ulimit -n 100000
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

# Tự động gán lại IPv6 và khởi động 3proxy khi reboot VPS
cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT
ulimit -n 100000
systemctl restart unbound
bash /home/anhhungproxy/add_ipv6.sh
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
chmod +x /etc/rc.d/rc.local

echo "------------------------------------------------"
echo "CÀI ĐẶT THÀNH CÔNG 5000 PROXY IPV6 TĨNH!"
echo "Subnet IPv6: $IP6"
echo "Dải Port: $START_PORT -> $END_PORT"
echo "Danh sách Proxy xuất ra tại: $WORKDIR/proxy.txt"
echo "------------------------------------------------"
head -n 5 $WORKDIR/proxy.txt
echo "... (Xem toàn bộ 5000 proxy tại: $WORKDIR/proxy.txt)"
