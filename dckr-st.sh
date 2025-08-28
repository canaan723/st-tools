#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 1.2.6 (修复进度条显示)
# 作者: Qingjue

# --- 初始化与环境设置 ---
set -e

# --- 色彩定义 ---
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- 全局变量 ---
BC_VER="-" BC_STATUS="-"
CURL_VER="-" CURL_STATUS="-"
TAR_VER="-" TAR_STATUS="-"
DOCKER_VER="-" DOCKER_STATUS="-"
COMPOSE_VER="-" COMPOSE_STATUS="-"
CONTAINER_NAME="sillytavern"
IMAGE_NAME="ghcr.io/sillytavern/sillytavern:latest"

# --- 辅助函数 ---
fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ $1${NC}"; }
fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; exit 1; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_info() { echo -e "  $1"; }

# --- 核心函数 ---

fn_report_dependencies() {
    fn_print_info "--- 环境诊断摘要 ---"
    printf "${BOLD}%-18s %-20s %-20s${NC}\n" "工具" "检测到的版本" "状态"
    printf "${CYAN}%-18s %-20s %-20s${NC}\n" "------------------" "--------------------" "--------------------"
    print_status_line() {
        local name="$1" version="$2" status="$3" color="$GREEN"
        if [[ "$status" == "Not Found" ]]; then color="$RED"; fi
        printf "%-18s %-20s ${color}%-20s${NC}\n" "$name" "$version" "$status"
    }
    print_status_line "bc" "$BC_VER" "$BC_STATUS"
    print_status_line "curl" "$CURL_VER" "$CURL_STATUS"
    print_status_line "tar" "$TAR_VER" "$TAR_STATUS"
    print_status_line "Docker" "$DOCKER_VER" "$DOCKER_STATUS"
    print_status_line "Docker Compose" "$COMPOSE_VER" "$COMPOSE_STATUS"
    echo ""
}

fn_get_cleaned_version_num() {
    echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

fn_check_dependencies() {
    fn_print_info "--- 依赖环境诊断开始 ---"
    for pkg in "bc" "curl" "tar"; do
        if command -v "$pkg" &> /dev/null; then
            declare -g "${pkg^^}_VER"="$(fn_get_cleaned_version_num "$($pkg --version 2>/dev/null)")"
            declare -g "${pkg^^}_STATUS"="OK"
        else
            declare -g "${pkg^^}_STATUS"="Not Found"
        fi
    done
    if ! command -v docker &> /dev/null; then DOCKER_STATUS="Not Found"; else DOCKER_VER=$(fn_get_cleaned_version_num "$(docker --version)"); DOCKER_STATUS="OK"; fi
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"; COMPOSE_VER="v$(fn_get_cleaned_version_num "$($DOCKER_COMPOSE_CMD version)")"; COMPOSE_STATUS="OK (v1)"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"; COMPOSE_VER=$(docker compose version | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n 1); COMPOSE_STATUS="OK (v2)"
    else
        DOCKER_COMPOSE_CMD=""; COMPOSE_STATUS="Not Found"
    fi
    fn_report_dependencies
    if [[ "$BC_STATUS" == "Not Found" || "$CURL_STATUS" == "Not Found" || "$TAR_STATUS" == "Not Found" || "$DOCKER_STATUS" == "Not Found" || "$COMPOSE_STATUS" == "Not Found" ]]; then
        fn_print_error "检测到核心组件缺失，请确保 bc, curl, tar, docker, docker-compose 均已安装。"
    fi
}

fn_apply_docker_config() {
    local config_content="$1"
    if [[ -z "$config_content" ]]; then
        fn_print_info "正在清除 Docker 镜像配置..."; if [ ! -f "/etc/docker/daemon.json" ]; then fn_print_success "无需操作，配置已是默认。"; return; fi
        sudo rm -f /etc/docker/daemon.json
    else
        fn_print_info "正在写入新的 Docker 镜像配置..."; echo -e "$config_content" | sudo tee /etc/docker/daemon.json > /dev/null
    fi
    fn_print_info "正在重启 Docker 服务以应用配置..."; if sudo systemctl restart docker > /dev/null 2>&1; then
        fn_print_success "Docker 服务已重启，新配置生效！"
    else
        fn_print_warning "Docker 服务重启失败！配置可能存在问题。"; fn_print_info "正在尝试自动回滚到默认配置..."; sudo rm -f /etc/docker/daemon.json
        if sudo systemctl restart docker > /dev/null 2>&1; then fn_print_success "自动回滚成功！Docker 已恢复并使用官方源。"; else
            fn_print_error "自动回滚失败！请手动执行 'sudo systemctl status docker.service' 和 'sudo journalctl -xeu docker.service' 进行排查。"
        fi
    fi
}
fn_speed_test_and_configure_mirrors() {
    fn_print_info "正在智能检测 Docker 镜像源可用性..."
    local mirrors=(
        "docker.io" "https://docker.1ms.run" "https://hub1.nat.tf" "https://docker.1panel.live"
        "https://dockerproxy.1panel.live" "https://hub.rat.dev" "https://docker.m.ixdev.cn"
        "https://hub2.nat.tf" "https://docker.1panel.dev" "https://docker.amingg.com"
        "https://docker.xuanyuan.me" "https://dytt.online" "https://lispy.org"
        "https://docker.xiaogenban1993.com" "https://docker-0.unsee.tech" "https://666860.xyz"
    )
    docker rmi hello-world > /dev/null 2>&1 || true
    local results=""; local official_hub_ok=false
    for mirror in "${mirrors[@]}"; do
        local pull_target="hello-world" display_name="$mirror"
        local timeout_duration
        if [[ "$mirror" == "docker.io" ]]; then
            timeout_duration=15
            display_name="Official Docker Hub"
        else
            timeout_duration=10
            pull_target="${mirror#https://}/library/hello-world"
        fi
        
        echo -ne "  - 正在测试: ${YELLOW}${display_name}${NC}..."; local start_time=$(date +%s.%N)
        if timeout "$timeout_duration" docker pull "$pull_target" > /dev/null 2>&1; then
            local end_time=$(date +%s.%N); local duration=$(echo "$end_time - $start_time" | bc)
            printf " ${GREEN}%.2f 秒${NC}\n" "$duration"; results+="${duration}|${mirror}|${display_name}\n"
            if [[ "$mirror" == "docker.io" ]]; then
                official_hub_ok=true
                docker rmi "$pull_target" > /dev/null 2>&1 || true
                break
            fi
            docker rmi "$pull_target" > /dev/null 2>&1 || true
        else
            echo -e " ${RED}超时或失败${NC}"; results+="9999|${mirror}|${display_name}\n"
        fi
    done
    if [ "$official_hub_ok" = true ]; then
        if ! grep -q "registry-mirrors" /etc/docker/daemon.json 2>/dev/null; then
            fn_print_success "官方 Docker Hub 可访问，且您未配置任何镜像，无需操作。"
        else
            fn_print_success "官方 Docker Hub 可访问。"; echo -ne "${YELLOW}是否清除本地镜像配置并使用官方源? [Y/n]: ${NC}"
            read -r confirm_clear < /dev/tty; confirm_clear=${confirm_clear:-y}
            if [[ "$confirm_clear" =~ ^[Yy]$ ]]; then fn_apply_docker_config ""; else fn_print_info "用户选择保留当前镜像配置，操作跳过。"; fi
        fi
    else
        fn_print_warning "官方 Docker Hub 连接超时。"; local sorted_mirrors=$(echo -e "$results" | grep -v '^9999' | grep -v '|docker.io|' | LC_ALL=C sort -n)
        if [ -z "$sorted_mirrors" ]; then fn_print_error "所有备用镜像均测试失败！请检查您的网络连接。"; else
            fn_print_info "以下是可用的备用镜像及其速度："; echo "$sorted_mirrors" | grep . | awk -F'|' '{ printf "  - %-30s %.2f 秒\n", $3, $1 }'
            echo -ne "${YELLOW}是否配置最快的可用镜像? [Y/n]: ${NC}"; read -r confirm_config < /dev/tty; confirm_config=${confirm_config:-y}
            if [[ "$confirm_config" =~ ^[Yy]$ ]]; then
                local best_mirrors=($(echo "$sorted_mirrors" | head -n 3 | cut -d'|' -f2))
                fn_print_success "将配置最快的 ${#best_mirrors[@]} 个镜像源。"; local mirrors_json=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//')
                local config_content="{\n  \"registry-mirrors\": [${mirrors_json}]\n}"; fn_apply_docker_config "$config_content"
            else
                fn_print_info "用户选择不配置镜像，操作跳过。"; fi
        fi
    fi
}

fn_apply_config_changes() {
    fn_print_info "正在使用 sed 精准修改配置..."
    sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true # 允许外部访问/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false # 关闭IP白名单模式/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)sessionTimeout: .*/\1sessionTimeout: 86400 # 24小时退出登录/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)numberOfBackups: .*/\1numberOfBackups: 5 # 单文件保留的备份数量/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)maxTotalBackups: .*/\1maxTotalBackups: 30 # 总聊天文件数量上限/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)lazyLoadCharacters: .*/\1lazyLoadCharacters: true # 懒加载、点击角色卡才加载/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)memoryCacheCapacity: .*/\1memoryCacheCapacity: '128mb' # 角色卡内存缓存/" "$CONFIG_FILE"
    if [[ "$run_mode" == "1" ]]; then
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # 启用基础认证/" "$CONFIG_FILE"
        sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)username:/{s/^([[:space:]]*)username: .*/\1username: \"$single_user\"/}" "$CONFIG_FILE"
        sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)password:/{s/^([[:space:]]*)password: .*/\1password: \"$single_pass\"/}" "$CONFIG_FILE"
    elif [[ "$run_mode" == "2" ]]; then
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # 临时开启基础认证以设置管理员/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true # 启用多用户模式/" "$CONFIG_FILE"
    fi
}

fn_get_public_ip() { local ip; ip=$(curl -s --max-time 5 https://api.ipify.org) || ip=$(curl -s --max-time 5 https://ifconfig.me) || ip=$(hostname -I | awk '{print $1}'); echo "$ip"; }
fn_confirm_and_delete_dir() {
    local dir_to_delete="$1"; local container_name="$2"
    fn_print_warning "目录 '$dir_to_delete' 已存在，其中可能包含您之前的聊天记录和角色卡。"
    echo -ne "您确定要【彻底清理】并继续安装吗？此操作会停止并删除旧容器。[Y/n]: "; read -r c1 < /dev/tty; c1=${c1:-y}
    if [[ ! "$c1" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。"; fi
    echo -ne "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 [Y/n]: ${NC}"; read -r c2 < /dev/tty; c2=${c2:-y}
    if [[ ! "$c2" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。"; fi
    echo -ne "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}"; read -r c3 < /dev/tty
    if [[ "$c3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi
    fn_print_info "正在停止可能正在运行的旧容器: $container_name..."; docker stop "$container_name" >/dev/null 2>&1 || true; fn_print_success "旧容器已停止。"
    fn_print_info "正在移除旧容器: $container_name..."; docker rm "$container_name" >/dev/null 2>&1 || true; fn_print_success "旧容器已移除。"
    fn_print_info "正在删除旧目录: $dir_to_delete..."; sudo rm -rf "$dir_to_delete"; fn_print_success "旧目录已彻底清理。"
}

fn_create_project_structure() {
    fn_print_info "正在创建项目目录结构..."
    mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
    fn_print_info "正在设置文件所有权..."; chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
    fn_print_success "项目目录创建并授权成功！"
}

# ==================== MODIFICATION START ====================
# 进度条函数 (v2, 使用 awk 修复显示问题)
fn_pull_with_progress_bar() {
    local compose_file="$1"
    local docker_compose_cmd="$2"

    fn_print_info "正在拉取 SillyTavern 镜像，请耐心等待..."
    
    # 使用 stdbuf 确保输出是行缓冲的
    # grep 筛选出包含进度信息的行
    # awk 负责格式化输出，实现单行动态刷新
    stdbuf -oL -eL $docker_compose_cmd
