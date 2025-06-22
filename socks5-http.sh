#!/bin/bash

# 默认端口
SOCKS_PORT=1080
HTTP_PORT=8080
PROXY_TYPE="xray" # 默认使用 xray

# 显示使用帮助
usage() {
  echo "使用方法: $0 [-n] [-u] [-s socks_port] [-h http_port] [-t proxy_type]"
  echo "  -n: 显示节点信息"
  echo "  -u: 卸载代理"
  echo "  -s: 指定 SOCKS5 端口 (默认: 1080)"
  echo "  -h: 指定 HTTP 端口 (默认: 8080)"
  echo "  -t: 指定代理类型 (xray 或 sing-box，默认: xray)"
  exit 0
}

# 解析命令行参数
while getopts "nus:h:t:" opt; do
  case $opt in
  n) SHOW_NODE_INFO=true ;;
  u) UNINSTALL=true ;;
  s) SOCKS_PORT=$OPTARG ;;
  h) HTTP_PORT=$OPTARG ;;
  t) PROXY_TYPE=$OPTARG ;;
  *) usage ;;
  esac
done

# 验证代理类型
if [[ "$PROXY_TYPE" != "xray" && "$PROXY_TYPE" != "sing-box" ]]; then
  echo "无效的代理类型: $PROXY_TYPE。必须是 'xray' 或 'sing-box'。"
  exit 1
fi

# 检测操作系统和初始化系统
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "无法检测操作系统。退出。"
  exit 1
fi

INIT_SYSTEM=""
if systemctl --version >/dev/null 2>&1; then
  INIT_SYSTEM="systemd"
elif rc-service --version >/dev/null 2>&1; then
  INIT_SYSTEM="openrc"
else
  echo "不支持的初始化系统。退出。"
  exit 1
fi

# 检测架构
ARCH=$(uname -m)
case $ARCH in
x86_64)
  XRAY_ARCH="64"
  SINGBOX_ARCH="amd64"
  ;;
aarch64)
  XRAY_ARCH="arm64-v8a"
  SINGBOX_ARCH="arm64"
  ;;
arm*)
  XRAY_ARCH="arm"
  SINGBOX_ARCH="armv7"
  ;;
*)
  echo "不支持的架构: $ARCH"
  exit 1
  ;;
esac

# 代理安装路径
PROXY_DIR="/usr/local/proxy"
PROXY_BIN="$PROXY_DIR/$PROXY_TYPE"
PROXY_CONFIG="$PROXY_DIR/config.json"

# 安装依赖，优先使用系统已有的 wget 或 curl，再检查 unzip 是否安装
install_dependencies() {
  # 检查是否安装 unzip
  if ! command -v unzip >/dev/null 2>&1; then
    echo "[INFO] unzip 未安装，准备安装..."
    case $OS in
    debian | ubuntu)
      apt-get update
      apt-get install -y unzip
      ;;
    centos)
      yum install -y unzip
      ;;
    alpine)
      apk add unzip
      ;;
    *)
      echo "不支持的操作系统: $OS"
      exit 1
      ;;
    esac
  fi

  # 检查是否有 curl 或 wget
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl -L"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget -O-"
  else
    echo "[INFO] curl 和 wget 都未安装，准备安装 curl..."
    case $OS in
    debian | ubuntu)
      apt-get update
      apt-get install -y curl
      ;;
    centos)
      yum install -y curl
      ;;
    alpine)
      apk add curl
      ;;
    *)
      echo "不支持的操作系统: $OS"
      exit 1
      ;;
    esac
    DOWNLOADER="curl -L"
  fi
}

# 下载并安装代理
install_proxy() {
  if [ "$PROXY_TYPE" = "xray" ]; then
    LATEST_URL=$($DOWNLOADER https://api.github.com/repos/XTLS/Xray-core/releases/latest | awk -v arch="$XRAY_ARCH" -F '"' '$0 ~ "https.*Xray-linux-" arch "\\.zip\"" { print $4 }')
  else
    LATEST_URL=$($DOWNLOADER https://api.github.com/repos/SagerNet/sing-box/releases/latest | awk -v arch="$SINGBOX_ARCH" -F '"' '$0 ~ "https.*sing-box.*-linux-" arch "\\.tar\\.gz\"" { print $4 }')
  fi

  if [ -z "$LATEST_URL" ]; then
    echo "无法找到最新的 $PROXY_TYPE 版本。"
    exit 1
  fi

  # 下载并解压
  mkdir -p "$PROXY_DIR"
  $DOWNLOADER "$LATEST_URL" >/tmp/proxy.zip

  if [ "$PROXY_TYPE" = "xray" ]; then
    unzip -o /tmp/proxy.zip -d "$PROXY_DIR"
  else
    tar -xzf /tmp/proxy.zip -C "$PROXY_DIR"
    mv "$PROXY_DIR/sing-box"*"/sing-box" "$PROXY_BIN"
  fi
  chmod +x "$PROXY_BIN"
  rm /tmp/proxy.zip
}

# 创建代理配置文件
create_config() {
  if [ "$PROXY_TYPE" = "xray" ]; then
    cat >"$PROXY_CONFIG" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": $SOCKS_PORT,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true
            }
        },
        {
            "listen": "127.0.0.1",
            "port": $HTTP_PORT,
            "protocol": "http",
            "settings": {
                "allowTransparent": false
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF
  else
    cat >"$PROXY_CONFIG" <<EOF
{
    "log": {
        "level": "warn"
    },
    "inbounds": [
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "listen_port": $SOCKS_PORT
        },
        {
            "type": "http",
            "tag": "http-in",
            "listen": "127.0.0.1",
            "listen_port": $HTTP_PORT
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "rules": [
            {
                "inbound": [
                    "socks-in",
                    "http-in"
                ],
                "outbound": "direct"
            }
        ]
    }
}
EOF
  fi
}

# 设置 systemd 服务
setup_systemd() {
  cat >/etc/systemd/system/proxy.service <<EOF
[Unit]
Description=代理服务 ($PROXY_TYPE)
After=network.target

[Service]
Type=simple
ExecStart=$PROXY_BIN run -c $PROXY_CONFIG
Restart=on-failure
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable proxy.service
  systemctl start proxy.service
}

# 设置 OpenRC 服务
setup_openrc() {
  cat >/etc/init.d/proxy <<EOF
#!/sbin/openrc-run

name="proxy"
description="代理服务 ($PROXY_TYPE)"
command="$PROXY_BIN"
command_args="run -c $PROXY_CONFIG"
command_background=true
pidfile="/run/proxy.pid"
command_user="nobody:nogroup"

depend() {
  need net
}
EOF
  chmod +x /etc/init.d/proxy
  rc-update add proxy default
  rc-service proxy start
}

# 显示节点信息
show_node_info() {
  echo "SOCKS5 节点: ss://127.0.0.1:$SOCKS_PORT"
  echo "HTTP 节点: http://127.0.0.1:$HTTP_PORT"
}

# 卸载代理
uninstall_proxy() {
  local installed_type="未知"
  # 检查安装的代理类型
  if [ -f "$PROXY_DIR/xray" ]; then
    installed_type="xray"
  elif [ -f "$PROXY_DIR/sing-box" ]; then
    installed_type="sing-box"
  fi

  # 停止并移除服务
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl stop proxy.service
    systemctl disable proxy.service
    rm -f /etc/systemd/system/proxy.service
    systemctl daemon-reload
  elif [ "$INIT_SYSTEM" = "openrc" ]; then
    rc-service proxy stop
    rc-update del proxy default
    rm -f /etc/init.d/proxy
  fi

  # 删除安装目录
  rm -rf "$PROXY_DIR"

  # 显示相应的卸载消息
  if [ "$installed_type" != "未知" ]; then
    echo "$installed_type 卸载成功。"
  else
    echo "未找到代理安装。清理完成。"
  fi
}

# 主执行流程
if [ "$UNINSTALL" = true ]; then
  uninstall_proxy
  exit 0
fi

install_dependencies
install_proxy
create_config

case $INIT_SYSTEM in
systemd)
  setup_systemd
  ;;
*)
  setup_openrc
  ;;
esac

# 总是显示节点信息
show_node_info