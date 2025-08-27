#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 5.5 (最终稳定版)
# 作者: Qingjue
# 功能: 自动化部署 SillyTavern Docker 版，提供极致的自动化、健壮性和用户体验。

# --- 初始化与环境设置 ---
set -e

# --- 色彩定义 ---
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ $1${NC}"; }
fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; exit 1; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_info() { echo -e "  $1"; }

# --- 核心函数 ---
fn_get_public_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org) || \
    ip=$(curl -s --max-time 5 https://ifconfig.me) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

fn_get_location_details() {
    local details
    details=$(curl -s --max-time 4 https://ipinfo.io/json) || echo ""
    if [[ -z "$details" ]]; then
        details=$(curl -s --max-time 4 https://ip.sb/geoip/) || echo ""
    fi
    
    local country_code=$(echo "$details" | grep -oP '"country_code":\s*"\K[^"]+' | head -n 1)
    local country=$(echo "$details" | grep -oP '"country":\s*"\K[^"]+' | head -n 1)
    local region=$(echo "$details" | grep -oP '"region":\s*"\K[^"]+' | head -n 1)

    if [[ -n "$country_code" ]]; then
        echo "${country_code}|${country}, ${region}"
    else
        echo "UNKNOWN|无法确定位置"
    fi
}

fn_handle_mirror_config() {
    local choice="$1"
    if [[ "$choice" == "mainland" ]]; then
        fn_print_info "正在为您配置国内 Docker 加速镜像..."
        tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://hub1.nat.tf",
    "https://docker.1panel.live",
    "https://dockerproxy.1panel.live",
    "https://hub.rat.dev",
    "https://docker.amingg.com"
  ]
}
EOF
        fn_print_info "配置文件 /etc/docker/daemon.json 已更新。"
        systemctl restart docker || fn_print_error "Docker 服务重启失败！请手动排查。"
        fn_print_success "Docker 服务已重启，加速配置生效！"
    elif [[ "$choice" == "overseas" ]]; then
        if [ -f "/etc/docker/daemon.json" ]; then
            fn_print_info "正在清除旧的 Docker 镜像配置..."
            rm -f /etc/docker/daemon.json
            systemctl restart docker || fn_print_warning "Docker 重启失败，可能无需操作。"
            fn_print_success "Docker 镜像配置已清除。"
        else
            fn_print_info "无需操作，跳过 Docker 镜像配置。"
        fi
    fi
}

fn_configure_docker_mirror() {
    fn_print_info "正在检测服务器地理位置..."
    IFS='|' read -r country_code location_display <<< "$(fn_get_location_details)"
    
    echo -e "  ${YELLOW}检测结果: ${location_display}${NC}"

    # 【关键修复】如果位置未知，先让用户手动确认
    if [[ "$country_code" == "UNKNOWN" ]]; then
        echo "无法自动判断，请手动选择您的服务器位置："
        echo -e "  [1] 我在中国大陆"
        echo -e "  [2] 我在海外"
        read -p "请输入选项数字: " manual_choice < /dev/tty
        if [[ "$manual_choice" == "1" ]]; then
            country_code="CN"
        else
            country_code="OVERSEAS" # 使用一个非CN的占位符
        fi
    fi

    # 【关键修复】统一的、带完整选项的菜单逻辑
    if [[ "$country_code" == "CN" ]]; then
        echo "请选择操作："
        echo -e "  [1] ${GREEN}配置国内加速镜像 (推荐)${NC}"
        echo -e "  [2] 跳过"
        echo -e "  [3] 检测有误，我是海外服务器"
        read -p "请输入选项数字 [默认为 1]: " choice < /dev/tty
        choice=${choice:-1}
        case "$choice" in
            1) fn_handle_mirror_config "mainland" ;;
            2) fn_print_info "已跳过镜像配置。" ;;
            3) fn_handle_mirror_config "overseas" ;;
            *) fn_print_warning "无效输入，已跳过。" ;;
        esac
    else # 海外或手动选择的海外
        echo "请选择操作："
        echo -e "  [1] 清除可能存在的国内镜像配置"
        echo -e "  [2] ${GREEN}跳过 (推荐)${NC}"
        echo -e "  [3] 检测有误，我是国内服务器"
        read -p "请输入选项数字 [默认为 2]: " choice < /dev/tty
        choice=${choice:-2}
        case "$choice" in
            1) fn_handle_mirror_config "overseas" ;;
            2) fn_print_info "已跳过镜像配置。" ;;
            3) fn_handle_mirror_config "mainland" ;;
            *) fn_print_warning "无效输入，已跳过。" ;;
        esac
    fi
}

fn_confirm_and_delete_dir() {
    local dir_to_delete="$1"
    fn_print_warning "目录 '$dir_to_delete' 已存在，其中可能包含您之前的聊天记录和角色卡。"
    echo -ne "您确定要删除此目录并继续安装吗？(${GREEN}y${NC}/${RED}n${NC}): "
    read -r confirm1 < /dev/tty
    if [[ "$confirm1" != "y" ]]; then fn_print_error "操作被用户取消。"; fi
    echo -ne "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}"
    read -r confirm3 < /dev/tty
    if [[ "$confirm3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi
    fn_print_info "正在删除旧目录: $dir_to_delete..."
    rm -rf "$dir_to_delete"
    fn_print_success "旧目录已删除。"
}

# ==============================================================================
#   主逻辑开始
# ==============================================================================

clear
echo -e "${CYAN}╔═════════════════════════════════╗${NC}"
echo -e "${CYAN}║      ${BOLD}SillyTavern 助手 v1.0${NC}      ${CYAN}║${NC}"
echo -e "${CYAN}║   by Qingjue | XHS:826702880    ${CYAN}║${NC}"
echo -e "${CYAN}╚═════════════════════════════════╝${NC}"
echo -e "\n本助手将引导您完成 SillyTavern 的自动化安装。"

# --- 阶段一：环境自检与准备 ---
fn_print_step "[ 1 / 5 ] 环境检查与准备"
if [ "$(id -u)" -ne 0 ]; then fn_print_error "本脚本需要以 root 权限运行。请使用 'sudo' 执行。"; fi
TARGET_USER="${SUDO_USER:-root}"
if [ "$TARGET_USER" = "root" ]; then
    USER_HOME="/root"
    fn_print_warning "您正以 root 用户身份直接运行脚本，将安装在 /root 目录下。"
else
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ -z "$USER_HOME" ]; then fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"; fi
fi
INSTALL_DIR="$USER_HOME/sillytavern"
CONFIG_FILE="$INSTALL_DIR/config.yaml"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
fn_print_info "正在检查核心依赖..."
if ! command -v docker &> /dev/null; then fn_print_error "未检测到 Docker。"; fi
if command -v docker-compose &> /dev/null; then DOCKER_COMPOSE_CMD="docker-compose"; elif docker compose version &> /dev/null; then DOCKER_COMPOSE_CMD="docker compose"; else fn_print_error "未检测到 Docker Compose。"; fi
fn_print_success "核心依赖检查通过！"
fn_configure_docker_mirror

# --- 阶段二：交互式配置 ---
fn_print_step "[ 2 / 5 ] 选择运行模式"
echo "请选择您希望的运行模式："
echo -e "  [1] ${CYAN}单用户模式${NC} (简单，适合个人使用)"
echo -e "  [2] ${CYAN}多用户模式${NC} (推荐，拥有独立的登录页面)"
read -p "请输入选项数字 [默认为 2]: " run_mode < /dev/tty
run_mode=${run_mode:-2}
if [[ "$run_mode" == "1" ]]; then
    read -p "请输入您的自定义用户名: " single_user < /dev/tty
    read -p "请输入您的自定义密码: " single_pass < /dev/tty
    if [ -z "$single_user" ] || [ -z "$single_pass" ]; then fn_print_error "用户名和密码不能为空！"; fi
elif [[ "$run_mode" != "2" ]]; then fn_print_error "无效输入，脚本已终止。"; fi

# --- 阶段三：自动化部署 ---
fn_print_step "[ 3 / 5 ] 创建项目文件"
if [ -d "$INSTALL_DIR" ]; then fn_confirm_and_delete_dir "$INSTALL_DIR"; fi
fn_print_info "正在创建项目目录结构..."
mkdir -p "$INSTALL_DIR/data"
mkdir -p "$INSTALL_DIR/plugins"
mkdir -p "$INSTALL_DIR/public/scripts/extensions/third-party"
chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
chmod -R 777 "$INSTALL_DIR"
fn_print_success "项目目录创建并授权成功！"
cat <<EOF > "$COMPOSE_FILE"
services:
  sillytavern:
    container_name: sillytavern
    image: ghcr.io/sillytavern/sillytavern:latest
    ports: ["8000:8000"]
    volumes:
      - "./:/home/node/app/config"
      - "./data:/home/node/app/data"
      - "./plugins:/home/node/app/plugins"
      - "./public/scripts/extensions/third-party:/home/node/app/public/scripts/extensions/third-party"
    restart: unless-stopped
EOF
fn_print_success "docker-compose.yml 文件创建成功！"

# --- 阶段四：初始化与配置 ---
fn_print_step "[ 4 / 5 ] 初始化与配置"
fn_print_info "正在拉取 SillyTavern 镜像，可能需要几分钟..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" pull || fn_print_error "拉取 Docker 镜像失败！"
fn_print_info "正在进行首次启动以生成配置文件..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
timeout=60
while [ ! -f "$CONFIG_FILE" ]; do
    if [ $timeout -eq 0 ]; then fn_print_error "等待配置文件生成超时！请运行 '$DOCKER_COMPOSE_CMD -f \"$COMPOSE_FILE\" logs' 查看日志。"; fi
    sleep 1; ((timeout--))
done
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" down > /dev/null
fn_print_success "最新的 config.yaml 文件已生成！"
fn_print_info "正在使用 sed 精准修改配置..."
sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true/" "$CONFIG_FILE"
sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false/" "$CONFIG_FILE"
sed -i -E "s/^([[:space:]]*)sessionTimeout: .*/\1sessionTimeout: 86400/" "$CONFIG_FILE"
sed -i -E "s/^([[:space:]]*)lazyLoadCharacters: .*/\1lazyLoadCharacters: true/" "$CONFIG_FILE"
if [[ "$run_mode" == "1" ]]; then
    sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)username: .*/\1username: \"$single_user\"/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)password: .*/\1password: \"$single_pass\"/" "$CONFIG_FILE"
    fn_print_success "单用户模式配置写入完成！"
else
    sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true/" "$CONFIG_FILE"
    fn_print_info "正在临时启动服务以设置管理员..."
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
    SERVER_IP=$(fn_get_public_ip)
    echo -e "\n${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}"
    echo "1. ${CYAN}【开放端口】${NC} 请确保您已在服务器后台开放了 ${GREEN}8000${NC} 端口。"
    echo "2. ${CYAN}【访问并登录】${NC} 请访问: ${GREEN}http://${SERVER_IP}:8000${NC} (按住 Ctrl 并单击)"
    echo "   使用默认凭据登录: 账号: ${YELLOW}user${NC} 密码: ${YELLOW}password${NC}"
    echo "3. ${CYAN}【设置管理员】${NC} 登录后，请在右上角【管理员面板】中创建您的管理员账号。"
    echo -e "${YELLOW}>>> 完成以上所有步骤后，请回到本窗口，然后按下【回车键】继续 <<<${NC}"
    read -p "" < /dev/tty
    sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)enableDiscreetLogin: .*/\1enableDiscreetLogin: true/" "$CONFIG_FILE"
    fn_print_success "多用户模式配置写入完成！"
fi

# --- 阶段五：最终启动 ---
fn_print_step "[ 5 / 5 ] 最终启动"
fn_print_info "正在应用最终配置并重启服务..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate > /dev/null
SERVER_IP=$(fn_get_public_ip)
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
echo -e "║                      部署成功！尽情享受吧！                      ║"
echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:8000${NC} (按住 Ctrl 并单击)"
if [[ "$run_mode" == "1" ]]; then
    echo -e "  ${CYAN}登录账号:${NC} ${YELLOW}${single_user}${NC}"
    echo -e "  ${CYAN}登录密码:${NC} ${YELLOW}${single_pass}${NC}"
elif [[ "$run_mode" == "2" ]]; then
    echo -e "  ${YELLOW}首次登录:${NC} 为确保看到新的登录页，请访问 ${GREEN}http://${SERVER_IP}:8000/login${NC} (按住 Ctrl 并单击)"
fi
echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
echo -e "\n"
