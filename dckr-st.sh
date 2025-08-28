#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 12.5 (终极功能验证版)
# 作者: Qingjue (由 AI 助手基于 v12.4 优化)
# 更新日志 (v12.5):
# - [核心修复] 引入 yq 功能性探测，彻底解决因版本欺骗或损坏导致的执行失败问题。
# - [核心修复] 修正版本号提取逻辑，确保 tar 等工具的版本能被正确显示。
# - [核心优化] 重构诊断报告的着色和对齐逻辑，实现完美的终端显示效果。

# --- 初始化与环境设置 ---
set -e

# --- 色彩定义 ---
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 全局变量 (存储纯文本状态) ---
BC_VER="-" BC_STATUS="-"
CURL_VER="-" CURL_STATUS="-"
TAR_VER="-" TAR_STATUS="-"
DOCKER_VER="-" DOCKER_STATUS="-"
COMPOSE_VER="-" COMPOSE_STATUS="-"
YQ_VER="-" YQ_STATUS="-"
JQ_VER="-" JQ_STATUS="-"
USE_YQ=false

# --- 辅助函数 ---
fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ $1${NC}"; }
fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; exit 1; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_info() { echo -e "  $1"; }

# --- 核心函数 ---

## --- 修改开始 1: 全面重构依赖检查、报告、版本提取 ---
fn_report_dependencies() {
    fn_print_info "--- 环境诊断摘要 ---"
    printf "${BOLD}%-18s %-20s %-15s${NC}\n" "工具" "检测到的版本" "状态"
    printf "${CYAN}%-18s %-20s %-15s${NC}\n" "------------------" "--------------------" "---------------"
    
    # 动态着色打印
    print_status_line() {
        local name="$1" version="$2" status="$3" color="$RED"
        if [[ "$status" == "OK" || "$status" == "Installed" ]]; then color="$GREEN"
        elif [[ "$status" == "Fallback (sed)" ]]; then color="$YELLOW"; fi
        printf "%-18s %-20s ${color}%-15s${NC}\n" "$name" "$version" "$status"
    }

    print_status_line "bc" "$BC_VER" "$BC_STATUS"
    print_status_line "curl" "$CURL_VER" "$CURL_STATUS"
    print_status_line "tar" "$TAR_VER" "$TAR_STATUS"
    print_status_line "Docker" "$DOCKER_VER" "$DOCKER_STATUS"
    print_status_line "Docker Compose" "$COMPOSE_VER" "$COMPOSE_STATUS"
    print_status_line "yq" "$YQ_VER" "$YQ_STATUS"
    print_status_line "jq" "$JQ_VER" "$JQ_STATUS"
    echo ""
}

fn_get_cleaned_version_num() {
    # 修复后的正则表达式，可匹配 X.Y, X.Y.Z 等多种格式
    echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

fn_auto_install_deps() {
    local pkgs_to_check=("bc" "curl" "tar")
    local pkgs_to_install=()
    for pkg in "${pkgs_to_check[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            pkgs_to_install+=("$pkg")
        else
            local ver_var_name="${pkg^^}_VER"
            local status_var_name="${pkg^^}_STATUS"
            declare -g "$ver_var_name"="$(fn_get_cleaned_version_num "$($pkg --version 2>/dev/null)")"
            declare -g "$status_var_name"="OK"
        fi
    done

    if [ ${#pkgs_to_install[@]} -eq 0 ]; then return; fi

    fn_print_warning "检测到必需的软件包缺失: ${pkgs_to_install[*]}，正在尝试自动安装..."
    if ! sudo -v; then fn_print_error "无法获取 sudo 权限，请手动安装: ${pkgs_to_install[*]}"; fi

    local pkg_manager=""
    if command -v apt-get &> /dev/null; then pkg_manager="apt-get"; elif command -v dnf &> /dev/null; then pkg_manager="dnf"; elif command -v yum &> /dev/null; then pkg_manager="yum"; elif command -v pacman &> /dev/null; then pkg_manager="pacman"; else
        fn_print_error "无法识别您的包管理器，请手动安装: ${pkgs_to_install[*]}"
    fi

    if [ "$pkg_manager" == "apt-get" ]; then
        fn_print_info "正在运行 'sudo apt-get update'..."
        sudo apt-get update -y || fn_print_warning "'apt-get update' 失败..."
    fi

    if sudo ${pkg_manager/apt-get/apt-get install -y} ${pkg_manager/dnf/dnf install -y} ${pkg_manager/yum/yum install -y} ${pkg_manager/pacman/pacman -S --noconfirm} "${pkgs_to_install[@]}"; then
        fn_print_success "成功安装缺失的软件包。"
        for pkg in "${pkgs_to_install[@]}"; do
            local ver_var_name="${pkg^^}_VER"
            local status_var_name="${pkg^^}_STATUS"
            declare -g "$ver_var_name"="$(fn_get_cleaned_version_num "$(command -v "$pkg" &>/dev/null && $pkg --version 2>/dev/null)")"
            declare -g "$status_var_name"="Installed"
        done
    else
        fn_print_error "自动安装失败，请手动安装后重试: ${pkgs_to_install[*]}"
    fi
}

fn_download_and_install_yq() {
    # ... (此函数逻辑不变) ...
    local YQ_TARGET_VERSION="4.47.1"
    local arch; case $(uname -m) in x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; *) fn_print_warning "不支持的架构"; return 1 ;; esac
    local yq_binary="yq_linux_${arch}"; local yq_archive="${yq_binary}.tar.gz"; local checksum_file="checksums"; local github_path_base="mikefarah/yq/releases/download/v${YQ_TARGET_VERSION}"
    local mirror_bases=( "https://github.com" "https://gh-proxy.com/https://github.com" "https://gh.llkk.cc/https://github.com" ); local special_mirrors=( "https://git.723123.xyz/gh" )
    fn_print_info "正在为 yq 下载源智能测速 (每个源超时 5 秒)..."
    local speed_results=""; local test_urls=(); for base in "${mirror_bases[@]}"; do test_urls+=("${base}/${github_path_base}/${checksum_file}"); done; for base in "${special_mirrors[@]}"; do test_urls+=("${base}/${github_path_base}/${checksum_file}"); done
    for url in "${test_urls[@]}"; do
        echo -ne "  - 正在测试: ${YELLOW}${url%%/*}${NC}..."; local time_taken=$(curl -o /dev/null -s -w '%{time_total}' --max-time 5 "$url" || echo "9999")
        if [[ $(echo "$time_taken > 0 && $time_taken < 5" | bc) -eq 1 ]]; then printf " ${GREEN}%.3f 秒${NC}\n" "$time_taken"; speed_results+="${time_taken}|${url}\n"; else echo -e " ${RED}超时或失败${NC}"; fi
    done
    local sorted_urls=(); if [ -n "$speed_results" ]; then while IFS= read -r line; do sorted_urls+=("$(echo "$line" | cut -d'|' -f2 | sed "s/${checksum_file}$/${yq_archive}/")"); done <<< "$(echo -e "$speed_results" | sort -n)"; else
        fn_print_warning "所有下载源测速失败！将按默认顺序尝试。"; for base in "${mirror_bases[@]}"; do sorted_urls+=("${base}/${github_path_base}/${yq_archive}"); done; for base in "${special_mirrors[@]}"; do sorted_urls+=("${base}/${github_path_base}/${yq_archive}"); done; fi
    fn_print_info "将按以下顺序尝试下载:"; for url in "${sorted_urls[@]}"; do fn_print_info "  - ${url}"; done
    local tmp_file; tmp_file=$(mktemp); trap 'rm -f "$tmp_file"' EXIT
    for url in "${sorted_urls[@]}"; do
        fn_print_info "正在尝试从: ${url}"; if curl -L --fail -o "$tmp_file" -s "$url"; then
            if file "$tmp_file" | grep -q 'gzip compressed data'; then
                fn_print_info "下载成功，正在解压和安装..."; if sudo tar xz -f "$tmp_file" -O "./${yq_binary}" > /usr/local/bin/yq; then
                    sudo chmod +x /usr/local/bin/yq; if command -v yq &> /dev/null && yq --help 2>/dev/null | grep -q "eval (e)"; then
                        rm -f "$tmp_file"; trap - EXIT; return 0; fi; fi; fi; fi
        fn_print_warning "从该源处理失败，尝试下一个..."; done
    return 1
}

fn_check_dependencies() {
    fn_print_info "--- 依赖环境诊断开始 ---"
    
    fn_auto_install_deps

    if ! command -v docker &> /dev/null; then DOCKER_STATUS="Not Found"; else DOCKER_VER=$(fn_get_cleaned_version_num "$(docker --version)"); DOCKER_STATUS="OK"; fi
    
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        COMPOSE_VER="v$(fn_get_cleaned_version_num "$($DOCKER_COMPOSE_CMD version)")"
        COMPOSE_STATUS="OK (v1)"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        COMPOSE_VER=$(docker compose version | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n 1)
        COMPOSE_STATUS="OK (v2)"
    else
        DOCKER_COMPOSE_CMD=""
        COMPOSE_STATUS="Not Found"
    fi

    local YQ_TARGET_VERSION="4.47.1"; local needs_install=false
    # 终极功能性探测
    if command -v yq &> /dev/null && yq --help 2>/dev/null | grep -q "eval (e)"; then
        YQ_VER="v$(fn_get_cleaned_version_num "$(yq --version)")"
        YQ_STATUS="OK"
        USE_YQ=true
    else
        if command -v yq &> /dev/null; then
             fn_print_warning "检测到 yq 命令，但它不是一个兼容的 v4+ 版本，将进行覆盖安装..."
        else
             fn_print_info "yq 未安装，将开始智能安装流程..."
        fi
        needs_install=true
    fi

    if [ "$needs_install" = true ]; then
        if fn_download_and_install_yq; then
            YQ_VER="v${YQ_TARGET_VERSION}"
            YQ_STATUS="Installed"
            USE_YQ=true
        else
            YQ_VER="-"
            YQ_STATUS="Fallback (sed)"
            USE_YQ=false
        fi
    fi

    if ! command -v jq &> /dev/null; then JQ_STATUS="Not Found"; else JQ_VER=$(jq --version); JQ_STATUS="OK"; fi
    
    fn_report_dependencies
    if [[ "$DOCKER_STATUS" == "Not Found" || "$COMPOSE_STATUS" == "Not Found" ]]; then
        fn_print_error "核心组件 Docker 或 Docker Compose 未安装，请安装后重试。"
    fi
}
## --- 修改结束 1 ---

# ... (其他所有函数保持不变) ...
fn_apply_docker_config() {
    local config_content="$1"
    if [[ -z "$config_content" ]]; then
        fn_print_info "正在清除 Docker 镜像配置..."
        if [ ! -f "/etc/docker/daemon.json" ]; then fn_print_success "无需操作，配置已是默认。"; return; fi
        sudo rm -f /etc/docker/daemon.json
    else
        fn_print_info "正在写入新的 Docker 镜像配置..."
        echo -e "$config_content" | sudo tee /etc/docker/daemon.json > /dev/null
    fi
    fn_print_info "正在重启 Docker 服务以应用配置..."
    if sudo systemctl restart docker; then
        fn_print_success "Docker 服务已重启，新配置生效！"
    else
        fn_print_warning "Docker 服务重启失败！配置可能存在问题。"
        fn_print_info "正在尝试自动回滚到默认配置..."
        sudo rm -f /etc/docker/daemon.json
        if sudo systemctl restart docker; then
            fn_print_success "自动回滚成功！Docker 已恢复并使用官方源。"
        else
            fn_print_error "自动回滚失败！请手动执行 'sudo systemctl status docker.service' 和 'sudo journalctl -xeu docker.service' 进行排查。"
        fi
    fi
}
fn_speed_test_and_configure_mirrors() {
    fn_print_info "正在智能检测 Docker 镜像源可用性 (每个源超时 30 秒)..."
    local mirrors=("docker.io" "https://docker.1ms.run" "https://hub1.nat.tf" "https://docker.1panel.live" "https://dockerproxy.1panel.live" "https://hub.rat.dev")
    docker rmi hello-world > /dev/null 2>&1 || true

    local results=""
    local official_hub_ok=false

    for mirror in "${mirrors[@]}"; do
        local pull_target="hello-world" display_name="$mirror"
        if [[ "$mirror" != "docker.io" ]]; then pull_target="${mirror#https://}/library/hello-world"; else display_name="Official Docker Hub"; fi
        echo -ne "  - 正在测试: ${YELLOW}${display_name}${NC}..."
        local start_time=$(date +%s.%N)
        if timeout 30 docker pull "$pull_target" > /dev/null 2>&1; then
            local end_time=$(date +%s.%N)
            local duration=$(echo "$end_time - $start_time" | bc)
            printf " ${GREEN}%.2f 秒${NC}\n" "$duration"
            results+="${duration}|${mirror}|${display_name}\n"
            if [[ "$mirror" == "docker.io" ]]; then
                official_hub_ok=true
            fi
            docker rmi "$pull_target" > /dev/null 2>&1 || true
        else
            echo -e " ${RED}超时或失败${NC}"
            results+="9999|${mirror}|${display_name}\n"
        fi
    done

    if [ "$official_hub_ok" = true ]; then
        fn_print_success "官方 Docker Hub 可访问。"
        echo -ne "${YELLOW}是否清除本地镜像配置并使用官方源? [Y/n]: ${NC}"
        read -r confirm_clear < /dev/tty
        confirm_clear=${confirm_clear:-y}
        if [[ "$confirm_clear" =~ ^[Yy]$ ]]; then
            fn_apply_docker_config ""
        else
            fn_print_info "用户选择保留当前镜像配置，操作跳过。"
        fi
    else
        fn_print_warning "官方 Docker Hub 连接超时。"
        local sorted_mirrors=$(echo -e "$results" | grep -v '^9999' | grep -v '|docker.io|' | LC_ALL=C sort -n)
        
        if [ -z "$sorted_mirrors" ]; then
            fn_print_error "所有备用镜像均测试失败！请检查您的网络连接。"
        else
            fn_print_info "以下是可用的备用镜像及其速度："
            echo "$sorted_mirrors" | awk -F'|' '{ printf "  - %-30s %.2f 秒\n", $3, $1 }'
            echo -ne "${YELLOW}是否配置最快的可用镜像? [Y/n]: ${NC}"
            read -r confirm_config < /dev/tty
            confirm_config=${confirm_config:-y}

            if [[ "$confirm_config" =~ ^[Yy]$ ]]; then
                local best_mirrors=($(echo "$sorted_mirrors" | head -n 3 | cut -d'|' -f2))
                fn_print_success "将配置最快的 ${#best_mirrors[@]} 个镜像源。"
                local mirrors_json=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//')
                local config_content="{\n  \"registry-mirrors\": [${mirrors_json}]\n}"
                fn_apply_docker_config "$config_content"
            else
                fn_print_info "用户选择不配置镜像，操作跳过。"
            fi
        fi
    fi
}
fn_apply_config_changes() {
    local tool_name
    if [ "$USE_YQ" = true ]; then tool_name="yq"; else tool_name="sed"; fi
    fn_print_info "正在使用 ${BOLD}${tool_name}${NC} 精准修改配置并添加注释..."

    if [ "$USE_YQ" = true ]; then
        yq e -i '(.listen = true) | (.listen | line_comment = "* 允许外部访问")' "$CONFIG_FILE"
        yq e -i '(.whitelistMode = false) | (.whitelistMode | line_comment = "* 关闭IP白名单模式")' "$CONFIG_FILE"
        yq e -i '(.sessionTimeout = 86400) | (.sessionTimeout | line_comment = "* 24小时退出登录")' "$CONFIG_FILE"
        yq e -i '(.backups.common.numberOfBackups = 5) | (.backups.common.numberOfBackups | line_comment = "* 单文件保留的备份数量")' "$CONFIG_FILE"
        yq e -i '(.backups.chat.maxTotalBackups = 30) | (.backups.chat.maxTotalBackups | line_comment = "* 总聊天文件数量上限")' "$CONFIG_FILE"
        yq e -i '(.performance.lazyLoadCharacters = true) | (.performance.lazyLoadCharacters | line_comment = "* 懒加载、点击角色卡才加载")' "$CONFIG_FILE"
        yq e -i ".performance.memoryCacheCapacity = '128mb' | .performance.memoryCacheCapacity | line_comment = \"* 角色卡内存缓存 (根据2G内存推荐)\"" "$CONFIG_FILE"
        if [[ "$run_mode" == "1" ]]; then
            yq e -i '(.basicAuthMode = true) | (.basicAuthMode | line_comment = "* 启用基础认证")' "$CONFIG_FILE"
            yq e -i ".basicAuthUser.username = \"$single_user\"" "$CONFIG_FILE"
            yq e -i ".basicAuthUser.password = \"$single_pass\"" "$CONFIG_FILE"
        elif [[ "$run_mode" == "2" ]]; then
            yq e -i '(.basicAuthMode = true) | (.basicAuthMode | line_comment = "* 临时开启基础认证以设置管理员")' "$CONFIG_FILE"
            yq e -i '(.enableUserAccounts = true) | (.enableUserAccounts | line_comment = "* 启用多用户模式")' "$CONFIG_FILE"
        fi
    else
        sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true # * 允许外部访问/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false # * 关闭IP白名单模式/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)sessionTimeout: .*/\1sessionTimeout: 86400 # * 24小时退出登录/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)numberOfBackups: .*/\1numberOfBackups: 5 # * 单文件保留的备份数量/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)maxTotalBackups: .*/\1maxTotalBackups: 30 # * 总聊天文件数量上限/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)lazyLoadCharacters: .*/\1lazyLoadCharacters: true # * 懒加载、点击角色卡才加载/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)memoryCacheCapacity: .*/\1memoryCacheCapacity: '128mb' # * 角色卡内存缓存 (根据2G内存推荐)/" "$CONFIG_FILE"
        if [[ "$run_mode" == "1" ]]; then
            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # * 启用基础认证/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)username: .*/\1username: \"$single_user\"/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)password: .*/\1password: \"$single_pass\"/" "$CONFIG_FILE"
        elif [[ "$run_mode" == "2" ]]; then
            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # * 临时开启基础认证以设置管理员/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true # * 启用多用户模式/" "$CONFIG_FILE"
        fi
    fi
}
fn_get_public_ip() { local ip; ip=$(curl -s --max-time 5 https://api.ipify.org) || ip=$(curl -s --max-time 5 https://ifconfig.me) || ip=$(hostname -I | awk '{print $1}'); echo "$ip"; }
fn_confirm_and_delete_dir() { local dir_to_delete="$1"; fn_print_warning "目录 '$dir_to_delete' 已存在，其中可能包含您之前的聊天记录和角色卡。"; echo -ne "您确定要删除此目录并继续安装吗？[Y/n]: "; read -r c1 < /dev/tty; c1=${c1:-y}; if [[ ! "$c1" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。"; fi; echo -ne "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 [Y/n]: ${NC}"; read -r c2 < /dev/tty; c2=${c2:-y}; if [[ ! "$c2" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。"; fi; echo -ne "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}"; read -r c3 < /dev/tty; if [[ "$c3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi; fn_print_info "正在删除旧目录: $dir_to_delete..."; rm -rf "$dir_to_delete"; fn_print_success "旧目录已删除。"; }
fn_create_project_structure() { fn_print_info "正在创建项目目录结构..."; mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"; chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"; fn_print_info "正在设置安全的文件权限..."; find "$INSTALL_DIR" -type d -exec chmod 755 {} +; find "$INSTALL_DIR" -type f -exec chmod 644 {} +; fn_print_success "项目目录创建并授权成功！"; }

# ==============================================================================
#   主逻辑开始
# ==============================================================================

clear
echo -e "${CYAN}╔═════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ${BOLD}SillyTavern 助手 v12.5${NC}      ${CYAN}║${NC}"
echo -e "${CYAN}║   by Qingjue | XHS:826702880    ${CYAN}║${NC}"
echo -e "${CYAN}╚═════════════════════════════════╝${NC}"
echo -e "\n本助手将引导您完成 SillyTavern 的自动化安装。"

# --- 阶段一：环境自检与准备 ---
fn_print_step "[ 1 / 5 ] 环境检查与准备"
if [ "$(id -u)" -ne 0 ]; then fn_print_error "本脚本需要以 root 权限运行。请使用 'sudo' 执行。"; fi
TARGET_USER="${SUDO_USER:-root}"; if [ "$TARGET_USER" = "root" ]; then USER_HOME="/root"; fn_print_warning "您正以 root 用户身份直接运行脚本，将安装在 /root 目录下。"; else USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6); if [ -z "$USER_HOME" ]; then fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"; fi; fi
INSTALL_DIR="$USER_HOME/sillytavern"; CONFIG_FILE="$INSTALL_DIR/config.yaml"; COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
fn_check_dependencies
fn_speed_test_and_configure_mirrors

# --- 阶段二：交互式配置 ---
fn_print_step "[ 2 / 5 ] 选择运行模式"
echo "请选择您希望的运行模式："; echo -e "  [1] ${CYAN}单用户模式${NC} (简单，适合个人使用)"; echo -e "  [2] ${CYAN}多用户模式${NC} (推荐，拥有独立的登录页面)"; read -p "请输入选项数字 [默认为 2]: " run_mode < /dev/tty; run_mode=${run_mode:-2}
if [[ "$run_mode" == "1" ]]; then read -p "请输入您的自定义用户名: " single_user < /dev/tty; read -p "请输入您的自定义密码: " single_pass < /dev/tty; if [ -z "$single_user" ] || [ -z "$single_pass" ]; then fn_print_error "用户名和密码不能为空！"; fi; elif [[ "$run_mode" != "2" ]]; then fn_print_error "无效输入，脚本已终止。"; fi

# --- 阶段三：自动化部署 ---
fn_print_step "[ 3 / 5 ] 创建项目文件"
if [ -d "$INSTALL_DIR" ]; then fn_confirm_and_delete_dir "$INSTALL_DIR"; fi
fn_create_project_structure

TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")

cat <<EOF > "$COMPOSE_FILE"
services:
  sillytavern:
    container_name: sillytavern
    hostname: sillytavern
    image: ghcr.io/sillytavern/sillytavern:latest
    user: "${TARGET_UID}:${TARGET_GID}"
    environment:
      - NODE_ENV=production
      - FORCE_COLOR=1
    ports:
      - "8000:8000"
    volumes:
      - "./:/home/node/app/config:z"
      - "./data:/home/node/app/data:z"
      - "./plugins:/home/node/app/plugins:z"
      - "./public/scripts/extensions/third-party:/home/node/app/public/scripts/extensions/third-party:z"
    restart: unless-stopped
EOF
fn_print_success "docker-compose.yml 文件创建成功！"

# --- 阶段四：初始化与配置 ---
fn_print_step "[ 4 / 5 ] 初始化与配置"
fn_print_info "正在拉取 SillyTavern 镜像，可能需要几分钟..."; $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" pull || fn_print_error "拉取 Docker 镜像失败！"
fn_print_info "正在进行首次启动以生成配置文件..."; $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
timeout=60; while [ ! -f "$CONFIG_FILE" ]; do if [ $timeout -eq 0 ]; then $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs; fn_print_error "等待配置文件生成超时！请检查以上日志输出。"; fi; sleep 1; ((timeout--)); done
$DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" down > /dev/null; fn_print_success "最新的 config.yaml 文件已生成！"
fn_apply_config_changes
if [[ "$run_mode" == "1" ]]; then fn_print_success "单用户模式配置写入完成！"; else
    fn_print_info "正在临时启动服务以设置管理员..."; $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null
    SERVER_IP=$(fn_get_public_ip); MULTI_USER_GUIDE=$(cat <<EOF

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
); echo -e "${MULTI_USER_GUIDE}"; read -p "" < /dev/tty
    fn_print_info "正在切换到多用户登录页模式..."
    if [ "$USE_YQ" = true ]; then
        yq e -i '(.basicAuthMode = false) | (.basicAuthMode | line_comment = "* 关闭基础认证，启用登录页")' "$CONFIG_FILE"
        yq e -i '(.enableDiscreetLogin = true) | (.enableDiscreetLogin | line_comment = "* 隐藏登录用户列表")' "$CONFIG_FILE"
    else
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false # * 关闭基础认证，启用登录页/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)enableDiscreetLogin: .*/\1enableDiscreetLogin: true # * 隐藏登录用户列表/" "$CONFIG_FILE"
    fi
    fn_print_success "多用户模式配置写入完成！"
fi

# --- 阶段五：最终启动 ---
fn_print_step "[ 5 / 5 ] 最终启动"
fn_print_info "正在应用最终配置并重启服务..."; $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate > /dev/null
SERVER_IP=$(fn_get_public_ip)
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
echo -e "║                      部署成功！尽情享受吧！                      ║"
echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:8000${NC} (按住 Ctrl 并单击)"
if [[ "$run_mode" == "1" ]]; then echo -e "  ${CYAN}登录账号:${NC} ${YELLOW}${single_user}${NC}"; echo -e "  ${CYAN}登录密码:${NC} ${YELLOW}${single_pass}${NC}"; elif [[ "$run_mode" == "2" ]]; then echo -e "  ${YELLOW}首次登录:${NC} 为确保看到新的登录页，请访问 ${GREEN}http://${SERVER_IP}:8000/login${NC} (按住 Ctrl 并单击)"; fi
echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
echo -e "\n"
