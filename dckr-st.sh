#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 2.5 (最终稳定版)
# 功能: 自动化部署 SillyTavern Docker 版，提供极致的自动化、健壮性和用户体验。

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
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org) || \
    ip=$(curl -s --max-time 5 https://ifconfig.me) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

fn_confirm_and_delete_dir() {
    local dir_to_delete="$1"

    fn_print_warning "目录 '$dir_to_delete' 已存在，其中可能包含您之前的聊天记录和角色卡。"

    echo -ne "您确定要删除此目录并继续安装吗？(${GREEN}y${NC}/${RED}n${NC}): "
    read -r confirm1 < /dev/tty
    if [[ "$confirm1" != "y" ]]; then
        fn_print_error "操作被用户取消。"
    fi

    echo -ne "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 (${GREEN}y${NC}/${RED}n${NC}): ${NC}"
    read -r confirm2 < /dev/tty
    if [[ "$confirm2" != "y" ]]; then
        fn_print_error "操作被用户取消。"
    fi

    echo -ne "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}"
    read -r confirm3 < /dev/tty
    if [[ "$confirm3" != "yes" ]]; then
        fn_print_error "操作被用户取消。"
    fi

    fn_print_info "正在删除旧目录: $dir_to_delete..."
    rm -rf "$dir_to_delete"
    fn_print_success "旧目录已删除。"
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

if ! yq --version 2>/dev/null | grep -q 'mikefarah'; then
    fn_print_info "未检测到正确的 yq 版本，正在为您自动下载安装..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) fn_print_error "不支持的系统架构: $ARCH" ;;
    esac
    
    YQ_VERSION="v4.44.2"
    YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
    
    if ! curl -sL "$YQ_URL" -o /usr/local/bin/yq; then
        fn_print_error "下载 yq 失败。请检查网络连接或 GitHub 访问。"
    fi
    chmod +x /usr/local/bin/yq
    
    if ! yq --version 2>/dev/null | grep -q 'mikefarah'; then
         fn_print_error "yq 安装后仍无法正常运行。"
    fi
    fn_print_success "依赖工具 yq (Go 版本) 安装成功！"
fi
fn_print_success "核心依赖检查通过！"

# 1.3 (可选) Docker 镜像加速
fn_print_warning "接下来的选项仅适用于【中国大陆】服务器，海外服务器请直接按回车跳过！"
read -p "您是否在中国大陆服务器上运行，需要配置 Docker 加速镜像？(y/N): " use_mirror < /dev/tty
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
    
    if ! systemctl restart docker; then
        fn_print_warning "Docker 服务重启失败！可能是因为海外服务器无法访问国内镜像。"
        fn_print_info "正在尝试移除配置文件并再次重启..."
        rm -f /etc/docker/daemon.json
        systemctl restart docker || fn_print_error "移除配置文件后 Docker 仍然启动失败！请手动排查。"
        fn_print_success "已自动移除镜像配置，Docker 服务恢复正常。"
    else
        fn_print_success "Docker 服务已重启，加速配置生效！"
    fi
fi

# --- 阶段二：交互式配置 ---

fn_print_step "[ 2 / 5 ] 选择运行模式"

echo "请选择您希望的运行模式："
echo -e "  [1] ${CYAN}单用户模式${NC} (简单，适合个人使用，通过浏览器弹窗认证)"
echo -e "  [2] ${CYAN}多用户模式${NC} (推荐，功能完整，拥有独立的登录页面)"
read -p "请输入选项数字 [默认为 2]: " run_mode < /dev/tty
run_mode=${run_mode:-2}

if [[ "$run_mode" == "1" ]]; then
    fn_print_info "您选择了单用户模式。"
    read -p "请输入您的自定义用户名: " single_user < /dev/tty
    read -sp "请输入您的自定义密码: " single_pass < /dev/tty
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
    fn_confirm_and_delete_dir "$INSTALL_DIR"
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

# yq 修改函数（带注释）
fn_yq_mod() {
    local key="$1"
    local value="$2"
    local comment="$3"
    
    if [[ "$value" == "true" || "$value" == "false" || "$value" =~ ^[0-9]+$ ]]; then
        yq e "(.${key} = ${value}) | .${key} line_comment = \"${comment}\"" -i "$CONFIG_FILE"
    else
        yq e "(.${key} = \"${value}\") | .${key} line_comment = \"${comment}\"" -i "$CONFIG_FILE"
    fi
}

# yq 修改函数（不带注释）
fn_yq_mod_no_comment() {
    local key="$1"
    local value="$2"
    
    if [[ "$value" == "true" || "$value" == "false" || "$value" =~ ^[0-9]+$ ]]; then
        yq e ".${key} = ${value}" -i "$CONFIG_FILE"
    else
        yq e ".${key} = \"${value}\"" -i "$CONFIG_FILE"
    fi
}

# --- 阶段五：应用配置并最终启动 ---

fn_print_step "[ 5 / 5 ] 应用配置并最终启动"

if [[ "$run_mode" == "1" ]]; then
    # 单用户模式：一次性完成所有配置和注释
    fn_print_info "正在写入单用户模式配置..."
    fn_yq_mod 'listen' 'true' '* 允许外部访问'
    fn_yq_mod 'whitelistMode' 'false' '* 关闭IP白名单模式'
    fn_yq_mod 'basicAuthMode' 'true' '* 启用基础认证 (单用户模式下保持开启)'
    fn_yq_mod 'basicAuthUser.username' "$single_user" 'TODO 请修改为自己的用户名'
    fn_yq_mod 'basicAuthUser.password' "$single_pass" 'TODO 请修改为自己的密码'
    fn_yq_mod 'sessionTimeout' '86400' '* 24小时退出登录'
    fn_yq_mod 'numberOfBackups' '5' '* 单文件保留的备份数量'
    fn_yq_mod 'maxTotalBackups' '30' '* 总聊天文件数量上限'
    fn_yq_mod 'lazyLoadCharacters' 'true' '* 懒加载、点击角色卡才加载'
    fn_yq_mod 'memoryCacheCapacity' "'128mb'" '* 角色卡内存缓存 (根据2G内存推荐)'
    fn_print_success "单用户模式配置写入完成！"
else
    # 多用户模式第一阶段：写入无注释的临时配置
    fn_print_info "正在写入多用户模式临时配置..."
    fn_yq_mod_no_comment 'listen' 'true'
    fn_yq_mod_no_comment 'whitelistMode' 'false'
    fn_yq_mod_no_comment 'basicAuthMode' 'true'
    fn_yq_mod_no_comment 'enableUserAccounts' 'true'
    
    fn_print_info "正在临时启动服务以设置管理员..."
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
    
    SERVER_IP=$(fn_get_public_ip)
    
    # 使用 command substitution 和 cat <<EOF 来安全地创建带变量的多行字符串
    MULTI_USER_GUIDE=$(cat <<EOF

${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}

SillyTavern 已临时启动，请完成管理员的初始设置：

1. ${CYAN}【开放端口】${NC}
   请确保您已在服务器后台（如阿里云/腾讯云安全组）开放了 ${GREEN}8000${NC} 端口。

2. ${CYAN}【访问并登录】${NC}
   请打开浏览器，访问: ${GREEN}http://${SERVER_IP}:8000${NC}
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
   如对以上步骤不熟，可访问图文教程： https://stdocs.723123.xyz

${YELLOW}>>> 完成以上所有步骤后，请回到本窗口，然后按下【回车键】继续 <<<${NC}
EOF
)
    echo -e "${MULTI_USER_GUIDE}"
    read -p "" < /dev/tty

    # 多用户模式第二阶段：一次性写入所有最终配置和注释
    fn_print_info "正在应用最终配置..."
    fn_yq_mod 'listen' 'true' '* 允许外部访问'
    fn_yq_mod 'whitelistMode' 'false' '* 关闭IP白名单模式'
    fn_yq_mod 'basicAuthMode' 'false' 'TODO 基础认证模式 初始化结束改回 false'
    fn_yq_mod 'enableUserAccounts' 'true' '* 多用户模式'
    fn_yq_mod 'enableDiscreetLogin' 'true' '* 隐藏登录用户列表'
    fn_yq_mod 'sessionTimeout' '86400' '* 24小时退出登录'
    fn_yq_mod 'numberOfBackups' '5' '* 单文件保留的备份数量'
    fn_yq_mod 'maxTotalBackups' '30' '* 总聊天文件数量上限'
    fn_yq_mod 'lazyLoadCharacters' 'true' '* 懒加载、点击角色卡才加载'
    fn_yq_mod 'memoryCacheCapacity' "'128mb'" '* 角色卡内存缓存 (根据2G内存推荐)'
    fn_print_success "多用户模式配置写入完成！"
fi

fn_print_info "正在应用最终配置并重启服务..."
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate > /dev/null

SERVER_IP=$(fn_get_public_ip)
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
echo -e "║                      部署成功！尽情享受吧！                      ║"
echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n  ${CYAN}访问地址:${NC} http://${SERVER_IP}:8000"
echo -e "  ${CYAN}管理方式:${NC} 请登录 1Panel 服务器面板，在“容器”菜单中管理您的 SillyTavern。"
echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
echo -e "\n"
