#!/bin/bash

# ===================================================================================
# Linux (Debian/Ubuntu) 服务器初始化脚本 (V5 - 专业精简版)
#
# 特点:
# - 专业、直接的指令和说明。
# - 移除了所有比喻和非必要的用户引导。
# - 修正了关键步骤的逻辑，并提供了明确的失败处理路径。
# - 默认执行重启操作以简化流程。
# ===================================================================================

# --- 配置 ---
SWAP_SIZE="2G" # 定义 Swap 文件大小

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 函数 ---
step_title() {
    echo -e "\n${BLUE}--- $1: $2 ---${NC}"
}

info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

action() {
    echo -e "${YELLOW}[ACTION] $1${NC}"
}

warn() {
    echo -e "${RED}[WARN] $1${NC}"
}

# --- 脚本开始 ---

# 0. 环境检查
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}[ERROR] 此脚本需要 root 权限执行。请使用 'sudo ./setup_server.sh' 运行。${NC}"
   exit 1
fi
set -e # 若任何命令执行失败则立即中止脚本

# 1. 前置条件说明
step_title "步骤 1" "配置云服务商安全组"
info "此脚本执行前，必须在云服务商控制台完成安全组/防火墙的配置。"
info "需要放行以下两个TCP端口的入站流量："
echo -e "  - ${YELLOW}22${NC}: 当前SSH连接使用的端口，用于执行此脚本。"
echo -e "  - ${YELLOW}一个新的高位端口${NC}: 范围 ${GREEN}49152-65535${NC}，将用作新的SSH端口。"
warn "若新的SSH端口未在安全组中放行，脚本执行后将无法通过SSH连接服务器。"
action "确认已完成上述配置后，按 Enter 键继续。"
read -p ""

# 2. 设置时区
step_title "步骤 2" "设置系统时区"
info "目的: 统一服务器日志和应用程序的时间标准。"
action "正在设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai
info "时区设置完成。当前系统时间: $(date +"%Y-%m-%d %H:%M:%S")"

# 3. 修改SSH端口
step_title "步骤 3" "修改SSH服务端口"
info "目的: 更改默认的22端口，降低被自动化工具扫描和攻击的风险。"
action "请输入新的SSH端口号 (范围 49152 - 65535):"
read -p "> " NEW_SSH_PORT
if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 49152 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
    echo -e "${RED}[ERROR] 输入无效。端口号必须是 49152-65535 之间的数字。${NC}"
    exit 1
fi
action "正在修改配置文件 /etc/ssh/sshd_config..."
sed -i.bak "s/^#\?Port [0-9]\+/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
info "SSH端口已在配置中更新为 ${NEW_SSH_PORT}。"

# 4. 安装Fail2ban
step_title "步骤 4" "安装Fail2ban"
info "目的: Fail2ban通过监控日志文件，自动阻止有恶意登录企图的IP地址。"
action "正在更新包列表并安装 Fail2ban..."
apt-get update > /dev/null 2>&1
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban
info "Fail2ban 安装并配置为开机自启。"

# 5. 应用SSH新配置并验证
step_title "步骤 5" "应用并验证新的SSH端口"
action "正在重启SSH服务以应用新端口 ${NEW_SSH_PORT}..."
systemctl restart sshd
info "SSH服务已重启。现在必须验证新端口的连通性。"
echo "-----------------------------------------------------------------------"
warn "1. 打开一个新的终端窗口。"
warn "2. 尝试使用新端口 ${GREEN}${NEW_SSH_PORT}${RED} 连接服务器。"
warn "3. ${GREEN}如果连接成功${RED}，请回到本窗口按 Enter 键继续。"
warn "4. ${RED}如果连接失败${RED}，请回到本窗口按 ${YELLOW}Ctrl+C${RED} 中止脚本。中止后，服务器将保持原样，22端口依然可用。"
echo "-----------------------------------------------------------------------"
action "请进行操作..."
read -p ""

# 6. 系统升级
step_title "步骤 6" "升级系统软件包"
info "目的: 应用最新的安全补丁和软件更新。"
action "正在执行系统升级，此过程可能需要一些时间..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" > /dev/null 2>&1
info "所有软件包已升级至最新版本。"

# 7. 配置内核参数
step_title "步骤 7" "优化内核参数"
info "目的: 启用BBR拥塞控制算法以优化网络性能，并调整Swappiness值以优先使用物理内存。"
action "正在向 /etc/sysctl.conf 添加配置..."
sed -i -e '/net.core.default_qdisc=fq/d' -e '/net.ipv4.tcp_congestion_control=bbr/d' -e '/vm.swappiness=10/d' /etc/sysctl.conf
cat <<EOF >> /etc/sysctl.conf

# Enable BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# Set swappiness
vm.swappiness=10
EOF
info "内核参数配置完成。"

# 8. 创建Swap文件
step_title "步骤 8" "创建并启用Swap交换文件"
info "目的: 当物理内存(RAM)不足时，使用Swap空间作为虚拟内存，防止系统因内存溢出而崩溃。"
if [ -f /swapfile ]; then
    info "Swap 文件 /swapfile 已存在，跳过创建。"
else
    action "正在创建 ${SWAP_SIZE} 的 Swap 文件..."
    fallocate -l ${SWAP_SIZE} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    info "Swap 文件创建、启用并已设置为开机自启。"
fi

# 9. 应用配置并准备重启
step_title "步骤 9" "应用配置并准备重启"
action "正在应用内核参数..."
sysctl -p > /dev/null 2>&1
info "所有配置已写入。需要重启服务器以使所有更改（特别是内核模块）完全生效。"
action "是否要立即重启服务器? [Y/n]"
read -n 1 -r REPLY
echo

if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
    info "服务器将立即重启。"
else
    info "已选择稍后重启。请在方便时手动执行 'sudo reboot'。"
fi

# 10. 重启后操作指南
step_title "步骤 10" "重启后的最终步骤"
info "重启并使用新端口 ${GREEN}${NEW_SSH_PORT}${NC} 成功登录后，请执行以下操作："
echo -e "  1. ${YELLOW}验证配置:${NC} 执行以下命令检查BBR和Swap状态。"
echo -e "     ${GREEN}sudo sysctl net.ipv4.tcp_congestion_control && free -h${NC}"
echo -e "     预期输出应包含 'bbr' 并且Swap总量为 ${SWAP_SIZE}。"
echo ""
echo -e "  2. ${YELLOW}关闭旧端口:${NC} 确认一切正常后，登录云服务商控制台，从安全组中移除针对TCP 22端口的规则。这是完成安全加固的最后一步。"

if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
    reboot
fi

exit 0
