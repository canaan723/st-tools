#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 8.0 (智能优化版)
# 作者: Qingjue (由 AI 助手基于 v7.0 优化)
# 更新日志 (v8.0):
# - [智能] 新增 Docker 镜像测速功能，自动选择并配置最快的镜像源。
# - [智能] 测速后若官方源最快，则自动清理镜像配置，无需用户选择。
# - [优化] 修改 YAML 配置时，使用 yq 的 line_comment 功能来添加注释，保持格式。
# - [结构] 进一步封装函数，将 YAML 修改和镜像测速逻辑模块化。

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

    if command -v jq &> /dev/null; then USE_JQ=true; fi
    fn_print_success "核心依赖检查通过！"
}

fn_update_yaml() {
    local key_path="$1"
    local value="$2"
    local comment="$3"
    local is_string="${4:-false}" # 第四个参数判断值是否为字符串

    local value_formatted
    if [[ "$is_string" == true ]]; then
        value_formatted="\"$value\""
    else
        value_formatted="$value"
    fi

    if [ "$USE_YQ" = true ]; then
        yq e -i "(${key_path} = ${value_formatted}) | (${key_path} | line_comment = \"${comment}\")" "$CONFIG_FILE"
    else
        # sed 方案无法处理嵌套key，这里只做简单兼容
        local main_key=$(echo "$key_path" | sed 's/\..*//')
        sed -i -E "s/^([[:space:]]*)(${main_key}): .*/\1\2: ${value} # ${comment}/" "$CONFIG_FILE"
    fi
}

fn_speed_test_and_configure_mirrors() {
    fn_print_info "正在智能检测并配置最佳 Docker 镜像..."
    
    local mirrors=(
        "docker.io" # 代表官方源
        "https://docker.1ms.run"
        "https://hub1.nat.tf"
        "https://docker.1panel.live"
        "https://dockerproxy.1panel.live"
        "https://hub.rat.dev"
    )
    
    local results=""
    # 清理旧的 hello-world 镜像，确保测速准确
    docker rmi hello-world > /dev/null 2>&1 || true

    for mirror in "${mirrors[@]}"; do
        local pull_target="hello-world"
        local display_name="$mirror"
        if [[ "$mirror" != "docker.io" ]]; then
            pull_target="${mirror#https://}/library/hello-world"
        else
            display_name="Official Docker Hub"
        fi

        echo -ne "  - 正在测试: ${YELLOW}${display_name}${NC}..."
        
        # 使用 timeout 防止某个源卡死
        local start_time=$(date +%s.%N)
        if timeout 30 docker pull "$pull_target" > /dev/null 2>&1; then
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc)
            printf " ${GREEN}%.2f 秒${NC}\n" "$duration"
            results+="${duration}|${mirror}\n"
            # 及时清理，为下一个测试准备
            docker rmi "$pull_target" > /dev/null 2>&1 || true
        else
            echo -e " ${RED}超时或失败${NC}"
            results+="9999|${mirror}\n"
        fi
    done

    # 排序并选出最快的
    local sorted_mirrors=$(echo -e "$results" | sort -n)
    local fastest_mirror=$(echo -e "$sorted_mirrors" | head -n 1 | cut -d'|' -f2)

    fn_print_info "测速完成，结果排行如下："
    echo -e "$sorted_mirrors" | awk -F'|' '{
        if ($1 < 9999) {
            printf "  - %-30s %.2f 秒\n", $2, $1
        } else {
            printf "  - %-30s 超时\n", $2
        }
    }'

    if [[ "$fastest_mirror" == "docker.io" ]]; then
        fn_print_success "官方源速度最快，将清除任何加速镜像配置。"
        if [ -f "/etc/docker/daemon.json" ]; then
            rm -f /etc/docker/daemon.json
            systemctl restart docker || fn_print_warning "Docker 重启失败，可能无需操作。"
        fi
    else
        local best_mirrors=($(echo -e "$sorted_mirrors" | grep -v '9999' | head -n 3 | cut -d'|' -f2))
        fn_print_success "将配置最快的 ${#best_mirrors[@]} 个镜像源。"
        
        local mirrors_json=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//')
        
        tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "registry-mirrors": [${mirrors_json}]
}
EOF
        fn_print_info "配置文件 /etc/docker/daemon.json 已更新。"
        systemctl restart docker || fn_print_error "Docker 服务重启失败！请手动排查。"
        fn_print_success "Docker 服务已重启，加速配置生效！"
    fi
}

# ... (其他函数 fn_get_public_ip, fn_confirm_and_delete_dir 等保持不变) ...
fn_get_public_ip() { local ip; ip=$(curl -s --max-time 5 https://api.ipify.org) || ip=$(curl -s --max-time 5 https://ifconfig.me) || ip=$(hostname -I | awk '{print $1}'); echo "$ip"; }
fn_confirm_and_delete_dir() { local dir_to_delete="$1"; fn_print_warning "目录 '$dir_to_delete' 已存在，其中可能包含您之前的聊天记录和角色卡。"; echo -ne "您确定要删除此目录并继续安装吗？(${GREEN}y${NC}/${RED}n${NC}): "; read -r c1 < /dev/tty; if [[ "$c1" != "y" ]]; then fn_print_error "操作被用户取消。"; fi; echo -ne "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 (${GREEN}y${NC}/${RED}n${NC}): ${NC}"; read -r c2 < /dev/tty; if [[ "$c2" != "y" ]]; then fn_print_error "操作被用户取消。"; fi; echo -ne "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}"; read -r c3 < /dev/tty; if [[ "$c3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi; fn_print_info "正在删除旧目录: $dir_to_delete..."; rm -rf "$dir_to_delete"; fn_print_success "旧目录已删除。"; }
fn_create_project_structure() { fn_print_info "正在创建项目目录结构..."; mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"; chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"; fn_print_info "正在设置安全的文件权限..."; find "$INSTALL_DIR" -type d -exec chmod 755 {} +; find "$INSTALL_DIR" -type f -exec chmod 644 {} +; fn_print_success "项目目录创建并授权成功！"; }

fn_apply_config_changes() {
    fn_print_info "正在使用 ${BOLD}${USE_YQ:+yq}${USE_YQ:-sed}${NC} 精准修改配置并添加注释..."
    
    fn_update_yaml '.listen' 'true' '* 允许外部访问'
    fn_update_yaml '.whitelistMode' 'false' '* 关闭IP白名单模式'
    fn_update_yaml '.sessionTimeout' '86400' '* 24小时退出登录'
    fn_update_yaml '.backups.common.numberOfBackups' '5' '* 单文件保留的备份数量'
    fn_update_yaml '.backups.chat.maxTotalBackups' '30' '* 总聊天文件数量上限'
    fn_update_yaml '.performance.lazyLoadCharacters' 'true' '* 懒加载、点击角色卡才加载'
    fn_update_yaml '.performance.memoryCacheCapacity' "'128mb'" '* 角色卡内存缓存 (根据2G内存推荐)' true

    if [[ "$run_mode" == "1" ]]; then
        fn_update_yaml '.basicAuthMode' 'true' '* 启用基础认证'
        fn_update_yaml '.basicAuthUser.username' "$single_user" '' true
        fn_update_yaml '.basicAuthUser.password' "$single_pass" '' true
    elif [[ "$run_mode" == "2" ]]; then
        fn_update_yaml '.basicAuthMode' 'true' '* 临时开启基础认证以设置管理员'
        fn_update_yaml '.enableUserAccounts' 'true' '* 启用多用户模式'
    fi
}

# ==============================================================================
#   主逻辑开始
# ==============================================================================

clear
echo -e "${CYAN}╔═════════════════════════════════╗${NC}"
echo -e "${CYAN}║      ${BOLD}SillyTavern 助手 v8.0${NC}      ${CYAN}║${NC}"
echo -e "${CYAN}║   by Qingjue | XHS:826702880    ${CYAN}║${NC}"
echo -e "${CYAN}╚═════════════════════════════════╝${NC}"
echo -e "\n本助手将引导您完成 SillyTavern 的自动化安装。"

# --- 阶段一：环境自检与准备 ---
fn_print_step "[ 1 / 5 ] 环境检查与准备"
if [ "$(id -u)" -ne 0 ]; then fn_print_error "本脚本需要以 root 权限运行。请使用 'sudo' 执行。"; fi
TARGET_USER="${SUDO_USER:-root}"
if [ "$TARGET_USER" = "root" ]; then USER_HOME="/root"; fn_print_warning "您正以 root 用户身份直接运行脚本，将安装在 /root 目录下。"; else USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6); if [ -z "$USER_HOME" ]; then fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"; fi; fi
INSTALL_DIR="$USER_HOME/sillytavern"
CONFIG_FILE="$INSTALL_DIR/config.yaml"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
fn_check_dependencies
fn_speed_test_and_configure_mirrors

# --- 阶段二：交互式配置 ---
fn_print_step "[ 2 / 5 ] 选择运行模式"
echo "请选择您希望的运行模式："
echo -e "  [1] ${CYAN}单用户模式${NC} (简单，适合个人使用)"
echo -e "  [2] ${CYAN}多用户模式${NC} (推荐，拥有独立的登录页面)"
read -p "请输入选项数字 [默认为 2]: " run_mode < /dev/tty
run_mode=${run_mode:-2}
if [[ "$run_mode" == "1" ]]; then read -p "请输入您的自定义用户名: " single_user < /dev/tty; read -p "请输入您的自定义密码: " single_pass < /dev/tty; if [ -z "$single_user" ] || [ -z "$single_pass" ]; then fn_print_error "用户名和密码不能为空！"; fi; elif [[ "$run_mode" != "2" ]]; then fn_print_error "无效输入，脚本已终止。"; fi

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
while [ ! -f "$CONFIG_FILE" ]; do if [ $timeout -eq 0 ]; then fn_print_error "等待配置文件生成超时！请运行 '$DOCKER_COMPOSE_CMD -f \"$COMPOSE_FILE\" logs' 查看日志。"; fi; sleep 1; ((timeout--)); done
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
    fn_update_yaml '.basicAuthMode' 'false' '* 关闭基础认证，启用登录页'
    fn_update_yaml '.enableDiscreetLogin' 'true' '* 隐藏登录用户列表'
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
if [[ "$run_mode" == "1" ]]; then echo -e "  ${CYAN}登录账号:${NC} ${YELLOW}${single_user}${NC}"; echo -e "  ${CYAN}登录密码:${NC} ${YELLOW}${single_pass}${NC}"; elif [[ "$run_mode" == "2" ]]; then echo -e "  ${YELLOW}首次登录:${NC} 为确保看到新的登录页，请访问 ${GREEN}http://${SERVER_IP}:8000/login${NC} (按住 Ctrl 并单击)"; fi
echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
echo -e "\n"
