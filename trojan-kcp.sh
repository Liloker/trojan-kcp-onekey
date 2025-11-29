#!/bin/bash
set -e

# ========= 基本变量 =========
TROJAN_DIR="/root/trojan-go"
KCPTUN_DIR="/usr/local/kcptun"
TROJAN_VERSION="v0.10.6"
KCPTUN_VERSION="v20230214"   # 示例版本，可按需改
TROJAN_BIN_URL="https://github.com/p4gefau1t/trojan-go/releases/download/${TROJAN_VERSION}/trojan-go-linux-amd64.zip"
KCPTUN_TAR_URL="https://github.com/xtaci/kcptun/releases/download/${KCPTUN_VERSION}/kcptun-linux-amd64-${KCPTUN_VERSION}.tar.gz"

# ========= 必须是 root =========
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

# ========= 检测系统 =========
if [ ! -f /etc/os-release ]; then
  echo "无法检测系统类型，仅测试过 Debian/Ubuntu，其他系统请自行调整。"
fi

. /etc/os-release
if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
  echo "当前系统 $ID 仅做示例，脚本主要按 Debian/Ubuntu 写的。"
fi

# ========= 安装依赖 =========
echo "==> 安装基础依赖（wget unzip openssl curl）..."
apt-get update -y
apt-get install -y wget unzip openssl curl

# ========= 交互：域名 =========
read -rp "请输入用于 TLS 的域名 (默认: xytest.com): " DOMAIN
DOMAIN=${DOMAIN:-xytest.com}

# ========= 获取当前服务器公网 IP =========
SERVER_IP=$(curl -4s https://api.ipify.org || curl -4s https://ifconfig.co || echo "你的服务器IP")
echo "检测到服务器 IP: $SERVER_IP"

# ========= 生成随机 Trojan 密码 =========
TROJAN_PWD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
echo "为 Trojan 生成的随机密码: $TROJAN_PWD"

# ========= 安装 Trojan-Go =========
echo "==> 安装 Trojan-Go 到 ${TROJAN_DIR} ..."
mkdir -p "$TROJAN_DIR"
cd /tmp
wget -O trojan-go.zip --no-check-certificate "$TROJAN_BIN_URL"
unzip -o trojan-go.zip -d "$TROJAN_DIR"
chmod +x "${TROJAN_DIR}/trojan-go"

# ========= 生成自签证书（如果你之后用正规证书，只要把路径替换掉即可） =========
if [ ! -f "${TROJAN_DIR}/your_key.key" ] || [ ! -f "${TROJAN_DIR}/your_cert.crt" ]; then
  echo "==> 生成自签 TLS 证书 ..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${TROJAN_DIR}/your_key.key" \
    -out "${TROJAN_DIR}/your_cert.crt" \
    -days 365 \
    -subj "/CN=${DOMAIN}"
fi

# ========= 写 Trojan-Go server.json =========
echo "==> 生成 Trojan-Go 配置文件 ..."
cat > "${TROJAN_DIR}/server.json" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "www.amazon.com",
  "remote_port": 80,
  "password": [
    "${TROJAN_PWD}"
  ],
  "ssl": {
    "verify": false,
    "cert": "${TROJAN_DIR}/your_cert.crt",
    "key": "${TROJAN_DIR}/your_key.key",
    "sni": "${DOMAIN}"
  },
  "router": {
    "enabled": false,
    "block": [
      "geoip:private"
    ],
    "geoip": "/usr/share/trojan-go/geoip.dat",
    "geosite": "/usr/share/trojan-go/geosite.dat"
  }
}
EOF

# ========= systemd 服务：Trojan-Go（输出直接丢掉） =========
echo "==> 写入 trojan-go systemd 服务 ..."
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target

[Service]
Type=simple
ExecStart=${TROJAN_DIR}/trojan-go -config ${TROJAN_DIR}/server.json
Restart=on-failure
User=root
Group=root
# 丢弃所有输出，等价于 nohup ... >/dev/null 2>&1 &
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trojan-go

# ========= 安装 Kcptun =========
echo "==> 安装 Kcptun 到 ${KCPTUN_DIR} ..."
mkdir -p "$KCPTUN_DIR"
cd /tmp
wget -O kcptun.tar.gz --no-check-certificate "$KCPTUN_TAR_URL"
tar -zxf kcptun.tar.gz -C "$KCPTUN_DIR"
chmod +x "${KCPTUN_DIR}/server_linux_amd64"

# ========= Kcptun 参数（按你给的常用配置） =========
KCP_PORT=29900
KCP_TARGET_ADDR="127.0.0.1"
KCP_TARGET_PORT=443
KCP_KEY="very_fast"
KCP_CRYPT="none"
KCP_MODE="fast3"
KCP_MTU=1350
KCP_SNDWND=8192
KCP_RCVWND=4096
KCP_DATASHARD=10
KCP_PARITYSHARD=3
KCP_DSCP=46
KCP_NOCOMP="false"

# ========= 写 Kcptun 的 systemd 服务 =========
echo "==> 写入 kcptun-server systemd 服务 ..."
cat > /etc/systemd/system/kcptun-server.service <<EOF
[Unit]
Description=Kcptun Server
After=network.target

[Service]
Type=simple
ExecStart=${KCPTUN_DIR}/server_linux_amd64 \\
  -t "${KCP_TARGET_ADDR}:${KCP_TARGET_PORT}" \\
  -l ":${KCP_PORT}" \\
  -key "${KCP_KEY}" \\
  -crypt "${KCP_CRYPT}" \\
  -mode "${KCP_MODE}" \\
  -mtu ${KCP_MTU} \\
  -sndwnd ${KCP_SNDWND} \\
  -rcvwnd ${KCP_RCVWND} \\
  -datashard ${KCP_DATASHARD} \\
  -parityshard ${KCP_PARITYSHARD} \\
  -dscp ${KCP_DSCP}
Restart=on-failure
User=root
Group=root
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kcptun-server

# ========= 输出结果 =========
clear
echo "============================================================"
echo "  Trojan-Go + Kcptun 安装完成"
echo "============================================================"
echo
echo "【Trojan-Go 服务端配置】"
echo "  配置文件路径: ${TROJAN_DIR}/server.json"
echo "  证书路径:     ${TROJAN_DIR}/your_cert.crt"
echo "  私钥路径:     ${TROJAN_DIR}/your_key.key"
echo
echo "  重启 Trojan-Go 使配置生效:"
echo "    systemctl restart trojan-go"
echo
echo "【Kcptun 服务端】"
echo "  服务端监听端口(UDP): ${KCP_PORT}"
echo "  加速目标:            ${KCP_TARGET_ADDR}:${KCP_TARGET_PORT}"
echo
echo "  重启 Kcptun 使配置生效:"
echo "    systemctl restart kcptun-server"
echo
echo "============================================================"
echo "  客户端参数 (请按自己的客户端界面填入)"
echo "============================================================"
echo
echo "【Trojan 客户端】"
echo "  服务器地址: ${SERVER_IP}"
echo "  端口:       443"
echo "  密码:       ${TROJAN_PWD}"
echo "  SNI/域名:   ${DOMAIN}"
echo "  传输:       TLS (verify 视客户端而定，一般可以开)"
echo
echo "【Kcptun 客户端】"
echo "  服务器地址: ${SERVER_IP}"
echo "  服务器端口: ${KCP_PORT}  (UDP)"
echo "  key:        ${KCP_KEY}"
echo "  crypt:      ${KCP_CRYPT}"
echo "  mode:       ${KCP_MODE}"
echo "  mtu:        ${KCP_MTU}"
echo "  sndwnd:     ${KCP_SNDWND}"
echo "  rcvwnd:     ${KCP_RCVWND}"
echo "  datashard:  ${KCP_DATASHARD}"
echo "  parityshard:${KCP_PARITYSHARD}"
echo "  dscp:       ${KCP_DSCP}"
echo "  nocomp:     ${KCP_NOCOMP}"
echo
echo "  示例命令行客户端（Linux）:"
echo "    ./client_linux_amd64 \\"
echo "      -r \"${SERVER_IP}:${KCP_PORT}\" \\"
echo "      -l \":12984\" \\"
echo "      -key \"${KCP_KEY}\" \\"
echo "      -crypt \"${KCP_CRYPT}\" \\"
echo "      -mode \"${KCP_MODE}\" \\"
echo "      -mtu ${KCP_MTU} \\"
echo "      -sndwnd ${KCP_SNDWND} \\"
echo "      -rcvwnd ${KCP_RCVWND} \\"
echo "      -datashard ${KCP_DATASHARD} \\"
echo "      -parityshard ${KCP_PARITYSHARD} \\"
echo "      -dscp ${KCP_DSCP}"
echo
echo "============================================================"
echo "  修改配置后重启服务："
echo "    systemctl restart trojan-go"
echo "    systemctl restart kcptun-server"
echo "============================================================"