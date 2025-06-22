#!/bin/sh

set -e

HTTP_PORT=8080
SOCKS_PORT=1080
RELEASE_VERSION="0.9.5"
DOWNLOAD_BASE="https://github.com/3proxy/3proxy/releases/download/$RELEASE_VERSION"
SERVICE_FILE="/etc/systemd/system/3proxy.service"

print_help() {
    echo "使用方法: $0 [-n] [-u] [-s socks_port] [-h http_port]"
    echo "  -n: 显示节点信息"
    echo "  -u: 卸载代理（包括关闭 systemd 服务）"
    echo "  -s: 指定 SOCKS5 端口 (默认: 1080)"
    echo "  -h: 指定 HTTP 端口 (默认: 8080)"
    exit 0
}

show_node() {
    echo "HTTP代理监听: 127.0.0.1:$HTTP_PORT"
    echo "SOCKS5代理监听: 127.0.0.1:$SOCKS_PORT"
    echo "3proxy 运行状态: $(systemctl is-active 3proxy.service || echo inactive)"
    exit 0
}

check_port() {
    PORT=$1
    if command -v lsof >/dev/null 2>&1 && lsof -i :$PORT | grep -q LISTEN; then
        echo "端口 $PORT 已被占用 (lsof)"
        exit 1
    elif command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ":$PORT "; then
        echo "端口 $PORT 已被占用 (ss)"
        exit 1
    elif command -v netstat >/dev/null 2>&1 && netstat -tln | grep -q ":$PORT "; then
        echo "端口 $PORT 已被占用 (netstat)"
        exit 1
    fi
}

install_http_tool() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl -L -o"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget -O"
    else
        echo "正在安装 curl..."
        if command -v apt >/dev/null 2>&1; then
            apt update -qq && apt install -y curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl
        else
            echo "无法安装 curl，未知包管理器"
            exit 1
        fi
        DOWNLOADER="curl -L -o"
    fi
}

uninstall_3proxy() {
    echo "🔧 正在卸载 3proxy..."

    if systemctl is-active --quiet 3proxy.service; then
        systemctl stop 3proxy.service
    fi
    systemctl disable 3proxy.service || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reexec || systemctl daemon-reload

    if command -v apt >/dev/null 2>&1; then
        apt remove -y 3proxy || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y 3proxy || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y 3proxy || true
    fi
    rm -rf /etc/3proxy

    echo "✅ 3proxy 卸载完成。"
    exit 0
}

# 解析参数
while getopts "h:s:nu" opt; do
    case $opt in
    h) HTTP_PORT="$OPTARG" ;;
    s) SOCKS_PORT="$OPTARG" ;;
    n) show_node ;;
    u) uninstall_3proxy ;;
    *) print_help ;;
    esac
done

# 检查端口是否被占用
check_port "$HTTP_PORT"
check_port "$SOCKS_PORT"

# 检查系统架构
ARCH=$(uname -m)
case "$ARCH" in
x86_64) ARCH_NAME="x86_64" ;;
aarch64) ARCH_NAME="aarch64" ;;
armv7l | armhf | armv6l) ARCH_NAME="arm" ;;
*) echo "❌ 不支持的架构: $ARCH" && exit 1 ;;
esac

# 检查系统类型
OS_TYPE="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
    debian | ubuntu | linuxmint) OS_TYPE="debian" ;;
    rhel | centos | fedora | rocky | almalinux) OS_TYPE="redhat" ;;
    alpine)
        echo "❌ 不支持 Alpine 系统，请使用 Debian 或 RedHat 系列。"
        exit 1
        ;;
    esac
fi

# 下载并安装
install_http_tool
case "$OS_TYPE" in
debian)
    PKG_NAME="3proxy-$RELEASE_VERSION.$ARCH_NAME.deb"
    $DOWNLOADER /tmp/3proxy.deb "$DOWNLOAD_BASE/$PKG_NAME"
    dpkg -i /tmp/3proxy.deb || apt install -f -y
    ;;
redhat)
    PKG_NAME="3proxy-$RELEASE_VERSION.$ARCH_NAME.rpm"
    $DOWNLOADER /tmp/3proxy.rpm "$DOWNLOAD_BASE/$PKG_NAME"
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y /tmp/3proxy.rpm
    else
        yum install -y /tmp/3proxy.rpm
    fi
    ;;
*)
    echo "❌ 不支持的系统类型。" && exit 1
    ;;
esac

# 写入配置文件
mkdir -p /etc/3proxy
cat >/etc/3proxy/3proxy.cfg <<EOF
#!/bin/3proxy
auth none
proxy -p$HTTP_PORT -a -i127.0.0.1
socks -p$SOCKS_PORT -a -i127.0.0.1
EOF

# 创建 systemd 单元文件
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=3proxy Lightweight Proxy Server
After=network.target

[Service]
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

# 重载 systemd 并启动服务
systemctl daemon-reload
systemctl enable 3proxy.service
systemctl restart 3proxy.service

sleep 1
if systemctl is-active --quiet 3proxy.service; then
    echo "✅ 3proxy 已通过 systemd 启动并设置为开机自启。"
    show_node
else
    echo "❌ 3proxy 启动失败，请运行 systemctl status 3proxy 查看日志。"
    exit 1
fi
