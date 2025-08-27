#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 7.0 (重构优化版)
# 作者: Qingjue (由 AI 助手基于 v6.0 优化)
# 更新日志 (v7.0):
# - [安全] 修复了 'chmod 777' 的致命安全漏洞，采用更安全的权限设置。
# - [健壮] 优先使用 yq/jq 修改 yaml/json，大幅提升配置修改的可靠性。
# - [兼容] 在 yq/jq 不存在时，自动回退到 sed/grep 方案。
# - [结构] 重构代码，将依赖检查、配置应用等逻辑封装成独立函数，提升可读性。

# --- 初始化与环境设置 ---
set -e

# --- 色彩定义 ---
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 全局变量 ---
USE_YQ=false
USE_JQ=false

# --- 辅助函数 ---
fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ $1${NC}"; }
fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; exit 1; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_info() { echo -e "  $1"; }

# --- 核心函数 ---

fn_check_dependencies() {
    fn_print_info "正在检查核心依赖..."
    if ! command -v docker &> /dev/null; then fn_print_error "未检测到 Docker。"; fi
    if command -v docker-compose &> /dev/null; then DOCKER_COMPOSE_CMD="docker-compose"; elif docker compose version &> /dev/null; then DOCKER_COMPOSE_CMD="docker compose"; else fn_print_error "未检测到 Docker Compose。"; fi
    
    if command -v yq &> /dev/null; then
        USE_YQ=true
        fn_print_success "检测到 yq，将使用 yq 修改配置 (更稳定)。"
    else
        fn_print_warning "未检测到 yq。将使用 sed 修改配置，在 SillyTavern 更新后可能失效。"
    fi

    if command -v jq &> /dev/null; then
        USE_JQ=true
    fi
    fn_print_success "核心依赖检查通过！"
}

fn_get_public_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org) || \
    ip=$(curl -s --max-time 5 https://ifconfig.me) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

fn_get_location_details() {
    local details=""
    # 尝试服务1: ipinfo.io (支持 jq)
    details=$(curl -s --max-time 4 https://ipinfo.io/json)
    if [[ -n "$details" && "$details" != *"Rate limit exceeded"* ]]; then
        if [ "$USE_JQ" = true ]; then
            local country_code=$(echo "$details" | jq -r '.country')
            local region=$(echo "$details" | jq -r '.region')
            if [[ "$country_code" != "null" ]]; then echo "${country_code}|${country_code}, ${region}" && return; fi
        else # jq 不存在，回退到 grep
            local country_code=$(echo "$details" | grep -oP '"country":\s*"\K[^"]+' | head -n 1)
            local region=$(echo "$details" | grep -oP '"region":\s*"\K[^"]+' | head -n 1)
            if [[ -n "$country_code" ]]; then echo "${country_code}|${country_code}, ${region}" && return; fi
        fi
    fi
    # 尝试服务2: myip.ipip.net (对国内友好)
    details=$(curl -s --max-time 4 https://myip.ipip.net)
    if [[ "$details" == *"中国"* ]]; then
        echo "CN|$(echo "$details" | awk '{print $3, $4}')" && return
    elif [[ -n "$details" ]]; then
        echo "OVERSEAS|$(echo "$details" | awk '{print $3, $4}')" && return
    fi
    echo "UNKNOWN|无法确定位置"
}

fn_handle_mirror_config() {
    local choice="$1"
    if [[ "$choice" == "mainland" ]]; then
        fn_print_info "正在为您配置国内 Docker 加速镜像..."
        # 这些镜像地址可能会失效，保留硬编码是为了脚本的独立性
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
    elif [[ "$country_code" != "UNKNOWN" ]]; then
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
    else
        echo "无法自动判断，请手动选择您的服务器位置："
        echo -e "  [1] 我在中国大陆"
        echo -e "  [2] 我在海外"
        read -p "请输入选项数字: " choice < /dev/tty
        case "$choice" in
            1) fn_handle_mirror_config "mainland" ;;
            2) fn_handle_mirror_config "overseas" ;;
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
    echo -ne "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 (${GREEN}y${NC}/${RED}n${NC}): ${NC}"
    read -r confirm2 < /dev/tty
    if [[ "$confirm2" != "y" ]]; then fn_print_error "操作被用户取消。"; fi
    echo -ne "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}"
    read -r confirm3 < /dev/tty
    if [[ "$confirm3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi
    fn_print_info "正在删除旧目录: $dir_to_delete..."
    rm -rf "$dir_to_delete"
    fn_print_success "旧目录已删除。"
}

fn_create_project_structure() {
    fn_print_info "正在创建项目目录结构..."
    mkdir -p "$INSTALL_DIR/data"
    mkdir -p "$INSTALL_DIR/plugins"
    mkdir -p "$INSTALL_DIR/public/scripts/extensions/third-party"
    chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
    
    fn_print_info "正在设置安全的文件权限..."
    find "$INSTALL_DIR" -type d -exec chmod 755 {} +
    find "$INSTALL_DIR" -type f -exec chmod 644 {} +
    
    fn_print_success "项目目录创建并授权成功！"
}

fn_apply_config_changes() {
    fn_print_info "正在使用 ${BOLD}${USE_YQ:+yq}${USE_YQ:-sed}${NC} 精准修改配置..."
    if [ "$USE_YQ" = true ]; then
        # 基础配置
        yq e -i '.listen = true' "$CONFIG_FILE"
        yq e -i '.whitelistMode = false' "$CONFIG_FILE"
        yq e -i '.sessionTimeout = 86400' "$CONFIG_FILE" # 24小时
        yq e -i '.backups.common.numberOfBackups = 5' "$CONFIG_FILE"
        yq e -i '.backups.chat.maxTotalBackups = 30' "$CONFIG_FILE"
        yq e -i '.performance.lazyLoadCharacters = true' "$CONFIG_FILE"
        yq e -i '.performance.memoryCacheCapacity = "128mb"' "$CONFIG_FILE"
        
        # 模式配置
        if [[ "$run_mode" == "1" ]]; then
            yq e -i '.basicAuthMode = true' "$CONFIG_FILE"
            yq e -i ".basicAuthUser.username = \"$single_user\"" "$CONFIG_FILE"
            yq e -i ".basicAuthUser.password = \"$single_pass\"" "$CONFIG_FILE"
        elif [[ "$run_mode" == "2" ]]; then
            yq e -i '.basicAuthMode = true' "$CONFIG_FILE" # 临时开启
            yq e -i '.enableUserAccounts = true' "$CONFIG_FILE"
        fi
    else # 回退到 sed
        sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)sessionTimeout: .*/\1sessionTimeout: 86400/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)numberOfBackups: .*/\1numberOfBackups: 5/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)maxTotalBackups: .*/\1maxTotalBackups: 30/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)lazyLoadCharacters: .*/\1lazyLoadCharacters: true/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)memoryCacheCapacity: .*/\1memoryCacheCapacity: '128mb'/" "$CONFIG_FILE"

        if [[ "$run_mode" == "1" ]]; then
            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)username: .*/\1username: \"$single_user\"/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)password: .*/\1password: \"$single_pass\"/" "$CONFIG_FILE"
        elif [[ "$run_mode" == "2" ]]; then
            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true/" "$CONFIG_FILE"
        fi
    fi
}

# ==============================================================================
#   主逻辑开始
# ==============================================================================

clear
echo -e "${CYAN}╔═════════════════════════════════╗${NC}"
echo -e "${CYAN}║      ${BOLD}SillyTavern 助手 v7.0${NC}      ${CYAN}║${NC}"
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
fn_check_dependencies
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
fn_create_project_structure
cat <<EOF > "$COMPOSE_FILE"
services:
  sillytavern:
    container_name: sillytavern
    hostname: sillytavern
    image: ghcr.io/sillytavern/sillytavern:latest
    environment:
      - NODE_ENV=production
      - FORCE_COLOR=1
    ports:
      - "8000:8000"
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

fn_apply_config_changes

if [[ "$run_mode" == "1" ]]; then
    fn_print_success "单用户模式配置写入完成！"
else
    fn_print_info "正在临时启动服务以设置管理员..."
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
    SERVER_IP=$(fn_get_public_ip)
    MULTI_USER_GUIDE=$(cat <<EOF

${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}
SillyTavern 已临时启动，请完成管理员的初始设置：
1. ${CYAN}【开放端口】${NC}
   请确保您已在服务器后台（如阿里云/腾讯云安全组）开放了 ${GREEN}8000${NC} 端口。
2. ${CYAN}【访问并登录】${NC}
   请打开浏览器，访问: ${GREEN}http://${SERVER_IP}:8000${NC} (按住 Ctrl 并单击鼠标左键打开)
   使用以下默认凭据登录：
     ▶ 账号: ${YELLOW}user${NC}
     ▶ 密码: ${YELLOW}password${NC}
3. ${CYAN}【设置管理员】${NC}
   登录后，请立即在右上角的【管理员面板】中操作：
   A. ${GREEN}设置密码${NC}：为默认账户 \`default-user\` 设置一个强大的新密码。
   B. ${GREEN}创建新账户 (推荐)${NC}：
      ① 点击“创建用户”。
      ② 自定义您的日常使用账号和密码（建议账号用纯英文）。
      ③ 创建后，点击新账户旁的【↑】箭头，将其提升为 Admin (管理员)。
4. ${CYAN}【需要帮助？】${NC}
   可访问图文教程： ${GREEN}https://stdocs.723123.xyz${NC} (按住 Ctrl 并单击鼠标左键打开)
${YELLOW}>>> 完成以上所有步骤后，请回到本窗口，然后按下【回车键】继续 <<<${NC}
EOF
)
    echo -e "${MULTI_USER_GUIDE}"
    read -p "" < /dev/tty
    
    fn_print_info "正在切换到多用户登录页模式..."
    if [ "$USE_YQ" = true ]; then
        yq e -i '.basicAuthMode = false' "$CONFIG_FILE"
        yq e -i '.enableDiscreetLogin = true' "$CONFIG_FILE"
    else
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)enableDiscreetLogin: .*/\1enableDiscreetLogin: true/" "$CONFIG_FILE"
    fi
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
