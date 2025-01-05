#!/usr/bin/env bash
# ---------------------------------
# MF Proxy 安装/配置脚本示例
# 支持自动申请 Let’s Encrypt 证书
# （二进制、配置安装到 /opt/mf_proxy）
# ---------------------------------

##################################
# 函数: 检测并设置包管理器 & 安装 certbot
##################################
install_certbot() {
  if [[ -f /etc/debian_version ]]; then
    # Debian / Ubuntu
    apt-get update
    apt-get install -y certbot
  elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
    # CentOS / RHEL / Rocky / Alma 等
    # 安装 EPEL 仓库（部分系统上 certbot 需要 epel-release 才能安装）
    yum install -y epel-release
    yum install -y certbot
  else
    echo "暂不支持此系统的自动安装 certbot，请手动安装后重试。"
    exit 1
  fi
}

# 1. 检查是否为 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "本脚本需要 root 权限，请使用 sudo 或切换为 root 后再执行。"
   exit 1
fi

# 2. 交互式获取必要参数
read -rp "请输入您的域名 (例如: xxx.xxx.com): " DOMAIN
read -rp "请输入 Emby 主站地址 (例如: https://emby.example.com): " EMBY_URL

# 2.1 是否自动申请 Let’s Encrypt 证书
read -rp "是否自动申请/更新 Let’s Encrypt 证书？[y/n] (默认 n): " AUTO_SSL
AUTO_SSL="${AUTO_SSL:-n}"

SSL_CERT=""
SSL_KEY=""

if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  # 2.2 若自动申请，则获取 Email
  read -rp "请输入您的邮箱 (用于 Let’s Encrypt 注册): " EMAIL
  # 提示用户端口 80 必须可用
  echo "请确保本机 80 端口空闲，并且域名 $DOMAIN 已解析到本机公网 IP。"
else
  # 2.3 若不自动申请，则让用户手动填写证书路径
  read -rp "请输入 SSL 证书文件绝对路径 (例如: /etc/ssl/certs/xxx.crt): " SSL_CERT
  read -rp "请输入 SSL 私钥文件绝对路径 (例如: /etc/ssl/certs/xxx.key): " SSL_KEY
fi

# 显示配置信息，供用户确认
echo "===================== 配置确认 ====================="
echo "域名 (Domain)              : $DOMAIN"
echo "Emby 主站地址 (Emby URL)   : $EMBY_URL"
echo "自动申请证书 (AUTO_SSL)    : $AUTO_SSL"
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo "邮箱 (Email)               : $EMAIL"
  echo "证书路径将保存在 Let’s Encrypt 默认目录: /etc/letsencrypt/live/$DOMAIN"
else
  echo "SSL 证书 (SSL_CERT)        : $SSL_CERT"
  echo "SSL 私钥 (SSL_KEY)         : $SSL_KEY"
fi
echo "===================================================="

# 是否确认
read -rp "以上信息是否正确？(y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "用户取消操作，脚本退出。"
  exit 1
fi

# 3. 如果选择自动申请证书，尝试安装并使用 certbot
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  install_certbot

  echo "使用 certbot standalone 模式为 $DOMAIN 申请/更新证书..."
  # 停止可能占用80端口的服务（如已有mf_proxy或nginx），仅示例处理，实际请根据情况调整
  systemctl stop mf_proxy 2>/dev/null || true
  systemctl stop nginx 2>/dev/null || true

  # 非交互式申请 SSL
  certbot certonly --standalone \
    --agree-tos --no-eff-email \
    -m "$EMAIL" \
    -d "$DOMAIN"

  # 判断申请结果
  if [[ $? -ne 0 ]]; then
    echo "Let’s Encrypt 证书申请失败，请检查错误信息。脚本退出。"
    exit 1
  fi

  # 设置证书路径
  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi

# 4. 下载 MF Proxy
DOWNLOAD_URL="https://download.misakaf.org/p/Emby/MF_Proxy"
INSTALL_DIR="/opt/mf_proxy"
BINARY_NAME="mf_proxy"
BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
CONFIG_FILE="${INSTALL_DIR}/config.yaml"

mkdir -p "$INSTALL_DIR"

echo "开始下载 MF Proxy 二进制文件: $DOWNLOAD_URL -> $BINARY_PATH"
curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"
if [[ $? -ne 0 ]]; then
  echo "二进制文件下载失败，请检查网络或下载链接。"
  exit 1
fi
chmod +x "$BINARY_PATH"

# 5. 生成 config.yaml 文件
cat > "$CONFIG_FILE" <<EOF
domain: "$DOMAIN"
ssl_certificate: "$SSL_CERT"
ssl_certificate_key: "$SSL_KEY"
emby_url: "$EMBY_URL"
EOF
echo "生成配置文件完成: $CONFIG_FILE"

# 6. 创建 systemd 服务文件
SERVICE_FILE="/etc/systemd/system/mf_proxy.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MF Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$BINARY_PATH
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 7. 刷新 systemd 配置、设置开机自启动
systemctl daemon-reload
systemctl enable mf_proxy

# 8. 启动服务
systemctl start mf_proxy

# 9. 查看服务状态
systemctl status mf_proxy --no-pager

# 最终提示
echo "===================================================="
echo "MF Proxy 安装并启动完成！"
echo
echo "二进制文件:    $BINARY_PATH"
echo "配置文件:      $CONFIG_FILE"
echo "systemd 服务:  $SERVICE_FILE"
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo
  echo "SSL 证书位于:  /etc/letsencrypt/live/$DOMAIN/"
  echo "请注意 Let’s Encrypt 证书有效期为 90 天，Certbot 会定期自动续期。"
fi
echo
echo "查看日志请使用：journalctl -u mf_proxy -f"
echo "===================================================="
