#!/bin/bash

echo "=== Update Server ==="
dnf update -y && dnf upgrade -y

echo "=== Install cloudflared, ufw, iptables-persistent, fail2ban ==="
dnf install curl ufw iptables-services fail2ban -y

echo "=== Install and Setup cloudflared ==="
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
dnf install ./cloudflared.deb

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared DNS over HTTPS proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared proxy-dns --port 53 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query
Restart=always
RestartSec=3
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

echo "=== Configure Netplan DNS to 127.0.0.1 with fallback ==="
# AlmaLinux tidak menggunakan Netplan, jadi kita gunakan resolv.conf langsung
rm -f /etc/resolv.conf
echo -e "nameserver 127.0.0.1\nnameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

echo "=== Setup UFW Firewall ==="
ufw --force reset
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from 127.0.0.1 to any port 53 proto udp
ufw allow from 127.0.0.1 to any port 53 proto tcp
ufw deny out to any port 53 proto udp
ufw deny out to any port 53 proto tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

echo "=== Setup Fail2Ban for SSH Protection ==="
cat > /etc/fail2ban/jail.d/ssh.conf <<EOF
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 3
findtime = 600
bantime = 3600
EOF

systemctl restart fail2ban
systemctl enable fail2ban

echo "=== Setup iptables Anti-DDoS, Connection Limit, and Port Scanning Protection ==="
iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --syn -m limit --limit 20/second --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --tcp-flags ALL SYN,ACK,FIN,RST RST -m limit --limit 2/second --limit-burst 2 -j ACCEPT
iptables -A INPUT -p icmp -m limit --limit 1/second --limit-burst 5 -j ACCEPT
iptables -A INPUT -p udp -m length --length 0:28 -j DROP
iptables -A INPUT -p udp -m limit --limit 100/second --limit-burst 200 -j ACCEPT

# Limit Connections per IP
iptables -A INPUT -p tcp --syn -m connlimit --connlimit-above 300 -j DROP

# Anti Port Scanning
iptables -N PORT-SCANNING
iptables -A PORT-SCANNING -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s --limit-burst 2 -j RETURN
iptables -A PORT-SCANNING -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j PORT-SCANNING

service iptables save
service iptables restart

echo "=== Enable TCP Stack Optimization & BBRv2 ==="
# Clean and append once
cat > /etc/sysctl.d/99-bbr-tune.conf <<EOF
# Anti DDoS Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# TCP Speed Optimization
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_mtu_probing = 1

# Enable BBRv2
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# General tuning
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

sysctl --system

echo "=== Setup Cloudflared Health Monitor ==="
cat > /etc/cron.d/monitor-cloudflared <<EOF
* * * * * root pgrep cloudflared > /dev/null || (systemctl restart cloudflared || (echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf))
EOF

echo "=== FINISH ==="
echo "✅ Server ultra-secure: Cloudflare DoH + Firewall Lock + Fail2Ban + BBRv2 + Anti-DDoS + Port Scan Block"
echo "✅ Direkomendasikan reboot server setelah selesai setup!"
