#!/bin/bash
set -e

# ========= 基本变量 =========
TROJAN_DIR="/root/trojan-go"
KCPTUN_DIR="/usr/local/kcptun"
TROJAN_VERSION="v0.10.6"

# 这里改成最新版本号（不带 v）
KCPTUN_VERSION="20240107"

TROJAN_BIN_URL="https://github.com/p4gefau1t/trojan-go/releases/download/${TROJAN_VERSION}/trojan-go-linux-amd64.zip"

# 注意：tag 前面要带 v，文件名中不要带 v
KCPTUN_TAR_URL="https://github.com/xtaci/kcptun/releases/download/v${KCPTUN_VERSION}/kcptun-linux-amd64-${KCPTUN_VERSION}.tar.gz"

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

# ========= 检测是否已安装 Trojan-Go / Trojan =========
EXISTING_TROJAN=0

# systemd 里有没有 trojan-go / trojan 类服务
if systemctl list-unit-files | grep -qE '^(trojan-go|trojan)\.service'; then
  EXISTING_TROJAN=1
fi

# 进程里有没有 trojan-go
if pgrep -x trojan-go >/dev/null 2>&1; then
  EXISTING_TROJAN=1
fi

if [ "$EXISTING_TROJAN" -eq 1 ]; then
  echo "⚠ 检测到当前系统已经有 Trojan/Trojan-Go 在运行。"
  echo "  1) 仅为现有 Trojan 配置 Kcptun 加速（不动原有 Trojan 配置和服务）"
  echo "  2) 覆盖安装新的 Trojan-Go（可能影响现有服务）"
  read -rp "请选择 [1/2] (默认: 1): " choice
  choice=${choice:-1}

  if [ "$choice" = "1" ]; then
    SKIP_TROJAN_INSTALL=1
    read -rp "请输入现有 Trojan 监听端口 (默认: 443): " EXISTING_TROJAN_PORT
    TROJAN_PORT=${EXISTING_TROJAN_PORT:-443}
  else
    echo "将覆盖原有 Trojan-Go 配置和服务，请确保你已经备份。"
    TROJAN_PORT=443
    # 检查端口占用（防止 443 被 Nginx 等占用）
    if ss -ltnp | grep -q ":${TROJAN_PORT} "; then
      echo "⚠ 端口 ${TROJAN_PORT} 已被其他程序占用："
      ss -ltnp | grep ":${TROJAN_PORT} "
      echo "请先停止占用该端口的服务，或修改脚本中的 TROJAN_PORT 再运行。"
      exit 1
    fi
  fi
else
  TROJAN_PORT=443
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

# ========= 生成/提示 Trojan 密码 =========
if [ -z "$SKIP_TROJAN_INSTALL" ]; then
  TROJAN_PWD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
  echo "为 Trojan 生成的随机密码: $TROJAN_PWD"
else
  TROJAN_PWD="(使用现有 Trojan 密码，本脚本未修改)"
  echo "提示：当前选择仅配置 Kcptun，本脚本不会修改 Trojan 密码。"
fi

# ========= 安装 / 配置 Trojan-Go（可跳过） =========
if [ -z "$SKIP_TROJAN_INSTALL" ]; then
  echo "==> 安装 Trojan-Go 到 ${TROJAN_DIR} ..."
  mkdir -p "$TROJAN_DIR"
  cd /tmp
  wget -O trojan-go.zip --no-check-certificate "$TROJAN_BIN_URL"
  unzip -o trojan-go.zip -d "$TROJAN_DIR"
  chmod +x "${TROJAN_DIR}/trojan-go"

  # 证书
  if [ ! -f "${TROJAN_DIR}/your_key.key" ] || [ ! -f "${TROJAN_DIR}/your_cert.crt" ]; then
    echo "==> 生成自签 TLS 证书 ..."
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "${TROJAN_DIR}/your_key.key" \
      -out "${TROJAN_DIR}/your_cert.crt" \
      -days 365 \
      -subj "/CN=${DOMAIN}"
  fi

  echo "==> 生成 Trojan-Go 配置文件 ..."
  cat > "${TROJAN_DIR}/server.json" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${TROJAN_PORT},
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
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now trojan-go
else
  echo "==> 检测到现有 Trojan，跳过 Trojan-Go 安装与 systemd 配置，仅配置 Kcptun 加速。"
fi

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
KCP_TARGET_PORT=${TROJAN_PORT}
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
if [ -z "$SKIP_TROJAN_INSTALL" ]; then
  echo "  已安装新的 Trojan-Go 实例："
  echo "  配置文件路径: ${TROJAN_DIR}/server.json"
  echo "  证书路径:     ${TROJAN_DIR}/your_cert.crt"
  echo "  私钥路径:     ${TROJAN_DIR}/your_key.key"
else
  echo "  本脚本未修改 Trojan，仅为其添加 Kcptun 加速。"
  echo "  请使用你原有的 Trojan 配置文件和证书。"
fi
echo
echo "  Trojan 监听端口: ${TROJAN_PORT}"
echo "  重启 Trojan-Go 使配置生效 (如使用本脚本安装的 trojan-go):"
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
echo "  端口:       ${TROJAN_PORT}"
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
