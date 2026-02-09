#!/bin/bash
set -e

# 定义全局变量
ET_VERSION="latest"
ET_PORT=${ET_PORT:-29879}
ET_PASS=${ET_PASS:-$(cat /proc/sys/kernel/random/uuid)}
ET_LOG="/var/log/easytier.log"
ET_SERVICE="/etc/systemd/system/easytier.service"
ET_BIN="/usr/local/bin/easytier"

# 颜色输出函数
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# 检查是否为root用户
check_root() {
    if [ $EUID -ne 0 ]; then
        red "错误：必须以root用户运行此脚本！"
        exit 1
    fi
}

# 检查系统架构
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) red "不支持的架构：$ARCH"; exit 1 ;;
    esac
    echo $ARCH
}

# 下载easytier二进制文件
download_easytier() {
    green "开始下载easytier二进制文件..."
    local ARCH=$(check_arch)
    local DOWNLOAD_URL="https://github.com/EasyTier/EasyTier/releases/${ET_VERSION}/download/easytier-linux-${ARCH}"

    if ! wget -q -O ${ET_BIN} ${DOWNLOAD_URL}; then
        red "下载失败！请检查网络或版本是否存在。"
        exit 1
    fi

    chmod +x ${ET_BIN}
    green "下载完成：${ET_BIN}"
}

# 启动easytier服务（核心修改：添加 --private 参数开启私有模式）
start_easytier() {
    # 检查进程是否已运行
    if pgrep -f "easytier server" > /dev/null; then
        yellow "easytier服务已在运行！"
        return 0
    fi

    # 核心修改点：添加 --private 参数，默认开启私有模式
    nohup ${ET_BIN} server --private --port ${ET_PORT} --password ${ET_PASS} > ${ET_LOG} 2>&1 &

    # 等待进程启动
    sleep 2
    if pgrep -f "easytier server" > /dev/null; then
        green "easytier服务启动成功（私有模式已开启）！"
        green "端口：${ET_PORT}"
        green "密码：${ET_PASS}"
        green "日志：${ET_LOG}"
    else
        red "easytier服务启动失败！请查看日志：${ET_LOG}"
        exit 1
    fi
}

# 停止easytier服务
stop_easytier() {
    if ! pgrep -f "easytier server" > /dev/null; then
        yellow "easytier服务未运行！"
        return 0
    fi

    pkill -f "easytier server"
    sleep 2
    if ! pgrep -f "easytier server" > /dev/null; then
        green "easytier服务已停止！"
    else
        red "easytier服务停止失败！请手动执行 kill -9 $(pgrep -f 'easytier server')"
        exit 1
    fi
}

# 重启easytier服务
restart_easytier() {
    stop_easytier
    start_easytier
}

# 查看easytier状态
status_easytier() {
    if pgrep -f "easytier server" > /dev/null; then
        green "easytier服务正在运行！"
        green "进程信息："
        ps aux | grep "easytier server" | grep -v grep
    else
        red "easytier服务未运行！"
    fi
}

# 设置开机自启
enable_easytier() {
    green "创建systemd服务文件..."
    cat > ${ET_SERVICE} << EOF
[Unit]
Description=EasyTier Server
After=network.target

[Service]
Type=simple
ExecStart=${ET_BIN} server --private --port ${ET_PORT} --password ${ET_PASS}
ExecStop=pkill -f "easytier server"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable easytier
    green "开机自启已配置完成！"
}

# 卸载easytier
uninstall_easytier() {
    stop_easytier
    rm -rf ${ET_BIN} ${ET_LOG} ${ET_SERVICE}
    systemctl daemon-reload
    green "easytier已完全卸载！"
}

# 主菜单
main() {
    check_root
    case $1 in
        install)
            download_easytier
            start_easytier
            enable_easytier
            ;;
        start)
            start_easytier
            ;;
        stop)
            stop_easytier
            ;;
        restart)
            restart_easytier
            ;;
        status)
            status_easytier
            ;;
        uninstall)
            uninstall_easytier
            ;;
        *)
            echo "用法：$0 [install|start|stop|restart|status|uninstall]"
            echo "示例："
            echo "  安装并启动：$0 install"
            echo "  启动服务：$0 start"
            echo "  停止服务：$0 stop"
            echo "  重启服务：$0 restart"
            echo "  查看状态：$0 status"
            echo "  卸载服务：$0 uninstall"
            exit 1
            ;;
    esac
}

# 执行主菜单
main $@