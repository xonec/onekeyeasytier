#!/bin/sh

#================================================================================
# EasyTier OpenWrt 专属部署管理脚本
# 适配 OpenWrt (aarch64) 环境，使用 procd 进行服务管理。
#================================================================================

# --- 脚本配置 ---
GITHUB_PROXY="ghfast.top"

# 颜色定义
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# --- OpenWrt 专属路径和文件名 ---
INSTALL_DIR="/usr/bin"
CONFIG_DIR="/etc/easytier"
CONFIG_FILE="${CONFIG_DIR}/easytier.toml"
CORE_BINARY_NAME="easytier-core"
CLI_BINARY_NAME="easytier-cli"
ALIAS_PATH="/usr/bin/et"
SERVICE_NAME="easytier"
SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

# --- OpenWrt aarch64 专属下载链接 ---
DOWNLOAD_URL="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/v2.3.2/easytier-linux-aarch64-v2.3.2.zip"


# --- 辅助函数 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以 root 权限运行。${NC}"; exit 1
    fi
}

check_arch() {
    CURRENT_ARCH=$(uname -m)
    if [ "$CURRENT_ARCH" != "aarch64" ]; then
        echo -e "${RED}错误: 此脚本专为 aarch64 架构设计。检测到当前架构为: $CURRENT_ARCH${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=""
    # find 和 mktemp 通常是 busybox 自带的，但为保险起见加入检查
    for cmd in curl unzip find mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps="$missing_deps $cmd"
        fi
    done

    if [ -n "$missing_deps" ]; then
        echo -e "${YELLOW}检测到缺失的依赖: ${missing_deps}${NC}"
        read -p "是否尝试使用 opkg 自动安装? (y/n): " choice
        if [ "$choice" != "y" ] && [ "$choice" != "Y" ]; then
            echo -e "${RED}操作中止。${NC}"; exit 1
        fi
        
        opkg update
        opkg install $missing_deps
        for dep in $missing_deps; do
             if ! command -v "$dep" >/dev/null 2>&1; then
                echo -e "${RED}依赖 '$dep' 安装失败。请手动安装后重试。${NC}"; exit 1
             fi
        done
    fi
}

check_installed() {
    if [ ! -f "${INSTALL_DIR}/${CORE_BINARY_NAME}" ]; then
        echo -e "${YELLOW}EasyTier 尚未安装。请先选择选项 1。${NC}"; return 1
    fi
    return 0
}

set_toml_value() {
    sed -i.bak "s|^#* *${1} *=.*|${1} = ${2}|" "$3" && rm "${3}.bak"
}


# --- OpenWrt 服务管理功能 ---
create_service_file() {
    mkdir -p "$(dirname "${SERVICE_FILE}")"
    cat > "${SERVICE_FILE}" << 'EOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=01

PROG=/usr/bin/easytier-core
CONFIG_FILE="/etc/easytier/easytier.toml"

start_service() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "配置文件 $CONFIG_FILE 未找到"
        return 1
    fi
    
    procd_open_instance
    procd_set_param command ${PROG} -c ${CONFIG_FILE}
    procd_set_param respawn
    procd_set_param file ${CONFIG_FILE}
    procd_close_instance
}

reload_service() {
    stop
    start
}

service_triggers() {
    procd_add_reload_trigger "easytier"
}
EOF
    chmod +x "${SERVICE_FILE}"
    echo -e "${GREEN}OpenWrt init 脚本创建成功: ${SERVICE_FILE}${NC}"
}

start_service() { service_action start; }
stop_service() { service_action stop; }
restart_service() { service_action restart; }
enable_service() { service_action enable; }
disable_service() { service_action disable; }
status_service() { service_action status; }

service_action() {
    if [ ! -f "${SERVICE_FILE}" ]; then
        echo -e "${YELLOW}服务脚本 ${SERVICE_FILE} 不存在。请先部署网络以创建它。${NC}"
        return 1
    fi
    ${SERVICE_FILE} "$1"
}

log_service() {
    echo "正在使用 logread 查看日志，按 Ctrl+C 退出。"
    logread -f -e ${CORE_BINARY_NAME}
}

# --- 主功能函数 ---
create_shortcut() {
    local SCRIPT_PATH
    SCRIPT_PATH=$(realpath "$0" 2>/dev/null || (cd "$(dirname "$0")" && echo "$(pwd)/$(basename "$0")"))
    if [ -L "${ALIAS_PATH}" ] && [ "$(readlink "${ALIAS_PATH}")" = "${SCRIPT_PATH}" ]; then
        return 0
    fi
    echo -e "${YELLOW}正在创建 'et' 快捷命令...${NC}"
    chmod +x "${SCRIPT_PATH}"
    ln -sf "${SCRIPT_PATH}" "${ALIAS_PATH}"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功! 现在你可以在终端中直接输入 'et' 来运行此脚本。${NC}"
    else
        echo -e "${RED}创建快捷命令失败。请检查权限。${NC}"
    fi
}

remove_shortcut() {
    if [ -L "${ALIAS_PATH}" ]; then
        rm -f "${ALIAS_PATH}" >/dev/null 2>&1
    fi
}

install_easytier() {
    echo -e "${GREEN}--- 开始安装或更新 EasyTier (OpenWrt/aarch64) ---${NC}"

    local download_file_url="${DOWNLOAD_URL}"
    if [ -n "$GITHUB_PROXY" ] && ! echo "${download_file_url}" | grep -q "${GITHUB_PROXY}"; then
        download_file_url=$(echo "$DOWNLOAD_URL" | sed "s|https://|https://${GITHUB_PROXY}/|")
        echo -e "${YELLOW}1. 使用代理下载: ${download_file_url}${NC}"
    else
        echo "1. 直接下载: ${download_file_url}"
    fi

    local temp_file
    temp_file=$(mktemp)
    
    curl -L --progress-bar -o "$temp_file" "$download_file_url"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败!${NC}"; rm -f "$temp_file"; return 1
    fi
    
    echo "2. 创建临时解压目录并解压..."
    local extract_dir
    extract_dir=$(mktemp -d)
    
    unzip -o "$temp_file" -d "$extract_dir" > /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压失败! 请检查文件是否为有效的 zip 格式。${NC}"
        rm -f "$temp_file"; rm -rf "$extract_dir"; return 1
    fi

    echo "3. 查找核心文件..."
    local found_core
    found_core=$(find "$extract_dir" -type f -name "${CORE_BINARY_NAME}")
    local found_cli
    found_cli=$(find "$extract_dir" -type f -name "${CLI_BINARY_NAME}")

    if [ -z "$found_core" ] || [ -z "$found_cli" ]; then
        echo -e "${RED}错误: 在解压目录中未动态找到核心文件。${NC}"
        rm -f "$temp_file"; rm -rf "$extract_dir"; return 1
    fi
    
    echo "4. 安装文件..."
    mkdir -p "$INSTALL_DIR"
    mv -f "$found_core" "${INSTALL_DIR}/${CORE_BINARY_NAME}"
    mv -f "$found_cli" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
    chmod +x "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
    
    rm -f "$temp_file"; rm -rf "$extract_dir"
    
    echo -e "${GREEN}--- EasyTier 安装/更新成功! ---${NC}"
    create_shortcut
    
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}检测到现有服务，正在重启以应用更新...${NC}"
        restart_service
    fi
}

create_default_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# === EasyTier 配置文件 (由脚本生成) ===
ipv4 = ""
dhcp = false
listeners = ["udp://0.0.0.0:11010", "tcp://0.0.0.0:11010", "wg://0.0.0.0:11011", "ws://0.0.0.0:11011/", "wss://0.0.0.0:11012/", "tcp://[::]:11010", "udp://[::]:11010"]
[network_identity]
network_name = ""
network_secret = ""
[flags]
default_protocol = "udp"
dev_name = ""
enable_encryption = true
enable_ipv6 = true
mtu = 1380
latency_first = true
enable_exit_node = false
no_tun = false
use_smoltcp = false
foreign_network_whitelist = "*"
disable_p2p = false
relay_all_peer_rpc = false
disable_udp_hole_punching = false
enableKcp_Proxy = true
EOF
    if [ $? -eq 0 ]; then
       echo "已成功创建默认配置文件: ${CONFIG_FILE}"; return 0
    else
       echo -e "${RED}错误: 创建配置文件失败!${NC}"; return 1
    fi
}

deploy_new_network() { 
    check_installed || return 1
    read -p "请输入网络名称: " network_name
    read -p "请输入网络密钥: " network_secret
    read -p "请输入此节点虚拟IP (留空则启用DHCP): " virtual_ip
    
    create_default_config || return 1
    
    set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
    set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
    
    if [ -z "$virtual_ip" ]; then
        echo -e "${YELLOW}未输入IP，将启用 DHCP 自动获取地址。${NC}"
        set_toml_value "dhcp" "true" "$CONFIG_FILE"
        set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
    else
        echo -e "${GREEN}已设置静态IP: ${virtual_ip}${NC}"
        set_toml_value "dhcp" "false" "$CONFIG_FILE"
        set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
    fi

    create_service_file
    echo -e "${YELLOW}正在应用配置并启动服务...${NC}"
    start_service
    echo -e "${GREEN}--- 新网络部署并启动成功! ---${NC}"
    sleep 2; status_service
}

join_existing_network() { 
    check_installed || return 1
    read -p "请输入网络名称: " network_name
    read -p "请输入网络密钥: " network_secret
    read -p "请输入此节点虚拟IP (留空则启用DHCP): " virtual_ip
    read -p "请输入一个对端节点地址 (如 tcp://x.x.x.x:11010): " peer_address
    
    create_default_config || return 1

    set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
    set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
    echo -e "\n[[peer]]\n uri = \"${peer_address}\"" >> "$CONFIG_FILE"

    if [ -z "$virtual_ip" ]; then
        echo -e "${YELLOW}未输入IP，将启用 DHCP 自动获取地址。${NC}"
        set_toml_value "dhcp" "true" "$CONFIG_FILE"
        set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
    else
        echo -e "${GREEN}已设置静态IP: ${virtual_ip}${NC}"
        set_toml_value "dhcp" "false" "$CONFIG_FILE"
        set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
    fi

    create_service_file
    echo -e "${YELLOW}正在应用配置并重启服务...${NC}"
    restart_service
    echo -e "${GREEN}--- 已加入网络并重启服务! ---${NC}"
    sleep 2; status_service
}

manage_service_menu() {
    check_installed || return 1
    
    while true; do
        echo "--- 服务管理菜单 ---"; echo " 1. 启动服务"; echo " 2. 停止服务"; echo " 3. 重启服务"; echo " 4. 查看状态"; echo " 5. 设为开机自启"; echo " 6. 取消开机自启"; echo " 7. 查看实时日志"; echo " 0. 返回主菜单"; echo "--------------------"
        read -p "请选择操作 [0-7]: " sub_choice
        case $sub_choice in
            1) start_service && echo -e "${GREEN}服务已启动。${NC}"; break ;;
            2) stop_service && echo -e "${GREEN}服务已停止。${NC}"; break ;;
            3) restart_service && echo -e "${GREEN}服务已重启。${NC}"; break ;;
            4) status_service; break ;;
            5) enable_service && echo -e "${GREEN}已设置开机自启。${NC}"; break ;;
            6) disable_service && echo -e "${GREEN}已取消开机自启。${NC}"; break ;;
            7) log_service; break ;;
            0) break ;;
            *) echo -e "${RED}无效输入，请重试。${NC}" ;;
        esac; done
}

uninstall_easytier() {
    read -p "警告: 此操作将停止服务并删除所有相关文件。确定要卸载吗? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "操作已取消。"; return; fi
    
    echo "正在停止并禁用服务..."
    if [ -f "$SERVICE_FILE" ]; then stop_service >/dev/null 2>&1; disable_service >/dev/null 2>&1; fi
    
    echo "正在删除文件..."
    rm -f "${SERVICE_FILE}" "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
    rm -rf "${CONFIG_DIR}"; remove_shortcut
    
    echo -e "${GREEN}EasyTier 已成功卸载。${NC}"
}

# --- 主菜单 ---
main() {
    check_root; check_arch; check_dependencies
    
    while true; do
        clear
        echo "======================================================="; echo -e "   ${GREEN}EasyTier OpenWrt 专属管理脚本 v6.2${NC}"; echo -e "   (架构: aarch64, 自动创建 'et' 快捷命令)"; echo "======================================================="
        echo " 1. 安装或更新 EasyTier"; echo " 2. 部署新网络 (首个节点)"; echo " 3. 加入现有网络"; echo "-------------------------------------------------------"
        echo " 4. 管理服务 (启停/状态/日志)"; echo " 5. 查看配置文件"; echo " 6. 查看网络节点 (easytier-cli)"; echo "-------------------------------------------------------"
        echo " 7. 卸载 EasyTier"; echo " 0. 退出脚本"; echo "======================================================="
        read -p "请输入选项 [0-7]: " choice
        
        echo
        case $choice in
            1) install_easytier ;;
            2) deploy_new_network ;;
            3) join_existing_network ;;
            4) manage_service_menu ;;
            5) if check_installed && [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else echo -e "${YELLOW}配置文件不存在或 EasyTier 未安装。${NC}"; fi ;;
            6) if check_installed; then ${INSTALL_DIR}/${CLI_BINARY_NAME} peer; fi ;;
            7) uninstall_easytier ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${NC}" ;;
        esac
        echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"; read -n 1 -s -r
    done
}

main "$@"
