#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

# 1. Hàm tạo mật khẩu ngẫu nhiên
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c8
    echo
}

# 2. Hàm tạo IPv6 ngẫu nhiên từ Prefix /48
gen48() {
    printf "$1:%x:%x:%x:%x:%x\n" \
        $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# 3. Lấy thông tin mạng từ người dùng
IP4=$(curl -4 -s ifconfig.co || curl -4 -s icanhazip.com)
read -p "Nhập IPv6 /48 Prefix (Ví dụ 2a0a:8dc0:f1): " RAW_IP6
IP6=$(echo $RAW_IP6 | sed -E 's/::\/[0-9]+//g' | sed -E 's/:\+$//g')

if [ -z "$IP6" ]; then
    echo "[!] Lỗi: IP6 Prefix không được để trống!"
    exit 1
fi

START_PORT=10000
END_PORT=14999

echo "[+] Đang khởi tạo danh sách 5000 IPv6..."
rm -f $WORKDIR/data.txt
seq $START_PORT $END_PORT | while read port; do
    echo "user$port/$(random)/$IP4/$port/$(gen48 $IP6)">> $WORKDIR/data.txt
done

# 4. Cài đặt 3proxy 0.9.4
echo "[+] Đang tải và biên dịch 3proxy..."
rm -rf 3proxy
wget --no-check-certificate -qO 3proxy.tar.gz https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -xzf 3proxy.tar.gz
mv 3proxy-0.9.4 3proxy
rm -f 3proxy.tar.gz

cd 3proxy
make -f Makefile.Linux
mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
cp bin/3proxy /usr/local/etc/3proxy/bin/ 2>/dev/null || cp src/3proxy /usr/local/etc/3proxy/bin/
cd $WORKDIR

# 5. Tạo file Mật khẩu và Cấu hình 3proxy chuẩn 0.9.x
echo "[+] Đang tạo cấu hình 3proxy..."
# Tạo file lưu danh sách USERS
awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data.txt > /usr/local/etc/3proxy/3proxy.passwd

# Tạo file 3proxy.cfg chuẩn Anti-Detection
cat <<'EOF' > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 100000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2606:4700:4700::1111
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535

users $/usr/local/etc/3proxy/3proxy.passwd
auth strong
EOF

# Thêm từng rule proxy vào file cấu hình
awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush"}' $WORKDIR/data.txt >> /usr/local/etc/3proxy/3proxy.cfg

# 6. Xuất file proxy.txt (USER:PASS:IP:PORT)
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data.txt > $WORKDIR/proxy.txt

# 7. Script gán 5000 IP v6 vào Card eth0
echo "[+] Đang tạo script gán IP và mở Firewall..."
awk -F "/" '{print "ip -6 addr add "$5"/64 dev eth0"}' $WORKDIR/data.txt > $WORKDIR/add_ip.sh

cat <<'EOF' > $WORKDIR/boot_ifconfig.sh
#!/bin/bash
bash /home/anhhungproxy/add_ip.sh >/dev/null 2>&1
EOF

cat <<EOF> $WORKDIR/boot_iptables.sh
#!/bin/bash
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT
EOF

chmod +x $WORKDIR/*.sh

# 8. Tối ưu Hệ thống
cat <<'EOF' >> /etc/sysctl.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.eth0.proxy_ndp = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 500000
EOF
sysctl -p >/dev/null 2>&1

# 9. Cấu hình tự khởi động cùng OS
cat <<'EOF' > /etc/rc.d/rc.local
#!/bin/bash
ulimit -n 500000
bash /home/anhhungproxy/boot_ifconfig.sh
bash /home/anhhungproxy/boot_iptables.sh
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
chmod +x /etc/rc.d/rc.local

# 10. Chạy dịch vụ ngay lập tức
echo "[+] Đang gán 5000 IP IPv6 và khởi chạy 3proxy..."
ulimit -n 500000
bash $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_iptables.sh
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

echo "=================================================="
echo " HOÀN TẤT THÀNH CÔNG!"
echo " File danh sách Proxy: $WORKDIR/proxy.txt"
echo "=================================================="
