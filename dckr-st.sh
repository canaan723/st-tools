#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 1.1
# 功能: 自动化部署 SillyTavern Docker 版，为新手用户提供极致的自动化安装体验。

# --- 初始化与环境设置 ---
set -e

# --- 色彩定义 ---
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
fn_print_step() {
    echo -e "\n${CYAN}═══ $1 ═══${NC}"
}
fn_print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}
fn_print_error() {
    echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2
    exit 1
}
fn_print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}
fn_print_info() {
    echo -e "  $1"
}

# --- 核心函数 ---
fn_get_public_ip() {
    # 尝试从多个服务获取公网IP，增加成功率
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org) || \
    ip=$(curl -s --max-time 5 https://ifconfig.me) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

# ==============================================================================
#   主逻辑开始
# ==============================================================================

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗"
echo -e "║            ${BOLD}SillyTavern Docker 版保姆级部署脚本${NC}           ${CYAN}║"
echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n本脚本将引导您完成 SillyTavern 的自动化安装。"

# --- 阶段一：环境自检与准备 ---

fn_print_step "[ 1 / 5 ] 环境检查与准备"

# 1.1 权限与用户检查
if [ "$(id -u)" -ne 0 ]; then
    fn_print_error "本脚本需要以 root 权限运行。请使用 'sudo' 执行。"
fi

TARGET_USER="${SUDO_USER:-root}"
if [ "$TARGET_USER" = "root" ]; then
    USER_HOME="/root"
    fn_print_warning "您正以 root 用户身份直接运行脚本，将安装在 /root 目录下。"
else
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ -z "$USER_HOME" ]; then
        fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"
    fi
fi

INSTALL_DIR="$USER_HOME/sillytavern"
CONFIG_FILE="$INSTALL_DIR/config.yaml"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# 1.2 检查并自动安装依赖
fn_print_info "正在检查核心依赖..."
if ! command -v docker &> /dev/null; then
    fn_print_error "未检测到 Docker。\n  请先根据您服务器的操作系统安装 Docker，或使用 1Panel 面板的 Docker 管理功能。"
fi
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    fn_print_error "未检测到 Docker Compose。\n  请确保 Docker Compose v2 (插件模式) 或 v1 (独立命令) 已正确安装。"
fi

if ! command -v yq &> /dev/null; then
    fn_print_info "未检测到 yq，正在为您自动安装..."
    if command -v apt-get &> /dev/null; then
        (apt-get update && apt-get install -y yq) || fn_print_error "使用 apt 安装 yq 失败。"
    elif command -v yum &> /dev/null; then
        yum install -y yq || fn_print_error "使用 yum 安装 yq 失败。"
    elif command -v dnf &> /dev/null; then
        dnf install -y yq || fn_print_error "使用 dnf 安装 yq 失败。"
    else
        fn_print_error "不支持的操作系统，请手动安装 yq 后再运行本脚本。"
    fi
    if ! command -v yq &> /dev/null; then
        fn_print_error "yq 自动安装失败，请检查系统环境或手动安装。"
    fi
    fn_print_success "依赖工具 yq 安装成功！"
fi
fn_print_success "核心依赖检查通过！"

# 1.3 (可选) Docker 镜像加速
read -p "您是否在中国大陆服务器上运行，需要配置 Docker 加速镜像？(y/n): " use_mirror
if [[ "$use_mirror" =~ ^[yY]$ ]]; then
    fn_print_info "正在为您配置国内 Docker 加速镜像..."
    
    MIRROR_LIST='
"https://docker.m.daocloud.io",
"https://docker.1ms.run",
"https://hub1.nat.tf",
"https://docker.1panel.live",
"https://dockerproxy.1panel.live",
"https://hub.rat.dev",
"https://docker.amingg.com"
'
    DAEMON_JSON_CONTENT="{\n  \"registry-mirrors\": [\n    $(echo "$MIRROR_LIST" | sed '$d')\n  ]\n}"

    tee /etc/docker/daemon.json <<< "$DAEMON_JSON_CONTENT" > /dev/null
    fn_print_info "配置文件 /etc/docker/daemon.json 已更新。"
    systemctl restart docker || fn_print_error "Docker 服务重启失败！请手动运行 'systemctl restart docker' 进行排查。"
    fn_print_success "Docker 服务已重启，加速配置生效！"
fi

# --- 阶段二：交互式配置 ---

fn_print_step "[ 2 / 5 ] 选择运行模式"

echo "请选择您希望的运行模式："
echo "  [1] 单用户模式 (简单，适合个人使用，通过浏览器弹窗认证)"
echo "  [2] 多用户模式 (推荐，功能完整，拥有独立的登录页面)"
read -p "请输入选项数字 [默认为 2]: " run_mode
run_mode=${run_mode:-2}

if [[ "$run_mode" == "1" ]]; then
    fn_print_info "您选择了单用户模式。"
    read -p "请输入您的自定义用户名: " single_user
    read -sp "请输入您的自定义密码: " single_pass
    echo
    if [ -z "$single_user" ] || [ -z "$single_pass" ]; then
        fn_print_error "用户名和密码不能为空！"
    fi
elif [[ "$run_mode" != "2" ]]; then
    fn_print_error "无效输入，脚本已终止。"
fi

# --- 阶段三：自动化部署 ---

fn_print_step "[ 3 / 5 ] 创建项目文件"

if [ -d "$INSTALL_DIR" ]; then
    fn_print_error "目录 '$INSTALL_DIR' 已存在。为防止数据丢失，请先手动备份并删除该目录后再运行本脚本。"
fi

mkdir -p "$INSTALL_DIR"
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
fn_print_success "项目目录和 docker-compose.yml 文件创建成功！"

fn_print_step "[ 4 / 5 ] 初始化与配置"

fn_print_info "正在拉取 SillyTavern 镜像，可能需要几分钟，请耐心等待..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" pull || fn_print_error "拉取 Docker 镜像失败！请检查网络连接或 Docker 加速镜像配置。"

fn_print_info "正在进行首次启动以生成初始配置文件..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null

timeout=60
while [ ! -f "$CONFIG_FILE" ]; do
    if [ $timeout -eq 0 ]; then
        fn_print_error "等待配置文件生成超时！请运行 '$DOCKER_COMPOSE_CMD -f \"$COMPOSE_FILE\" logs' 查看容器日志以排查问题。"
    fi
    sleep 1
    ((timeout--))
done

$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" down > /dev/null
fn_print_success "初始配置文件生成成功！"

fn_print_info "正在修正文件权限..."
chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
fn_print_success "文件权限已设置为 '$TARGET_USER' 用户。"

fn_print_info "正在根据您的选择修改配置文件..."

# yq 修改函数，支持添加注释
fn_yq_mod() {
    local key="$1"
    local value="$2"
    local comment="$3"
    local value_type
    
    if [[ "$value" == "true" || "$value" == "false" || "$value" =~ ^[0-9]+$ ]]; then
        value_type="literal"
    else
        value_type="string"
    fi

    if [ "$value_type" == "string" ]; then
        yq e "(${key} = \"${value}\") | ${key} line_comment = \"${comment}\"" -i "$CONFIG_FILE"
    else
        yq e "(${key} = ${value}) | ${key} line_comment = \"${comment}\"" -i "$CONFIG_FILE"
    fi
}

# 通用基础配置
fn_yq_mod '.listen' 'true' '* 允许外部访问'
fn_yq_mod '.whitelistMode' 'false' '* 关闭IP白名单模式'
fn_yq_mod '.sessionTimeout' '86400' '* 24小时退出登录'
fn_yq_mod '.numberOfBackups' '5' '* 单文件保留的备份数量'
fn_yq_mod '.maxTotalBackups' '30' '* 总聊天文件数量上限'
fn_yq_mod '.lazyLoadCharacters' 'true' '* 懒加载、点击角色卡才加载'
fn_yq_mod '.memoryCacheCapacity' "'128mb'" '* 角色卡内存缓存 (根据2G内存推荐)'

if [[ "$run_mode" == "1" ]]; then
    # 单用户模式配置
    fn_yq_mod '.basicAuthMode' 'true' '* 启用基础认证 (单用户模式下保持开启)'
    fn_yq_mod '.basicAuthUser.username' "$single_user" '* 请修改为自己的用户名'
    fn_yq_mod '.basicAuthUser.password' "$single_pass" '* 请修改为自己的密码'
    fn_print_success "单用户模式配置写入完成！"
else
    # 多用户模式第一阶段配置
    fn_yq_mod '.basicAuthMode' 'true' '# 临时开启，用于初始化管理员密码'
    fn_yq_mod '.enableUserAccounts' 'true' '* 多用户模式'
    
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
    
    # 显示引导文字并暂停
    SERVER_IP=$(fn_get_public_ip)
    echo -e "\n"
    cat <<EOF
---【 重要：请按以下步骤设置管理员 】---

SillyTavern 已临时启动，请完成管理员的初始设置：

1. 【开放端口】
   请确保您已在服务器后台（如阿里云/腾讯云安全组）开放了 8000 端口。

2. 【访问并登录】
   请打开浏览器，访问: http://${SERVER_IP}:8000
   使用以下默认凭据登录：
     ▶ 账号: user
     ▶ 密码: password

3. 【设置管理员】
   登录后，请立即在右上角的【管理员面板】中操作：
   A. 设置密码：为默认账户 \`default-user\` 设置一个强大的新密码。
   B. 创建新账户 (推荐)：
      ① 点击“创建用户”。
      ② 自定义您的日常使用账号和密码（建议账号用纯英文）。
      ③ 创建后，点击新账户旁的【↑】箭头，将其提升为 Admin (管理员)。

4. 【需要帮助？】
   如对以上步骤不熟，可访问图文教程： https://stdocs.723123.xyz

>>> 完成以上所有步骤后，请回到本窗口，然后按下【回车键】继续 <<<
EOF
    read -p ""

    # 多用户模式第二阶段配置
    fn_yq_mod '.basicAuthMode' 'false' '# 初始化完成，关闭基础认证'
    fn_yq_mod '.enableDiscreetLogin' 'true' '* 隐藏登录用户列表'
    fn_print_success "多用户模式配置写入完成！"
fi

# --- 阶段五：最终启动 ---

fn_print_step "[ 5 / 5 ] 完成部署"
fn_print_info "正在应用最终配置并启动服务..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null

SERVER_IP=$(fn_get_public_ip)
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
echo -e "║                      部署成功！尽情享受吧！                      ║"
echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n  ${CYAN}访问地址:${NC} http://${SERVER_IP}:8000"
echo -e "  ${CYAN}管理方式:${NC} 请登录 1Panel 服务器面板，在“容器”菜单中管理您的 SillyTavern。"
echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
echo -e "\n"
