#!/bin/bash

set -e

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запускайте как root"
  exit 1
fi

# Ввод SSH-ключа
read -p "Вставьте ваш SSH public key (начиная с ssh-ed25519 или ssh-rsa): " SSH_KEY

# Ввод пароля для пользователя admin
read -s -p "Введите пароль для пользователя admin: " ADMIN_PASS

echo "✅ Установка и настройка системы..."

# Обновление
apt update && apt upgrade -y

# Установка пакетов
apt install -y sudo curl iptables iptables-persistent fail2ban

# Создание пользователя admin
useradd -m -s /bin/bash admin
echo "admin:$ADMIN_PASS" | chpasswd
usermod -aG sudo admin
mkdir -p /home/admin/.ssh
echo "$SSH_KEY" > /home/admin/.ssh/authorized_keys
chmod 600 /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh

echo "admin ALL=(ALL) ALL" | tee /etc/sudoers.d/90-admin > /dev/null
chmod 440 /etc/sudoers.d/90-admin

# Настройка SSH
sed -i -E 's/^#?Port .*/Port 45916/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# Отключение ping
sysctl -w net.ipv4.icmp_echo_ignore_all=1
echo 'net.ipv4.icmp_echo_ignore_all=1' >> /etc/sysctl.conf

# Отключение IPv6
echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.default.disable_ipv6 = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.lo.disable_ipv6 = 1' >> /etc/sysctl.conf
sysctl -p

# Настройка iptables
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 45916 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables-save > /etc/iptables/rules.v4

# BBR + FQ
if modinfo tcp_bbr &>/dev/null; then
  modprobe tcp_bbr || true
  cp /etc/sysctl.conf /etc/sysctl.conf.bak_$(date +%s)
  if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo -e "\n# BBR + FQ Optimization" >> /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.core.rmem_default=262144" >> /etc/sysctl.conf
    echo "net.core.rmem_max=4194304" >> /etc/sysctl.conf
    echo "net.core.wmem_default=262144" >> /etc/sysctl.conf
    echo "net.core.wmem_max=4194304" >> /etc/sysctl.conf
  fi
  sysctl -p
fi

# Настройка fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = iptables-multiport
findtime = 600
bantime = 600
maxretry = 5
destemail = root@localhost
sender = fail2ban@localhost
mta = sendmail
action = %(action_)s

[sshd]
enabled = true
port = 45916
logpath = /var/log/auth.log
backend = systemd
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "✅ Готово! Вы можете войти через ssh"
