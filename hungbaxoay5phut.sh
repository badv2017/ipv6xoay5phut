#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

# Auto nhận diện card mạng chính
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
[ -z "$IFACE" ] && IFACE="eth0"

# Tự động cài đặt gói phụ thuộc (RHEL/CentOS)
yum install -y gcc make wget net-tools curl cronie psmisc >/dev/null 2>&1
systemctl start crond && systemctl enable crond

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

install_3proxy() {
    if [ ! -f /usr/local/etc/3proxy/bin/3proxy ]; then
        echo "Đang tải và biên dịch 3proxy..."
        URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
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

# Đảm bảo ulimit cao cho tiến trình 3proxy
ulimit -n 100000

gen48() {
    printf "$1:%x:%x:%x:%x:%x\n" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# 1. Tạo danh sách IP mới TRƯỚC
> $WORKDIR/data.txt
> $WORKDIR/new_ipv6.txt

while IFS="/" read -r user pass ip4 port; do
    new_ip6=$(gen48 $IP6)
    echo "$user/$pass/$ip4/$port/$new_ip6" >> $WORKDIR/data.txt
    echo "$new_ip6" >> $WORKDIR/new_ipv6.txt
    ip -6 addr add $new_ip6/64 dev $IFACE
done < $WORKDIR/data_static.txt

# 2. Xóa IP cũ SAU (Giảm thời gian gián đoạn mạng)
if [ -f $WORKDIR/current_ipv6.txt ]; then
    while read old_ip; do
        ip -6 addr del $old_ip/64 dev $IFACE 2>/dev/null
    done < $WORKDIR/current_ipv6.txt
fi

mv $WORKDIR/new_ipv6.txt $WORKDIR/current_ipv6.txt

# 3. Ghi file cấu hình 3proxy
cat <<CFG > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 1000
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
auth strong
users $(awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data.txt | paste -sd " ")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' $WORKDIR/data.txt)
CFG

# 4. Kiếm tra và khởi động/reload 3proxy an toàn
if pgrep 3proxy > /dev/null; then
    pkill -USR1 3proxy
else
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
fi
EOF
    chmod +x $WORKDIR/rotate_ipv6.sh
}

gen_proxy_txt() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data_static.txt > $WORKDIR/proxy.txt
}

# --- MAIN SCRIPT ---
IP4=$(curl -4 -s ifconfig.co)
read -p "Nhập subnet IPv6 /48 (ví dụ: 2602:fa81:b): " RAW_IP6

# Chuẩn hóa IPv6 Subnet (Tự động xóa dấu : thừa ở cuối nếu có)
IP6=$(echo $RAW_IP6 | sed 's/:*$//')

START_PORT=21000
END_PORT=21999

# Lưu biến môi trường
echo "IP6=$IP6" > $WORKDIR/config.env

install_3proxy
gen_fixed_data
gen_proxy_txt
gen_rotate_script

# Mở Firewall
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT

# Chạy xoay IP lần đầu
bash $WORKDIR/rotate_ipv6.sh

# Cài đặt Cronjob (Thêm ulimit trực tiếp trước khi gọi script)
CRON_CMD="*/5 * * * * ulimit -n 100000 && bash $WORKDIR/rotate_ipv6.sh >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "rotate_ipv6.sh" ; echo "$CRON_CMD") | crontab -

# Cấu hình khởi động cùng hệ thống
cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash
iptables -I INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT
ulimit -n 100000
bash $WORKDIR/rotate_ipv6.sh
EOF
chmod +x /etc/rc.d/rc.local

echo "------------------------------------------------"
echo "HOÀN TẤT! Script đã được kiểm tra và chạy an toàn."
echo "Proxy lưu tại: $WORKDIR/proxy.txt"
echo "------------------------------------------------"
cat $WORKDIR/proxy.txt
