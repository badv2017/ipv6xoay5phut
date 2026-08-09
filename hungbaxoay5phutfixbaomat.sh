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

# --- Tối ưu hóa Kernel System chống ngẽn mạng ---
cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 500000
EOF
sysctl -p >/dev/null 2>&1

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
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
EOF
systemctl restart unbound && systemctl enable unbound >/dev/null 2>&1
systemctl start crond && systemctl enable crond >/dev/null 2>&1

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

install_3proxy() {
    if [ ! -f /usr/local/etc/3proxy/bin/3proxy ]; then
        echo "Đang tải và biên dịch 3proxy..."
        URL="https://github.com/3proxy/3proxy/archive/refs/tags/0.9.7.tar.gz"
        wget -qO- $URL | tar -xz
        cd 3proxy-3proxy-0.8.6
        make -f Makefile.Linux
        mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
        cp src/3proxy /usr/local/etc/3proxy/bin/
        cd ..
        rm -rf 3proxy-3proxy-0.8.6
    fi
}

gen_fixed_data() {
    if [ ! -f $WORKDIR/data_static.txt ]; then
        echo "Tạo dữ liệu tài khoản và port cố định..."
        > $WORKDIR/data_static.txt
        for port in $(seq $START_PORT $END_PORT); do
            echo "user$port/$(random)/$IP4/$port" >> $WORKDIR/data_static.txt
        done
    fi
}

gen_rotate_script() {
    cat <<'EOF' > $WORKDIR/rotate_ipv6.sh
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
WORKDIR="/home/anhhungproxy"

IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
[ -z "$IFACE" ] && IFACE="eth0"

source $WORKDIR/config.env

ulimit -n 100000

gen48() {
    printf "$1:%x:%x:%x:%x:%x\n" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# 1. Tạo IPv6 mới
> $WORKDIR/data.txt
> $WORKDIR/new_ipv6.txt

while IFS="/" read -r user pass ip4 port; do
    new_ip6=$(gen48 $IP6)
    echo "$user/$pass/$ip4/$port/$new_ip6" >> $WORKDIR/data.txt
    echo "$new_ip6" >> $WORKDIR/new_ipv6.txt
    ip -6 addr add $new_ip6/64 dev $IFACE
done < $WORKDIR/data_static.txt

# 2. Xóa IPv6 cũ
if [ -f $WORKDIR/current_ipv6.txt ]; then
    while read old_ip; do
        ip -6 addr del $old_ip/64 dev $IFACE 2>/dev/null
    done < $WORKDIR/current_ipv6.txt
fi

mv $WORKDIR/new_ipv6.txt $WORKDIR/current_ipv6.txt

# 3. Ghi file cấu hình 3proxy CHUẨN TỐI ƯU CÚ PHÁP
cat <<CFG > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 1000

# Dùng Local DNS từ Unbound chống rò rỉ DNS
nserver 127.0.0.1
nscache 65536

timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535

# Cấu hình xác thực người dùng
auth strong
users $(awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data.txt | paste -sd " ")

# Cấu hình Proxy Lắng nghe
$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' $WORKDIR/data.txt)
CFG

# 4. Khởi động / Reload 3proxy
pkill -9 3proxy 2>/dev/null
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
    chmod +x $WORKDIR/rotate_ipv6.sh
}

gen_proxy_txt() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data_static.txt > $WORKDIR/proxy.txt
}

# --- MAIN ---
IP4=$(curl -4 -s ifconfig.co)
START_PORT=21000
END_PORT=21999

echo "IP6=$IP6" > $WORKDIR/config.env

install_3proxy
gen_fixed_data
gen_proxy_txt
gen_rotate_script

# Mở Firewall
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT

# Chạy xoay IP lần đầu
bash $WORKDIR/rotate_ipv6.sh

# Cài Cronjob xoay IP 5 phút/lần
CRON_CMD="*/5 * * * * ulimit -n 100000 && bash $WORKDIR/rotate_ipv6.sh >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "rotate_ipv6.sh" ; echo "$CRON_CMD") | crontab -

# Khởi động cùng hệ thống
cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT
ulimit -n 100000
systemctl restart unbound
bash $WORKDIR/rotate_ipv6.sh
EOF
chmod +x /etc/rc.d/rc.local

echo "------------------------------------------------"
echo "CÀI ĐẶT THÀNH CÔNG! ĐÃ FIX HOÀN TOÀN LỖI CÚ PHÁP."
echo "Subnet IPv6: $IP6"
echo "Danh sách Proxy: $WORKDIR/proxy.txt"
echo "------------------------------------------------"
head -n 5 $WORKDIR/proxy.txt
echo "... (Xem toàn bộ danh sách tại: $WORKDIR/proxy.txt)"
