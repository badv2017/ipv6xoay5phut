#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 1. Tạo mật khẩu ngẫu nhiên an toàn
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c8
    echo
}

# 2. Tạo IPv6 chuẩn từ Prefix /48
gen48() {
    printf "$1:%x:%x:%x:%x:%x\n" \
        $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# 3. Cài đặt 3proxy v0.9.4 mới nhất
install_3proxy() {
    echo "=== Cài đặt 3proxy v0.9.4 ==="
    cd $WORKDIR
    rm -rf 3proxy*
    
    # Tải trực tiếp bản release 0.9.4 chuẩn từ GitHub
    wget --no-check-certificate -qO 3proxy-0.9.4.tar.gz https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
    tar -xzf 3proxy-0.9.4.tar.gz
    cd 3proxy-0.9.4
    
    # Biên dịch
    make -f Makefile.Linux
    
    # Copy file thực thi
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/ 2>/dev/null || cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
    rm -rf 3proxy-0.9.4*
}

# 4. Tạo file cấu hình 3proxy 0.9.4 (Stealth Mode / Anti-Detect)
gen_3proxy_cfg() {
    cat <<EOF
daemon
maxconn 100000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2606:4700:4700::1111
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535

# Tối ưu ẩn thông tin Proxy (Anti-Detection)
auth strong
users $(awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data.txt | paste -sd " ")

$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' $WORKDIR/data.txt)
EOF
}

# 5. Định dạng file proxy.txt (USER:PASS:IP:PORT)
gen_proxy_txt() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data.txt > $WORKDIR/proxy.txt
}

# 6. Sinh dữ liệu 5000 Proxy
gen_data() {
    seq $START_PORT $END_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen48 $IP6)"
    done
}

# 7. Tạo script gán IP và cấu hình Firewall
gen_network_scripts() {
    cat <<EOF > $WORKDIR/boot_ifconfig.sh
#!/bin/bash
awk -F "/" '{if ($5 != "") print "ip -6 addr add "$5"/64 dev eth0"}' $WORKDIR/data.txt > $WORKDIR/add_ip.sh
bash $WORKDIR/add_ip.sh >/dev/null 2>&1
EOF

    cat <<EOF > $WORKDIR/boot_iptables.sh
#!/bin/bash
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT
EOF

    chmod +x $WORKDIR/boot_*.sh
}

# 8. Tối ưu Kernel Linux
tune_system() {
    cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.eth0.proxy_ndp = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 500000
EOF
    sysctl -p >/dev/null 2>&1
}

# 9. Cấu hình tự khởi động cùng hệ thống
setup_rc_local() {
    cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash
ulimit -n 500000
bash $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_iptables.sh
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
    chmod +x /etc/rc.d/rc.local
}

### CHƯƠNG TRÌNH CHÍNH ###
echo "=== Bắt đầu cài đặt 5000 IPv6 Proxy (3proxy v0.9.4) ==="
yum install -y gcc make wget net-tools curl bsdtar zip

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

# Lấy IPv4 tự động
IP4=$(curl -4 -s ifconfig.co || curl -4 -s icanhazip.com)

# Nhập và làm sạch IPv6 Prefix
read -p "Nhập IPv6 /48 Prefix (Ví dụ 2a0a:8dc0:f1): " RAW_IP6
IP6=$(echo $RAW_IP6 | sed -E 's/::\/[0-9]+//g' | sed -E 's/:\+$//g')

if [ -z "$IP6" ]; then
    echo "[!] Lỗi: IP6 Prefix không hợp lệ!"
    exit 1
fi

START_PORT=10000
END_PORT=14999

echo "[+] Đang khởi tạo danh sách 5000 IPv6..."
gen_data > data.txt

echo "[+] Đang tải và biên dịch 3proxy v0.9.4..."
install_3proxy

echo "[+] Đang tối ưu hệ thống & tạo cấu hình..."
tune_system
gen_3proxy_cfg > /usr/local/etc/3proxy/3proxy.cfg
gen_proxy_txt
gen_network_scripts
setup_rc_local

echo "[+] Đang gán IP và khởi chạy service..."
ulimit -n 500000
bash $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_iptables.sh
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

echo "=================================================="
echo " HOÀN TẤT! Đã nâng cấp lên 3proxy v0.9.4 và tạo xong 5000 Proxy."
echo " File danh sách Proxy: $WORKDIR/proxy.txt"
echo " Format: IP4:PORT:USER:PASS"
echo "=================================================="
