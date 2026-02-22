#!/usr/bin/env bash

# 咕咕助手
# 作者: 清绝 | 网址: blog.qjyg.de
#
# Copyright (c) 2025 清绝 (QingJue) <blog.qjyg.de>
# This script is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
# To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
#
# 郑重声明：
# 本脚本为免费开源项目，仅供个人学习和非商业用途使用。
# 未经作者授权，严禁将本脚本或其修改版本用于任何形式的商业盈利行为（包括但不限于倒卖、付费部署服务等）。
# 任何违反本协议的行为都将受到法律追究。

readonly SCRIPT_VERSION="v5.126test"
GUGU_MODE="test"

if [ "$GUGU_MODE" = "prod" ]; then
    readonly GUGU_COMMAND="gugu"
    readonly GUGU_URL="https://gugu.qjyg.de/vps"
else
    readonly GUGU_COMMAND="gugutest"
    readonly GUGU_URL="https://gugu.qjyg.de/vpstest"
fi

trap 'exit 0' INT

if [ -z "$BASH_VERSION" ]; then
    echo "错误: 此脚本需要使用 bash 解释器运行。" >&2
    echo "请尝试使用: bash <(curl -sL $GUGU_URL)" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[33m[提示] 正在请求 Root 权限以继续...\033[0m"
    
    if command -v sudo >/dev/null 2>&1; then
        if [[ -f "$0" && "$0" != "/dev/fd/"* && "$0" != "bash" && "$0" != "sh" ]]; then
            exec sudo bash "$0" "$@"
        else
            exec curl -sL "$GUGU_URL" | sudo bash -s -- "$@"
        fi
    elif command -v su >/dev/null 2>&1; then
        echo -e "\033[33m[提示] 未检测到 sudo，尝试通过 su 提权，请根据提示输入 Root 密码...\033[0m"
        if [[ -f "$0" && "$0" != "/dev/fd/"* && "$0" != "bash" && "$0" != "sh" ]]; then
            exec su -c "bash $0 $*"
        else
            tmp_script="/tmp/gugu_$(date +%s).sh"
            if curl -sL "$GUGU_URL" -o "$tmp_script"; then
                chmod +x "$tmp_script"
                su -c "bash $tmp_script $*; rm -f $tmp_script"
                exit 0
            else
                echo -e "\033[31m[错误] 提权失败：无法下载临时脚本文件以供 su 运行。\033[0m"
                exit 1
            fi
        fi
    else
        echo -e "\033[31m[错误] 系统缺失 sudo 和 su，无法提权，请手动以 root 用户运行。\033[0m"
        exit 1
    fi
fi
# --- -------------------------- ---

CUSTOM_PROXY_IMAGE=""
USER_HOME=""
readonly AIS2API_OLD_IMAGE_REPO="ellinalopez/cloud-studio"
readonly AIS2API_OLD_IMAGE="ellinalopez/cloud-studio:latest"
readonly AIS2API_NEW_IMAGE_REPO="ghcr.io/ibuhub/aistudio-to-api"
readonly AIS2API_NEW_IMAGE="ghcr.io/ibuhub/aistudio-to-api:latest"

fn_init_user_home() {
    local target_user
    target_user="${SUDO_USER:-$(logname 2>/dev/null || who am i 2>/dev/null | awk '{print $1}')}"
    target_user="${target_user:-root}"

    if [ "$target_user" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME=$(getent passwd "$target_user" | cut -d: -f6)
        if [ -z "$USER_HOME" ]; then
            USER_HOME="/home/$target_user"
        fi
    fi
}

fn_ensure_valid_cwd() {
    if ! pwd -P >/dev/null 2>&1; then
        log_warn "检测到当前工作目录不可用，已自动切换到用户主目录。"
        cd "$USER_HOME" 2>/dev/null || cd /root 2>/dev/null || cd / || return 1
    fi
    return 0
}

fn_ssh_rollback() {
    local failed_port=$1
    echo -e "\033[33m[警告] 检测到新SSH端口连接失败，正在执行回滚操作...\033[0m"
    
    local restored=false
    if [ -f /etc/ssh/sshd_config.bak ]; then
        cp -f /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        restored=true
    fi

    if [ -f /etc/ssh/sshd_config.d/99-gugu-ssh.conf.bak ]; then
        cp -f /etc/ssh/sshd_config.d/99-gugu-ssh.conf.bak /etc/ssh/sshd_config.d/99-gugu-ssh.conf
        restored=true
    elif [ -f /etc/ssh/sshd_config.d/99-gugu-ssh.conf ]; then
        rm -f /etc/ssh/sshd_config.d/99-gugu-ssh.conf
        restored=true
    fi

    if [ "$restored" = true ]; then
        systemctl restart sshd
        echo -e "\033[32m[成功] SSH 配置文件已恢复到修改前状态。\033[0m"
    else
        log_warn "未找到有效的备份文件，无法自动恢复配置。"
    fi

    if [ -n "$failed_port" ] && ufw status | grep -q "Status: active"; then
        log_info "正在从 UFW 中移除失败的端口规则 (${failed_port})..."
        ufw delete allow "$failed_port/tcp" 2>/dev/null || true
        ufw --force reload
    fi

    echo -e "\033[34m[提示] SSH 端口修改已回滚。请检查防火墙/NAT映射设置后重试。\033[0m"
}

# 获取当前 SSH 端口
fn_get_ssh_port() {
    local ports
    # 优先使用 sshd -T 获取实际生效的配置（支持 Include 目录和多端口）
    # 使用 paste 将多行端口合并为逗号分隔，如 "22,2222"
    ports=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | sort -un | paste -sd "," -)
    
    # 如果 sshd -T 失败，回退到主配置文件搜索
    if [ -z "$ports" ]; then
        ports=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | sort -un | paste -sd "," -)
    fi
    
    # 最终默认值为 22
    echo "${ports:-22}"
}

# 获取当前连接 IP (多重回退机制确保识别)
fn_get_current_ip() {
    local current_ip
    # 1. 尝试从 SSH_CLIENT 变量获取
    current_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    
    # 2. 尝试从 SSH_CONNECTION 变量获取
    if [ -z "$current_ip" ]; then
        current_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi
    
    # 3. 尝试从 who am i 获取 (处理 sudo 环境)
    if [ -z "$current_ip" ]; then
        current_ip=$(who am i 2>/dev/null | awk -F'[()]' '{print $2}')
    fi
    
    # 4. 尝试从 who -m 获取
    if [ -z "$current_ip" ]; then
        current_ip=$(who -m 2>/dev/null | awk -F'[()]' '{print $2}')
    fi

    # 5. 尝试通过 ss 探测 (针对 SSH 端口)
    if [ -z "$current_ip" ]; then
        local ssh_port
        ssh_port=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -n1)
        ssh_port=${ssh_port:-22}
        current_ip=$(ss -nt 2>/dev/null | grep ":$ssh_port" | grep ESTAB | awk '{print $5}' | cut -d: -f1 | grep -v -E '127.0.0.1|::1' | head -n 1)
    fi

    # 6. 尝试通过 netstat 探测
    if [ -z "$current_ip" ]; then
        local ssh_port
        ssh_port=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -n1)
        ssh_port=${ssh_port:-22}
        current_ip=$(netstat -tn 2>/dev/null | grep ":$ssh_port" | grep ESTABLISHED | awk '{print $5}' | cut -d: -f1 | grep -v -E '127.0.0.1|::1' | head -n 1)
    fi

    # 过滤掉非 IP 格式的输出 (如空值或本地终端名)
    if [[ ! "$current_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        current_ip=""
    fi
    
    echo "$current_ip"
}

# 检查密码是否包含不支持的特殊字符
fn_check_password_safe() {
    local pwd="$1"
    # 检查是否包含反斜杠、斜杠或双引号（这些字符容易导致 YAML 解析错误或 sed 替换问题）
    if [[ "$pwd" =~ [\\/\"\&] ]]; then
        return 1
    fi
    return 0
}

# 转义 sed 替换字符串中的特殊字符 (&, /, \)
fn_escape_sed_str() {
    local s="$1"
    s="${s//\\/\\\\}" # 1. 转义反斜杠
    s="${s//\//\\/}"  # 2. 转义斜杠
    s="${s//&/\\&}"   # 3. 转义 & 符号
    echo "$s"
}

# set -e  # 已移除全局退出设置，改为逻辑容错
# set -o pipefail

readonly GUGU_PATH="/usr/local/bin/$GUGU_COMMAND"
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[1;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

IS_DEBIAN_LIKE=false
DETECTED_OS="未知"
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DETECTED_OS="$PRETTY_NAME"
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        IS_DEBIAN_LIKE=true
    fi
fi

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "\n${RED}[ERROR] $1${NC}\n"; return 1 2>/dev/null || exit 1; }
log_action() { echo -e "${YELLOW}[ACTION] $1${NC}"; }
log_step() { echo -e "\n${BLUE}--- $1: $2 ---${NC}"; }
log_success() { echo -e "${GREEN}✓ $1${NC}"; }

# --- [核心功能] 自安装、自更新与卸载 ---
fn_auto_install() {
    # 如果当前运行路径不是目标路径，则执行安装
    if [[ "$0" != "$GUGU_PATH" ]]; then
        log_info "正在将脚本安装到系统路径 ($GUGU_PATH)..."
        if [[ "$0" == "/dev/fd/"* ]] || [[ "$0" == "-" ]] || [[ ! -f "$0" ]]; then
            # 处理通过 curl | bash 或进程替换运行的情况
            if ! curl -sL "$GUGU_URL" -o "$GUGU_PATH"; then
                log_error "安装失败：无法从网络下载脚本。" || return 1
            fi
        else
            cp -f "$0" "$GUGU_PATH"
        fi
        chmod +x "$GUGU_PATH"
        log_success "安装完成！现在你可以直接使用 '${YELLOW}$GUGU_COMMAND${NC}' 命令调用脚本。"
    fi
}

fn_check_update() {
    # 仅在已安装到系统路径时才在启动时检查更新，避免干扰初次安装
    [[ "$0" != "$GUGU_PATH" ]] && return

    log_info "正在检查版本更新..."
    # 获取远程版本号 (匹配 readonly SCRIPT_VERSION="xxx")
    local remote_version
    remote_version=$(curl -sL "$GUGU_URL" | grep -oP 'readonly SCRIPT_VERSION="\K[^"]+' | head -n 1)
    
    if [ -n "$remote_version" ] && [ "$remote_version" != "$SCRIPT_VERSION" ]; then
        echo -e "${YELLOW}[更新提示] 发现新版本: ${GREEN}$remote_version${NC} (当前: $SCRIPT_VERSION)"
        read -rp "是否立即升级到最新版本？[Y/n]: " confirm_update < /dev/tty
        if [[ "${confirm_update:-y}" =~ ^[Yy]$ ]]; then
            log_action "正在下载并应用更新..."
            if curl -sL "$GUGU_URL" -o "$GUGU_PATH"; then
                log_success "更新成功！正在重启脚本..."
                sleep 1
                exec bash "$GUGU_PATH"
            else
                log_error "更新失败，请检查网络连接。"
            fi
        fi
    else
        log_success "当前已是最新版本 ($SCRIPT_VERSION)。"
    fi
}

fn_uninstall_gugu() {
    echo -e "\n${RED}警告：此操作将从系统中移除 '$GUGU_COMMAND' 命令。${NC}"
    read -rp "确定要继续吗？[y/N]: " confirm_un < /dev/tty
    if [[ "$confirm_un" =~ ^[Yy]$ ]]; then
        rm -f "$GUGU_PATH"
        log_success "脚本已成功从系统中移除。"
        exit 0
    else
        log_info "操作已取消。"
    fi
}
# ------------------------------------

fn_show_main_header() {
    echo -e "${YELLOW}>>${GREEN} 咕咕助手 ${SCRIPT_VERSION}${NC}"
    echo -e "   ${BOLD}\033[0;37m作者: 清绝 | 博客: blog.qjyg.de${NC}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
       echo -e "\n${RED}错误: 此脚本需要 root 权限执行。${NC}"
       echo -e "请尝试使用 ${YELLOW}sudo bash $0${NC} 来运行。\n"
       return 1
    fi
    return 0
}

fn_check_base_deps() {
    local missing_pkgs=()
    local required_pkgs=("bc" "curl" "tar" "sudo")

    log_info "正在检查基础依赖: ${required_pkgs[*]}..."
    for pkg in "${required_pkgs[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_action "检测到缺失的工具: ${missing_pkgs[*]}，正在尝试自动安装..."
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            apt-get update > /dev/null 2>&1
            if ! apt-get install -y "${missing_pkgs[@]}"; then
                log_error "部分基础依赖自动安装失败，请手动执行 'apt-get install -y ${missing_pkgs[*]}' 后重试。" || return 1
            fi
            log_success "所有缺失的基础依赖已安装成功。"
        else
            log_error "您的系统 (${DETECTED_OS}) 不支持自动安装。请手动安装缺失的工具: ${missing_pkgs[*]}" || return 1
        fi
    else
        log_success "基础依赖完整。"
    fi
}

# --- [通用 Docker 环境检查与辅助函数] ---
fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
fn_print_info() { echo -e "  $1"; }
fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; return 1 2>/dev/null || exit 1; }

fn_get_cleaned_version_num() { echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }

fn_detect_compose_cmd() {
    if command -v docker-compose &> /dev/null; then
        echo "docker-compose"
        return 0
    fi
    if docker compose version &> /dev/null; then
        echo "docker compose"
        return 0
    fi
    return 1
}

fn_resolve_project_dir() {
    local container_name="$1"
    local fallback_subdir="$2"
    local project_dir=""
    project_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_name" 2>/dev/null || true)

    if [ -n "$project_dir" ] && [ -d "$project_dir" ]; then
        echo "$project_dir"
        return 0
    fi

    if [ -n "$fallback_subdir" ]; then
        echo "${USER_HOME}/${fallback_subdir}"
        return 0
    fi

    return 1
}

fn_prompt_port_in_range() {
    local __result_var="$1"
    local prompt="$2"
    local default_port="$3"
    local min_port="$4"
    local max_port="$5"
    local input_port=""

    while true; do
        read -rp "$prompt" input_port < /dev/tty
        input_port=${input_port:-$default_port}
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge "$min_port" ] && [ "$input_port" -le "$max_port" ]; then
            printf -v "$__result_var" '%s' "$input_port"
            return 0
        fi
        log_warn "端口无效。请输入 ${min_port}-${max_port} 之间的数字。"
    done
}

fn_confirm_remove_existing_container() {
    local container_name="$1"
    local confirm_text="${2:-是否停止并移除现有容器？[y/N]: }"

    if docker ps -a -q -f "name=^${container_name}$" | grep -q .; then
        log_warn "检测到已存在名为 '${container_name}' 的容器。"
        read -rp "$confirm_text" confirm_rm < /dev/tty
        if [[ "$confirm_rm" =~ ^[Yy]$ ]]; then
            docker stop "$container_name" >/dev/null 2>&1 || true
            docker rm "$container_name" >/dev/null 2>&1 || true
        else
            log_info "操作已取消。"
            return 1
        fi
    fi
    return 0
}

fn_report_dependencies() {
    fn_print_info "--- Docker 环境诊断摘要 ---"
    printf "${BOLD}%-18s %-20s %-20s${NC}\n" "工具" "检测到的版本" "状态"
    printf "${CYAN}%-18s %-20s %-20s${NC}\n" "------------------" "--------------------" "--------------------"
    print_status_line() {
        local name="$1" version="$2" status="$3"
        local color="$GREEN"
        if [[ "$status" == "未安装" ]]; then color="$RED"; fi
        printf "%-18s %-20s ${color}%-20s${NC}\n" "$name" "$version" "$status"
    }
    print_status_line "Docker" "$DOCKER_VER" "$DOCKER_STATUS"
    print_status_line "Docker Compose" "$COMPOSE_VER" "$COMPOSE_STATUS"
    echo ""
}

fn_check_dependencies() {
    fn_ensure_valid_cwd || true
    fn_print_info "--- Docker 环境诊断开始 ---"
    
    local docker_check_needed=true
    while $docker_check_needed; do
        if ! command -v docker &> /dev/null; then
            DOCKER_STATUS="未安装"
        else
            DOCKER_VER=$(fn_get_cleaned_version_num "$(docker --version)"); DOCKER_STATUS="正常"
        fi
        DOCKER_COMPOSE_CMD=$(fn_detect_compose_cmd || true)
        if [ -n "$DOCKER_COMPOSE_CMD" ]; then
            if [ "$DOCKER_COMPOSE_CMD" = "docker-compose" ]; then
                COMPOSE_VER="v$(fn_get_cleaned_version_num "$($DOCKER_COMPOSE_CMD version)")"
                COMPOSE_STATUS="正常 (v1)"
            else
                COMPOSE_VER=$(docker compose version | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n 1)
                COMPOSE_STATUS="正常 (v2)"
            fi
        else
            COMPOSE_VER="-"
            COMPOSE_STATUS="未安装"
        fi

        if [[ "$DOCKER_STATUS" == "未安装" || "$COMPOSE_STATUS" == "未安装" ]]; then
            if [ "$IS_DEBIAN_LIKE" = true ]; then
                log_warn "未检测到 Docker 或 Docker-Compose。"
                read -rp "是否立即尝试自动安装 Docker? [Y/n]: " confirm_install_docker < /dev/tty
                if [[ "${confirm_install_docker:-y}" =~ ^[Yy]$ ]]; then
                    log_action "正在使用官方推荐脚本安装 Docker..."
                    bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
                    continue
                else
                    fn_print_error "用户选择不安装 Docker，脚本无法继续。" || return 1
                fi
            else
                fn_print_error "未检测到 Docker 或 Docker-Compose。请在您的系统 (${DETECTED_OS}) 上手动安装它们后重试。" || return 1
            fi
        else
            docker_check_needed=false
        fi
    done

    fn_report_dependencies

    local current_user="${SUDO_USER:-$(whoami)}"
    if ! groups "$current_user" | grep -q '\bdocker\b' && [ "$(id -u)" -ne 0 ]; then
        fn_print_error "当前用户不在 docker 用户组。请尝试【重新登录SSH】或手动执行 'sudo usermod -aG docker \$USER' 后再试。" || return 1
    fi
    log_success "Docker 环境检查通过！"
}

fn_verify_container_health() {
    local container_name="$1"
    local retries=10
    local interval=3
    local spinner="/-\|"
    fn_print_info "正在确认容器健康状态..."
    echo -n "  "
    for i in $(seq 1 $retries); do
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "错误")
        if [[ "$status" == "running" ]]; then
            echo -e "\r  ${GREEN}✓${NC} 容器已成功进入运行状态！"
            return 0
        fi
        echo -ne "${spinner:i%4:1}\r"
        sleep $interval
    done
    echo -e "\r  ${RED}✗${NC} 容器未能进入健康运行状态！"
    fn_print_info "以下是容器的最新日志，以帮助诊断问题："
    echo -e "${YELLOW}--- 容器日志开始 ---${NC}"
    docker logs "$container_name" --tail 50 || echo "无法获取容器日志。"
    echo -e "${YELLOW}--- 容器日志结束 ---${NC}"
    fn_print_error "部署失败。请检查以上日志以确定问题原因。"
}

fn_wait_for_service() {
    local seconds="${1:-10}"
    while [ $seconds -gt 0 ]; do
        printf "  服务正在后台稳定，请稍候... ${YELLOW}%2d 秒${NC}  \r" "$seconds"
        sleep 1
        ((seconds--))
    done
    echo -e "                                           \r"
}

# 通用 Docker 应用卸载函数
fn_uninstall_docker_app() {
    local container_name=$1
    local display_name=$2
    local project_dir=$3
    local image_name=$4

    echo -e "\n${RED}警告：此操作将彻底卸载 ${display_name}！${NC}"
    echo -e "此操作将执行以下步骤："
    echo -e "  1. 停止并移除容器: ${YELLOW}${container_name}${NC}"
    echo -e "  2. 移除 Docker 镜像: ${YELLOW}${image_name}${NC}"
    echo -e "  3. ${BOLD}${RED}永久删除项目目录及其所有数据: ${project_dir}${NC}"
    
    read -rp "确定要继续吗？[y/N]: " confirm1 < /dev/tty
    if [[ ! "$confirm1" =~ ^[Yy]$ ]]; then
        log_info "操作已取消。"
        return 1
    fi

    read -rp "请再次确认，输入 'yes' 以执行卸载: " confirm2 < /dev/tty
    if [[ "$confirm2" != "yes" ]]; then
        log_info "输入不匹配，操作已取消。"
        return 1
    fi

    log_action "正在卸载 ${display_name}..."

    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "正在停止并移除容器..."
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
    fi

    if [ -n "$image_name" ]; then
        log_info "正在移除镜像 ${image_name}..."
        docker rmi "$image_name" >/dev/null 2>&1 || true
    fi

    if [ -d "$project_dir" ]; then
        log_info "正在删除项目目录: ${project_dir}..."
        rm -rf "$project_dir"
    fi

    log_success "${display_name} 已成功卸载。"
    return 0
}

fn_check_in_china() {
    log_info "正在判断服务器地理位置..."
    # 通过测试 google.com 的连通性来判断是否在大陆
    if curl -s --connect-timeout 3 https://www.google.com > /dev/null; then
        log_success "检测到服务器位于海外，将直接使用官方 Docker 源。"
        return 1 # 不在大陆
    else
        log_warn "检测到服务器位于中国大陆，建议配置镜像加速。"
        return 0 # 在大陆
    fi
}

fn_optimize_docker() {
    log_action "是否需要进行 Docker 优化（配置日志限制与镜像加速）？"
    log_info "此操作将：1. 限制日志大小防止磁盘占满。 2. 自动测速或手动配置镜像源。"
    
    while true; do
        echo -e "\n${CYAN}--- Docker 优化选项 ---${NC}"
        echo -e "  [1] 自动模式 (推荐: 自动判断地理位置并配置最快镜像)"
        echo -e "  [2] 手动模式 (手动输入自定义镜像地址)"
        echo -e "  [3] 仅限制日志 (不配置镜像加速)"
        echo -e "  [n] 跳过所有优化"
        read -rp "请选择 [1/2/3/n, 默认 1]: " opt_choice < /dev/tty
        opt_choice=${opt_choice:-1}

        [[ "$opt_choice" =~ ^[123Nn]$ ]] && break
        log_warn "无效选项，请重新选择。"
    done

    if [[ "$opt_choice" =~ ^[Nn]$ ]]; then
        log_info "已跳过 Docker 优化。"
        return
    fi

    local DAEMON_JSON="/etc/docker/daemon.json"
    local best_mirrors=()
    
    case "$opt_choice" in
        1)
            if fn_check_in_china; then
                log_info "正在检测内置 Docker 镜像源可用性..."
                local mirrors=(
                    "https://docker.1ms.run" "https://hub1.nat.tf" "https://docker.1panel.live"
                    "https://dockerproxy.1panel.live" "https://hub.rat.dev" "https://docker.m.ixdev.cn"
                    "https://hub2.nat.tf" "https://docker.1panel.dev" "https://docker.amingg.com" "https://docker.xuanyuan.me"
                    "https://dytt.online" "https://lispy.org" "https://docker.xiaogenban1993.com"
                    "https://docker-0.unsee.tech" "https://666860.xyz" "https://hubproxy-advj.onrender.com"
                )
                docker rmi hello-world > /dev/null 2>&1 || true
                local results=""
                for mirror in "${mirrors[@]}"; do
                    local pull_target="${mirror#https://}/library/hello-world"
                    echo -ne "  - 正在测试: ${YELLOW}${mirror}${NC}..."
                    local start_time; start_time=$(date +%s.%N)
                    if (timeout -k 12 10 docker pull "$pull_target" >/dev/null) 2>/dev/null; then
                        local end_time; end_time=$(date +%s.%N); local duration; duration=$(echo "$end_time - $start_time" | bc)
                        printf " ${GREEN}%.2f 秒${NC}\n" "$duration"
                        results+="${duration}|${mirror}\n"
                        docker rmi "$pull_target" > /dev/null 2>&1 || true
                    else
                        echo -e " ${RED}超时或失败${NC}"
                    fi
                done
                
                if [ -n "$results" ]; then
                    best_mirrors=($(echo -e "$results" | grep '.' | LC_ALL=C sort -n | head -n 3 | cut -d'|' -f2))
                    log_success "已选取最快的 ${#best_mirrors[@]} 个镜像源。"
                else
                    log_warn "所有内置镜像均测试失败！"
                fi
            fi
            ;;
        2)
            echo -e "\n${CYAN}--- 自定义镜像说明 ---${NC}"
            echo -e "  1. ${BOLD}注册表镜像 (Registry Mirror)${NC}: 以 ${YELLOW}https://${NC} 开头，写入 daemon.json (系统级加速)。"
            echo -e "     例如: https://docker.1ms.run"
            echo -e "  2. ${BOLD}镜像代理 (Proxy Pull)${NC}: 直接输入代理后的完整镜像路径 (临时拉取并自动重打标签)。"
            echo -e "     例如: dockerproxy.com/ghcr.io/sillytavern/sillytavern:latest"
            echo -e "------------------------"
            read -rp "请输入自定义地址 (多个请用空格分隔): " custom_input < /dev/tty
            read -ra input_items <<< "$custom_input"
            for item in "${input_items[@]}"; do
                if [[ "$item" =~ ^https:// ]]; then
                    best_mirrors+=("$item")
                else
                    # 识别为代理镜像路径
                    CUSTOM_PROXY_IMAGE="$item"
                    log_info "检测到代理镜像路径: ${YELLOW}${CUSTOM_PROXY_IMAGE}${NC}"
                fi
            done
            ;;
        3)
            log_info "仅配置日志限制。"
            ;;
    esac

    log_action "正在应用 Docker 优化配置 (安全模式)..."
    
    mkdir -p /etc/docker
    if [ -f "$DAEMON_JSON" ]; then
        log_info "检测到现有的 daemon.json，正在备份并尝试合并配置..."
        cp "$DAEMON_JSON" "${DAEMON_JSON}.bak_$(date +%Y%m%d_%H%M%S)"
        
        # 检查是否存在自定义存储路径 (data-root)
        if grep -q "data-root" "$DAEMON_JSON"; then
            local current_root; current_root=$(grep "data-root" "$DAEMON_JSON" | cut -d'"' -f4)
            log_warn "检测到自定义 Docker 存储路径: ${current_root}"
            log_warn "为防止数据丢失，脚本将不会覆盖您的核心配置。"
        fi
    fi

    # 构建镜像列表 JSON 数组
    local mirrors_json="[]"
    if [ ${#best_mirrors[@]} -gt 0 ]; then
        mirrors_json=$(printf '"%s", ' "${best_mirrors[@]}" | sed 's/, $//')
        mirrors_json="[ $mirrors_json ]"
    fi

    # 使用 Python 进行安全的 JSON 合并 (如果 Python 可用)
    if command -v python3 &> /dev/null; then
        python3 - <<EOF
import json, os
path = "$DAEMON_JSON"
new_conf = {
    "log-driver": "json-file",
    "log-opts": {"max-size": "50m", "max-file": "3"}
}
if $mirrors_json:
    new_conf["registry-mirrors"] = $mirrors_json

try:
    if os.path.exists(path):
        with open(path, 'r') as f:
            data = json.load(f)
    else:
        data = {}
    
    # 深度合并配置，保留原有非冲突项
    data.update({k: v for k, v in new_conf.items() if k not in data or k == "registry-mirrors"})
    if "log-opts" in data and isinstance(data["log-opts"], dict):
        data["log-opts"].update(new_conf["log-opts"])
    else:
        data["log-opts"] = new_conf["log-opts"]

    with open(path, 'w') as f:
        json.dump(data, f, indent=4)
except Exception as e:
    print(f"JSON 合并失败: {e}")
    exit(1)
EOF
    else
        # 回退方案：如果没 Python，则仅在文件不存在时创建，存在时警告
        if [ ! -f "$DAEMON_JSON" ]; then
            cat <<EOF | tee "$DAEMON_JSON" > /dev/null
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    }$( [ "$mirrors_json" != "[]" ] && echo ",
    \"registry-mirrors\": $mirrors_json" )
}
EOF
        else
            log_error "系统中未检测到 Python3，无法安全合并 JSON。请手动修改 ${DAEMON_JSON}。"
            return 1
        fi
    fi

    if systemctl restart docker; then
        log_success "Docker 服务已重启，优化配置已生效！"
    else
        log_error "Docker 服务重启失败！请检查 ${DAEMON_JSON} 格式。" || return 1
    fi
}


run_system_cleanup() {
    log_action "即将执行系统安全清理..."
    echo -e "此操作将执行以下命令："
    echo -e "  - ${CYAN}apt-get clean -y${NC} (清理apt缓存)"
    echo -e "  - ${CYAN}journalctl --vacuum-size=100M${NC} (压缩日志到100M)"
    if command -v docker &> /dev/null; then
        echo -e "  - ${CYAN}docker system prune -f${NC} (清理无用的Docker镜像和容器)"
    fi
    read -rp "确认要继续吗? [Y/n] " confirm < /dev/tty
    if [[ ! "${confirm:-y}" =~ ^[Yy]$ ]]; then
        log_info "操作已取消。"
        return
    fi

    log_info "正在清理 apt 缓存..."
    apt-get clean -y
    log_success "apt 缓存清理完成。"

    log_info "正在压缩 journald 日志..."
    journalctl --vacuum-size=100M
    log_success "journald 日志压缩完成。"

    if command -v docker &> /dev/null; then
        log_info "正在清理 Docker 系统..."
        docker system prune -f
        log_success "Docker 系统清理完成。"
    else
        log_warn "未检测到 Docker，已跳过 Docker 系统清理步骤。"
    fi

    log_info "系统安全清理已全部完成！"
}


create_dynamic_swap() {
    local mem_total_mb
    mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')

    # 设定目标 Swap 大小
    local target_swap_mb
    if [ "$mem_total_mb" -lt 1024 ]; then
        target_swap_mb=$((mem_total_mb * 2))
    else
        target_swap_mb=2048
    fi

    # 1. 先暂时关闭脚本可能创建过的旧 swapfile，以便准确计算原生 Swap
    if [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
    fi

    # 2. 获取当前系统剩余的 Swap（通常是原生分区）
    local native_swap_mb
    native_swap_mb=$(free -m | awk '/^Swap:/{print $2}')

    if [ "$native_swap_mb" -ge "$target_swap_mb" ]; then
        log_success "检测到系统原生 Swap (${native_swap_mb}MB) 已超过或等于目标容量 (${target_swap_mb}MB)。"
        log_info "无需额外配置，将跳过创建补足文件以节省硬盘空间。"
        # 如果之前有旧的 swapfile 且现在不需要了，清理掉
        if [ -f /swapfile ]; then
            rm -f /swapfile
            sed -i '/\/swapfile/d' /etc/fstab
        fi
        return 0
    fi

    # 3. 计算需要补足的差额
    local needed_mb=$((target_swap_mb - native_swap_mb))
    local needed_display
    needed_display=$(echo "scale=1; $needed_mb / 1024" | bc | sed 's/^\./0./')G

    log_info "当前物理内存: ${mem_total_mb}MB | 原生 Swap: ${native_swap_mb}MB"
    log_action "将创建 ${needed_display} 的补足文件，使总 Swap 达到约 $(($target_swap_mb / 1024))G..."

    # 4. 创建/更新补足文件
    if ! fallocate -l "${needed_mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$needed_mb" status=progress
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 5. 确保开机自启条目唯一
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    local final_swap
    final_swap=$(free -m | awk '/^Swap:/{print $2}')
    if [ "$native_swap_mb" -eq 0 ]; then
        log_success "Swap 优化完成！当前总 Swap 容量: ${final_swap}MB (补足文件)。"
    else
        log_success "Swap 优化完成！当前总 Swap 容量: ${final_swap}MB (原生分区 + 补足文件)。"
    fi
}

fn_set_timezone() {
    log_step "设置系统时区" "Asia/Shanghai"
    timedatectl set-timezone Asia/Shanghai
    log_success "时区设置完成。当前系统时间: $(date +"%Y-%m-%d %H:%M:%S")"
}

fn_change_ssh_port() {
    log_step "修改 SSH 服务端口" "增强安全性"
    local current_ports=$(fn_get_ssh_port)
    log_info "当前生效的 SSH 端口: ${YELLOW}${current_ports}${NC}"
    
    log_info "执行前，请确保已在云服务商控制台放行新端口。"
    while true; do
        read -rp "请输入新的 SSH 端口号 (1-65535，输入 q 取消): " NEW_SSH_PORT < /dev/tty
        [[ "$NEW_SSH_PORT" == "q" ]] && return 1
        if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
            break
        else
            log_warn "输入无效。端口号必须是 1-65535 之间的数字。"
        fi
    done

    # 检查新端口是否已经在当前生效列表中
    if echo "$current_ports" | grep -qE "(^|,)$NEW_SSH_PORT(,|$)"; then
        # 如果当前只有一个端口且就是新端口，则跳过
        if [[ "$current_ports" == "$NEW_SSH_PORT" ]]; then
            log_info "新端口与当前端口一致，无需修改。"
            return 0
        fi
        log_info "新端口已经在监听列表中，脚本将尝试清理其他冗余端口并收拢为单端口。"
    fi

    if [ "$NEW_SSH_PORT" -lt 1024 ]; then
        log_warn "您输入的是低位端口 (${NEW_SSH_PORT})，容易被扫描，建议使用 49152-65535 之间的高位端口。"
        read -rp "确定要继续吗？[y/N]: " confirm_low < /dev/tty
        if [[ ! "$confirm_low" =~ ^[Yy]$ ]]; then return 1; fi
    fi

    log_action "正在修改 SSH 端口配置并清理冗余定义..."
    # 备份主配置文件
    cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    # 备份可能存在的 .d 配置文件
    if [ -f /etc/ssh/sshd_config.d/99-gugu-ssh.conf ]; then
        cp -f /etc/ssh/sshd_config.d/99-gugu-ssh.conf /etc/ssh/sshd_config.d/99-gugu-ssh.conf.bak
    fi
    
    # 1. 无论哪种模式，先注释掉主文件中的所有 Port 定义
    sed -i 's/^\s*Port /#Port /g' /etc/ssh/sshd_config

    # 2. 现代管理方式：处理 sshd_config.d 目录
    if [ -d /etc/ssh/sshd_config.d ] && grep -qE "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
        log_info "检测到支持 sshd_config.d 目录，正在清理冗余配置..."
        # 注释掉该目录下所有 .conf 文件中的 Port 定义（排除我们自己的 99-gugu-ssh.conf）
        find /etc/ssh/sshd_config.d/ -name "*.conf" ! -name "99-gugu-ssh.conf" -exec sed -i 's/^\s*Port /#Port /g' {} +
        # 创建/更新我们的独立配置文件
        echo "Port $NEW_SSH_PORT" | tee /etc/ssh/sshd_config.d/99-gugu-ssh.conf > /dev/null
    else
        log_info "使用传统方式修改 /etc/ssh/sshd_config。"
        # 传统方式：在文件开头添加（因为上面已经注释了所有旧的）
        sed -i "1iPort $NEW_SSH_PORT" /etc/ssh/sshd_config
    fi
    
    # --- 关键修复：在重启 SSH 前放行 UFW 端口，防止重启后立即被拦截 ---
    if ufw status | grep -q "Status: active"; then
        log_info "检测到 UFW 活跃，正在放行新端口 ${NEW_SSH_PORT}..."
        ufw allow "$NEW_SSH_PORT/tcp"
        ufw --force reload
    fi

    log_action "正在重启 SSH 服务以应用新端口 ${NEW_SSH_PORT}..."
    systemctl restart sshd
    # ------------------------------------
    
    echo -e "\n${BLUE}╔═══════════════════════ SSH 端口连接测试 ═══════════════════════╗${NC}"
    echo -e "║                                                                ║"
    echo -e "║  ${YELLOW}[重要] 请立即打开一个新的终端窗口，尝试连接新端口：${NC}${BOLD}${GREEN}${NEW_SSH_PORT}${NC}       ║"
    echo -e "║                                                                ║"
    echo -e "║  ${CYAN}注意：在确认连接成功前，请勿关闭当前窗口！${NC}                    ║"
    echo -e "║                                                                ║"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"

    read -rp "新端口是否连接成功？(输入 y 确认并继续 / 直接回车则回滚退出) [y/N]: " choice < /dev/tty
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        log_success "确认新端口可用。SSH 端口已成功更换为 ${NEW_SSH_PORT}！"
        
        # --- UFW 协同逻辑 ---
        if ufw status | grep -q "Status: active"; then
            log_info "检测到 UFW 活跃，正在同步清理旧规则..."
            # 循环关闭旧端口
            IFS=',' read -ra ADDR <<< "$current_ports"
            for old_port in "${ADDR[@]}"; do
                if [ "$old_port" != "$NEW_SSH_PORT" ]; then
                    log_info "正在移除旧端口规则: ${old_port}"
                    ufw delete allow "$old_port/tcp" 2>/dev/null || true
                fi
            done
            ufw --force reload
            log_success "UFW 规则已同步。"
        fi
        # -------------------

        # 计算需要关闭的旧端口（排除掉新端口）
        local ports_to_close=$(echo "$current_ports" | tr ',' '\n' | grep -v "^$NEW_SSH_PORT$" | paste -sd "," -)
        
        if [ -n "$ports_to_close" ]; then
            echo -e "\n${YELLOW}[提示] UFW 已自动移除本地旧端口规则。${NC}"
            echo -e "       如果您使用了云服务商控制台防火墙（如安全组），请务必前往手动禁用旧端口 (${RED}${ports_to_close}${NC})；"
            echo -e "       若无云端防火墙，则无需操作。\n"
        fi
        
        # 如果安装了 Fail2ban，自动更新其监听端口
        if command -v fail2ban-client &> /dev/null; then
            log_info "检测到 Fail2ban，正在同步更新其监听端口..."
            sed -i "s/^port = .*/port = $NEW_SSH_PORT/" /etc/fail2ban/jail.local
            systemctl restart fail2ban
        fi
    else
        fn_ssh_rollback "$NEW_SSH_PORT"
        # 清理备份文件
        rm -f /etc/ssh/sshd_config.bak /etc/ssh/sshd_config.d/99-gugu-ssh.conf.bak 2>/dev/null || true
        return 1
    fi

    # 成功后清理备份文件
    rm -f /etc/ssh/sshd_config.bak /etc/ssh/sshd_config.d/99-gugu-ssh.conf.bak 2>/dev/null || true
}

fn_install_ufw() {
    local mode=$1
    log_step "安装并配置 UFW 防火墙" "本地安全加固"
    
    if ! command -v ufw &> /dev/null; then
        log_action "正在安装 UFW..."
        apt-get update
        apt-get install -y ufw
    else
        log_info "UFW 已安装。"
    fi

    local ssh_port=$(fn_get_ssh_port)
    log_info "当前 SSH 端口为: ${YELLOW}${ssh_port}${NC}"
    
    log_action "正在配置基础规则..."
    # 默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 关键：防锁死，先放行当前 SSH 端口（支持多端口情况）
    log_info "正在放行当前 SSH 端口 (${ssh_port})..."
    IFS=',' read -ra ADDR <<< "$ssh_port"
    for port in "${ADDR[@]}"; do
        ufw allow "${port}/tcp"
    done
    
    local confirm_ufw
    if [[ "$mode" == "auto" ]]; then
        confirm_ufw="y"
    else
        echo -e "\n${YELLOW}[安全提示] 启用 UFW 后，本地防火墙将接管端口管理。${NC}"
        echo -e "脚本已自动放行当前的 SSH 端口，开启后不会导致掉线。"
        read -rp "确定要立即启用 UFW 本地防火墙吗？[y/N]: " confirm_ufw < /dev/tty
    fi

    if [[ "$confirm_ufw" =~ ^[Yy]$ ]]; then
        log_action "正在启用 UFW..."
        ufw --force enable
        log_success "UFW 已启用并设置为开机自启。"
    else
        log_info "已取消启用 UFW。规则已预设，您可以稍后手动执行 'ufw enable'。"
    fi
}

fn_ufw_manager() {
    while true; do
        tput reset
        echo -e "${BLUE}=== UFW 防火墙运维管理 ===${NC}"
        local status=$(ufw status | head -n 1 | sed 's/Status: active/状态: 已启用/g' | sed 's/Status: inactive/状态: 已禁用/g')
        echo -e "当前状态: ${CYAN}${status}${NC}"
        echo -e "------------------------"
        echo -e "  [1] 查看详细规则列表"
        echo -e "  [2] 启用防火墙"
        echo -e "  [3] 禁用防火墙"
        echo -e "  [4] 放行指定端口"
        echo -e "  [5] 删除指定规则"
        echo -e "  [6] 查看被 Fail2ban 封禁的 IP"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " ufw_choice < /dev/tty
        [[ -z "$ufw_choice" ]] && continue
        case $ufw_choice in
            1) ufw status numbered; read -rp "按 Enter 继续..." < /dev/tty ;;
            2) ufw --force enable; sleep 1 ;;
            3) ufw disable; sleep 1 ;;
            4)
                read -rp "请输入要放行的端口号 (1-65535): " p_allow < /dev/tty
                if [[ "$p_allow" =~ ^[0-9]+$ ]] && [ "$p_allow" -ge 1 ] && [ "$p_allow" -le 65535 ]; then
                    echo -e "选择协议: [1] TCP (默认)  [2] UDP  [3] TCP & UDP"
                    read -rp "请输入选项 [1-3]: " p_proto < /dev/tty
                    case ${p_proto:-1} in
                        1) ufw allow "$p_allow/tcp"; log_success "端口 $p_allow/tcp 已放行。" ;;
                        2) ufw allow "$p_allow/udp"; log_success "端口 $p_allow/udp 已放行。" ;;
                        3) ufw allow "$p_allow"; log_success "端口 $p_allow (TCP/UDP) 已放行。" ;;
                        *) log_warn "无效协议选项，默认放行 TCP。" ; ufw allow "$p_allow/tcp" ;;
                    esac
                else
                    log_warn "无效端口号，请输入 1-65535 之间的数字。"
                fi
                sleep 2
                ;;
            5)
                while true; do
                    tput reset
                    echo -e "${BLUE}=== 删除 UFW 规则 (连续模式) ===${NC}"
                    ufw status numbered
                    echo -e "------------------------"
                    echo -e "请输入要删除的规则编号 (${YELLOW}输入 0 返回${NC}): "
                    read -rp "> " r_num < /dev/tty
                    if [[ "$r_num" == "0" ]]; then
                        break
                    elif [[ "$r_num" =~ ^[0-9]+$ ]]; then
                        # 尝试删除并捕获错误输出
                        local delete_msg
                        delete_msg=$(ufw --force delete "$r_num" 2>&1)
                        if [[ $? -eq 0 ]]; then
                            log_success "规则编号 $r_num 已成功删除。"
                        else
                            log_warn "删除失败: ${delete_msg}"
                        fi
                    else
                        log_warn "无效输入，请输入数字编号。"
                    fi
                    sleep 1.5
                done
                ;;
            6)
                echo -e "\n${RED}--- 当前被 UFW 拦截的 IP (由 Fail2ban 触发) ---${NC}"
                # Fail2ban 在 UFW 中通常使用 REJECT 动作
                ufw status | grep -E "DENY|REJECT" | grep "by Fail2Ban" || echo "当前无封禁记录。"
                read -rp "按 Enter 继续..." < /dev/tty
                ;;
            0) break ;;
        esac
    done
}

fn_1pctl_run() {
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        1pctl "$@" < /dev/tty > /dev/tty 2>&1
    else
        1pctl "$@"
    fi
}

fn_1panel_manager() {
    while true; do
        tput reset
        echo -e "${BLUE}=== 1Panel 运维管理 ===${NC}"
        if ! command -v 1pctl &> /dev/null; then
            log_error "未检测到 1pctl 命令，请确认 1Panel 是否已正确安装。" || return 1
        fi
        
        echo -e "  [1] 查看面板状态与版本"
        echo -e "  [2] 获取面板登录信息 (user-info)"
        echo -e "  [3] 启动/停止/重启 1Panel 服务"
        echo -e "  [4] 修改面板端口 (自动同步 UFW)"
        echo -e "  [5] 修改面板用户/密码"
        echo -e "  [6] 重置安全设置 (取消域名/入口/IP限制/MFA)"
        echo -e "  [7] 切换监听 IP (IPv4/IPv6)"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " op_1panel < /dev/tty
        [[ -z "$op_1panel" ]] && continue
        case "$op_1panel" in
            1)
                echo -e "\n${CYAN}--- 服务状态 ---${NC}"
                fn_1pctl_run status
                echo -e "\n${CYAN}--- 版本信息 ---${NC}"
                fn_1pctl_run version
                read -rp "按 Enter 继续..." < /dev/tty
                ;;
            2)
                echo -e "\n${CYAN}--- 面板登录信息 ---${NC}"
                fn_1pctl_run user-info
                read -rp "按 Enter 继续..." < /dev/tty
                ;;
            3)
                echo -e "  [1] 启动服务 (start)"
                echo -e "  [2] 停止服务 (stop)"
                echo -e "  [3] 重启服务 (restart)"
                read -rp "请选择 [1-3]: " svc_op < /dev/tty
                case "$svc_op" in
                    1) log_action "正在启动 1Panel 服务..."; fn_1pctl_run start all ;;
                    2) log_action "正在停止 1Panel 服务..."; fn_1pctl_run stop all ;;
                    3) log_action "正在重启 1Panel 服务..."; fn_1pctl_run restart all ;;
                    *) log_warn "无效选项" ;;
                esac
                sleep 2
                ;;
            4)
                local new_1p_port=""
                if fn_prompt_port_in_range new_1p_port "请输入新的面板端口号 (1-65535): " "" 1 65535; then
                    log_action "正在修改面板端口为 ${new_1p_port}..."
                    if fn_1pctl_run update port "$new_1p_port"; then
                        if ufw status | grep -q "Status: active"; then
                            log_info "检测到 UFW 活跃，正在自动放行新端口 ${new_1p_port}..."
                            ufw allow "$new_1p_port/tcp"
                            ufw --force reload
                            log_success "UFW 规则已更新。"
                        fi
                    else
                        log_warn "1Panel 端口修改失败，已跳过 UFW 自动放行。"
                    fi
                fi
                sleep 2
                ;;
            5)
                echo -e "  [1] 修改用户名 (调用 1Panel 官方交互)"
                echo -e "  [2] 修改密码 (调用 1Panel 官方交互)"
                read -rp "请选择 [1-2]: " up_choice < /dev/tty
                if [[ "$up_choice" == "1" ]]; then
                    log_info "即将进入 1Panel 官方用户名修改流程，请按提示操作。"
                    if ! fn_1pctl_run update username; then
                        log_warn "官方交互失败，正在尝试兼容参数模式。"
                        read -rp "请输入新用户名: " new_1p_user < /dev/tty
                        if [ -n "$new_1p_user" ]; then
                            fn_1pctl_run update username "$new_1p_user" || log_warn "兼容参数模式也失败，请执行 '1pctl update username' 手动修改。"
                        else
                            log_warn "用户名为空，已取消。"
                        fi
                    fi
                elif [[ "$up_choice" == "2" ]]; then
                    log_info "即将进入 1Panel 官方密码修改流程。"
                    log_warn "输入密码时屏幕不会显示字符，这是终端的安全设计，属于正常现象。"
                    if ! fn_1pctl_run update password; then
                        log_warn "官方交互失败，正在尝试兼容参数模式。"
                        read -rsp "请输入新密码: " new_1p_pass < /dev/tty
                        echo ""
                        if [ -n "$new_1p_pass" ]; then
                            fn_1pctl_run update password "$new_1p_pass" || log_warn "兼容参数模式也失败，请执行 '1pctl update password' 手动修改。"
                        else
                            log_warn "密码为空，已取消。"
                        fi
                    fi
                else
                    log_warn "无效选项。"
                fi
                sleep 2
                ;;
            6)
                echo -e "${YELLOW}即将重置安全设置，包括取消域名绑定、安全入口、HTTPS、IP限制和两步验证。${NC}"
                read -rp "确定要继续吗？[y/N]: " confirm_reset < /dev/tty
                if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
                    fn_1pctl_run reset domain
                    fn_1pctl_run reset entrance
                    fn_1pctl_run reset https
                    fn_1pctl_run reset ips
                    fn_1pctl_run reset mfa
                    log_success "安全设置已重置。"
                fi
                sleep 2
                ;;
            7)
                echo -e "  [1] 监听 IPv4"
                echo -e "  [2] 监听 IPv6"
                read -rp "请选择 [1-2]: " ip_choice < /dev/tty
                if [[ "$ip_choice" == "1" ]]; then
                    fn_1pctl_run listen-ip ipv4
                elif [[ "$ip_choice" == "2" ]]; then
                    fn_1pctl_run listen-ip ipv6
                fi
                sleep 2
                ;;
            0) break ;;
        esac
    done
}

fn_install_fail2ban() {
    log_step "安装/更新进阶版 Fail2ban" "双重防护体系"
    
    log_action "正在安装 Fail2ban 及必要组件..."
    apt-get update
    apt-get install -y fail2ban python3-systemd
    
    # 移除可能冲突的旧组件
    if dpkg -l | grep -q iptables-persistent; then
        log_info "检测到 iptables-persistent，正在移除以避免与 UFW 冲突..."
        apt-get purge -y iptables-persistent
    fi
    
    local ssh_port=$(fn_get_ssh_port)
    local current_ip=$(fn_get_current_ip)
    log_info "检测到当前 SSH 端口: ${YELLOW}${ssh_port}${NC}"
    
    if [ -z "$current_ip" ]; then
        log_warn "未能自动识别您的连接 IP，将仅添加本地回环到白名单。"
    fi

    local ignore_ips="127.0.0.1/8 ::1"
    if [ -n "$current_ip" ]; then
        log_info "将 IP: ${YELLOW}${current_ip}${NC} 加入白名单。"
        ignore_ips="${ignore_ips} ${current_ip}"
    else
        log_warn "未设置远程白名单 IP，仅添加本地回环。"
    fi

    # 1. 创建自定义过滤器 (针对 systemd journal)
    log_info "配置自定义过滤器: /etc/fail2ban/filter.d/sshd-systemd.conf"
    cat > /etc/fail2ban/filter.d/sshd-systemd.conf << 'EOF'
[Definition]
# 针对systemd journal的SSH攻击过滤器
failregex = ^.*sshd\[\d+\]:\s+Failed password for .* from <HOST> port \d+ ssh2?$
            ^.*sshd\[\d+\]:\s+Invalid user .* from <HOST> port \d+.*$
            ^.*sshd\[\d+\]:\s+Disconnected from authenticating user .* <HOST> port \d+ \[preauth\]$
            ^.*sshd\[\d+\]:\s+Received disconnect from <HOST> port \d+:11: Bye Bye \[preauth\]$
            ^.*sshd\[\d+\]:\s+Connection closed by <HOST> port \d+ \[preauth\]$
            ^.*sshd\[\d+\]:\s+Disconnected from invalid user .* <HOST> port \d+ \[preauth\]$

# 忽略成功登录
ignoreregex = ^.*sshd\[\d+\]:\s+Accepted .* from <HOST> port \d+ .*$

[INCLUDES]
before = common.conf
EOF

    # 2. 创建主配置文件 jail.local
    log_info "配置防护规则: /etc/fail2ban/jail.local"
    
    local f2b_action="iptables-multiport"
    if ufw status | grep -q "Status: active"; then
        log_info "检测到 UFW 活跃，Fail2ban 将使用 UFW 动作。"
        f2b_action="ufw"
    else
        log_info "UFW 未启用，Fail2ban 将使用标准 iptables 动作。"
    fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5
banaction = ${f2b_action}
action = %(action_)s
ignoreip = ${ignore_ips}

[sshd]
# 密码防爆破 (针对多次输错密码)
enabled = true
filter = sshd
port = ${ssh_port}
maxretry = 3
findtime = 600
bantime = 86400
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
action = ${f2b_action}[name=SSH, port="%(port)s", protocol=tcp]

[sshd-aggressive]
# 恶意扫描拦截 (针对非法用户试探、扫描器探测)
enabled = true
filter = sshd-systemd
port = ${ssh_port}
maxretry = 2
findtime = 300
bantime = 604800
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
action = ${f2b_action}[name=SSH-AGG, port="%(port)s", protocol=tcp]
EOF

    # 3. 创建状态监控脚本
    log_info "创建监控脚本: /usr/local/bin/fail2ban-status.sh"
    cat > /usr/local/bin/fail2ban-status.sh << 'EOF'
#!/bin/bash
# Fail2ban 状态监控脚本
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

seconds_to_readable() {
    local seconds=$1
    if [ "$seconds" = "-1" ]; then
        echo "永久封禁"
    else
        local days=$((seconds / 86400))
        local hours=$(((seconds % 86400) / 3600))
        local mins=$(((seconds % 3600) / 60))
        echo "${days}天${hours}小时${mins}分钟"
    fi
}

get_remaining_time() {
    local jail=$1
    local ip=$2
    local ban_time
    ban_time=$(fail2ban-client get "$jail" bantime 2>/dev/null)
    if [ -z "$ban_time" ]; then echo "未知"; return; fi
    if [ "$ban_time" = "-1" ]; then echo "永久"; return; fi
    
    local ban_start
    ban_start=$(grep "Ban $ip" /var/log/fail2ban.log | tail -1 | cut -d' ' -f1-2)
    if [ -z "$ban_start" ]; then echo "未知"; return; fi
    
    local ban_timestamp
    ban_timestamp=$(date -d "$ban_start" +%s 2>/dev/null)
    if [ -z "$ban_timestamp" ]; then echo "未知"; return; fi
    
    local current_timestamp
    current_timestamp=$(date +%s)
    local elapsed=$((current_timestamp - ban_timestamp))
    local remaining=$((ban_time - elapsed))
    if [ $remaining -le 0 ]; then echo "即将解封"; else seconds_to_readable "$remaining"; fi
}

show_jail_status() {
    local jail=$1
    local name=$2
    echo -e "${YELLOW}$name：${NC}"
    
    # 预检服务状态，防止 socket 连接错误
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "  ${RED}错误：Fail2ban 服务未运行，无法获取状态${NC}"
        return 1
    fi

    local status
    status=$(fail2ban-client status "$jail" 2>/dev/null)
    if [ $? -ne 0 ]; then echo "  ${RED}jail '$jail' 未运行或不存在${NC}"; return; fi

    local bantime=$(fail2ban-client get "$jail" bantime 2>/dev/null)
    local findtime=$(fail2ban-client get "$jail" findtime 2>/dev/null)
    local maxretry=$(fail2ban-client get "$jail" maxretry 2>/dev/null)
    echo -e "${BLUE}  封禁策略: ${maxretry}次失败(${findtime}秒内) → 封禁$(seconds_to_readable "$bantime")${NC}"
    local banned_ips=$(fail2ban-client get "$jail" banip 2>/dev/null)
    if [ -n "$banned_ips" ]; then
        echo -e "${RED}  被封禁的IP及剩余时间：${NC}"
        for ip in $banned_ips; do
            local remaining=$(get_remaining_time "$jail" "$ip")
            echo "    $ip → 剩余: $remaining"
        done
    else
        echo "  当前无IP被封禁"
    fi
    echo
}

echo -e "${BLUE}========== Fail2ban 状态报告 $(date) ==========${NC}"

echo -e "\n${YELLOW}1. 服务状态：${NC}"
systemctl is-active --quiet fail2ban && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"

# 显示当前白名单
if command -v fail2ban-client &> /dev/null && systemctl is-active --quiet fail2ban; then
    white_list=$(fail2ban-client get sshd ignoreip 2>/dev/null || echo "获取失败")
    echo -e "${CYAN}当前白名单 (ignoreip): ${NC}${white_list}"
fi

echo -e "\n${YELLOW}2. 活跃的 jail：${NC}"
fail2ban-client status
echo
show_jail_status "sshd" "3. 密码防爆破状态 (sshd)"
show_jail_status "sshd-aggressive" "4. 恶意扫描拦截状态 (sshd-aggressive)"
echo -e "${YELLOW}5. 今日攻击统计：${NC}"
count=$(journalctl _SYSTEMD_UNIT=ssh.service --since today | grep -E "(Failed password|Invalid user)" | wc -l)
echo "攻击次数：$count"
if [ $count -gt 0 ]; then
    echo "攻击IP排行："
    journalctl _SYSTEMD_UNIT=ssh.service --since today | grep -E "(Failed password|Invalid user)" | grep -oP 'from \K[0-9.]+' | sort | uniq -c | sort -nr | head -5
fi
echo -e "\n${GREEN}========== 报告结束 ==========${NC}"
EOF
    chmod +x /usr/local/bin/fail2ban-status.sh

    systemctl enable --now fail2ban
    systemctl restart fail2ban
    log_success "Fail2ban 进阶防护已开启/更新！"
    log_info "您可以使用 ${YELLOW}sudo /usr/local/bin/fail2ban-status.sh${NC} 查看实时报告。"
}

fn_fail2ban_manager() {
    while true; do
        tput reset
        echo -e "${BLUE}=== Fail2ban 运维管理 ===${NC}"
        
        local svc_status
        if systemctl is-active --quiet fail2ban; then
            svc_status="${GREEN}运行中${NC}"
        else
            svc_status="${RED}未运行${NC}"
        fi
        echo -e "服务状态: $svc_status"
        echo -e "------------------------"
        echo -e "  [1] 查看详细封禁报告"
        echo -e "  [2] 查看实时拦截日志 (Ctrl+C 退出)"
        echo -e "  [3] 手动解封被封 IP"
        echo -e "  [4] 手动封禁指定 IP"
        echo -e "  [5] 修改封禁时长 (小时)"
        echo -e "  [6] 重启 Fail2ban 服务"
        echo -e "  [7] 白名单管理"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " f2b_choice < /dev/tty
        [[ -z "$f2b_choice" ]] && continue
        case $f2b_choice in
            1) /usr/local/bin/fail2ban-status.sh; read -rp "按 Enter 继续..." < /dev/tty ;;
            2)
                trap : INT
                tail -f /var/log/fail2ban.log
                trap 'exit 0' INT
                ;;
            3)
                if ! systemctl is-active --quiet fail2ban; then
                    log_error "Fail2ban 服务未运行，无法执行此操作。"
                    sleep 2
                    continue
                fi
                echo -e "\n${CYAN}--- 正在获取被封禁的 IP 列表 ---${NC}"
                # 兼容不同版本的 fail2ban-client 输出格式 (处理空格或制表符)
                local jails
                jails=$(fail2ban-client status | grep "Jail list:" | sed -E 's/.*Jail list:[[:space:]]+//' | tr ',' ' ')
                local banned_list=()
                local i=1
                for jail in $jails; do
                    jail=$(echo "$jail" | xargs) # 移除首尾空格
                    [ -z "$jail" ] && continue
                    local ips=$(fail2ban-client get "$jail" banip)
                    for ip in $ips; do
                        banned_list+=("$jail|$ip")
                        echo -e "  [$i] ${RED}$ip${NC} (来自 Jail: $jail)"
                        i=$((i+1))
                    done
                done

                if [ ${#banned_list[@]} -eq 0 ]; then
                    log_info "当前没有任何被封禁的 IP。"
                    read -rp "按 Enter 继续..." < /dev/tty
                else
                    read -rp "请选择要解封的编号 (直接回车取消): " unban_num < /dev/tty
                    if [[ "$unban_num" =~ ^[0-9]+$ ]] && [ "$unban_num" -le ${#banned_list[@]} ] && [ "$unban_num" -gt 0 ]; then
                        local target=${banned_list[$((unban_num-1))]}
                        local t_jail=${target%|*}
                        local t_ip=${target#*|}
                        fail2ban-client set "$t_jail" unbanip "$t_ip"
                        log_success "IP $t_ip 已从 $t_jail 中解封。"
                    else
                        log_info "操作已取消。"
                    fi
                    sleep 2
                fi
                ;;
            4)
                read -rp "请输入要封禁的 IP: " ban_ip < /dev/tty
                fail2ban-client set sshd banip $ban_ip
                log_success "封禁指令已发送。"
                sleep 2
                ;;
            5)
                echo -e "\n${CYAN}--- 修改封禁时长 ---${NC}"
                echo -e "  [1] 仅修改: 密码防爆破 (sshd)"
                echo -e "  [2] 仅修改: 恶意扫描拦截 (sshd-aggressive)"
                echo -e "  [3] 同时修改全部"
                echo -e "  [0] 取消"
                read -rp "请选择: " time_choice < /dev/tty
                
                local target_jails=()
                case $time_choice in
                    1) target_jails=("sshd") ;;
                    2) target_jails=("sshd-aggressive") ;;
                    3) target_jails=("sshd" "sshd-aggressive") ;;
                    *) continue ;;
                esac

                read -rp "请输入新的封禁时长 (小时，输入 -1 为永久): " ban_hours < /dev/tty
                local ban_seconds
                if [[ "$ban_hours" == "-1" ]]; then
                    ban_seconds="-1"
                elif [[ "$ban_hours" =~ ^[0-9]+$ ]]; then
                    ban_seconds=$((ban_hours * 3600))
                else
                    log_warn "输入无效。"
                    sleep 1
                    continue
                fi

                for jail in "${target_jails[@]}"; do
                    fail2ban-client set "$jail" bantime "$ban_seconds"
                    # 同步更新配置文件中对应 jail 的 bantime
                    # 使用 sed 匹配 jail 块并替换其下的 bantime
                    sed -i "/\[$jail\]/,/\[/ s/bantime = .*/bantime = $ban_seconds/" /etc/fail2ban/jail.local
                done
                
                log_success "封禁时长已更新 (运行时已生效并保存配置)。"
                sleep 2
                ;;
            6) systemctl restart fail2ban; log_success "服务已重启"; sleep 1 ;;
            7)
                log_action "正在进入白名单管理模块..."
                local current_ip=$(fn_get_current_ip)
                echo -e "\n${CYAN}--- Fail2ban 白名单管理 ---${NC}"
                echo -e "当前登录 IP: ${YELLOW}${current_ip:-未知}${NC}"
                echo -e "------------------------"
                echo -e "  [1] 将当前登录 IP 加入白名单"
                echo -e "  [2] 手动输入 IP 或 CIDR 加入白名单"
                echo -e "  [3] 从白名单中移除 IP"
                echo -e "  [0] 返回"
                read -rp "请选择: " wl_choice < /dev/tty
                
                case $wl_choice in
                    1)
                        local add_ip=""
                        if [ -n "$current_ip" ]; then
                            add_ip="$current_ip"
                        else
                            log_warn "无法自动获取当前 IP，请手动输入。"
                            read -rp "请输入 IP: " add_ip < /dev/tty
                        fi
                        
                        if [ -n "$add_ip" ]; then
                            if [ ! -f /etc/fail2ban/jail.local ]; then
                                log_error "未找到 /etc/fail2ban/jail.local 配置文件。" || return 1
                            fi
                            local current_ignore=$(grep "^ignoreip =" /etc/fail2ban/jail.local | cut -d= -f2- | xargs)
                            if echo "$current_ignore" | grep -q "$add_ip"; then
                                log_info "IP $add_ip 已在白名单中。"
                            else
                                local new_ignore="$current_ignore $add_ip"
                                sed -i "s|^ignoreip =.*|ignoreip = $new_ignore|" /etc/fail2ban/jail.local
                                systemctl restart fail2ban
                                log_success "IP $add_ip 已成功加入白名单并重启服务。"
                            fi
                        fi
                        sleep 2
                        ;;
                    2)
                        read -rp "请输入要加入的 IP 或 CIDR: " add_ip < /dev/tty
                        if [ -n "$add_ip" ]; then
                            if [ ! -f /etc/fail2ban/jail.local ]; then
                                log_error "未找到 /etc/fail2ban/jail.local 配置文件。" || return 1
                            fi
                            local current_ignore=$(grep "^ignoreip =" /etc/fail2ban/jail.local | cut -d= -f2- | xargs)
                            local new_ignore="$current_ignore $add_ip"
                            sed -i "s|^ignoreip =.*|ignoreip = $new_ignore|" /etc/fail2ban/jail.local
                            systemctl restart fail2ban
                            log_success "IP $add_ip 已成功加入白名单并重启服务。"
                        fi
                        sleep 2
                        ;;
                    3)
                        if [ ! -f /etc/fail2ban/jail.local ]; then
                            log_error "未找到 /etc/fail2ban/jail.local 配置文件。" || return 1
                        fi
                        local current_ignore=$(grep "^ignoreip =" /etc/fail2ban/jail.local | cut -d= -f2- | xargs)
                        read -ra ignore_list <<< "$current_ignore"
                        if [ ${#ignore_list[@]} -eq 0 ]; then
                            log_info "当前白名单为空。"
                        else
                            echo -e "\n${CYAN}--- 当前白名单列表 ---${NC}"
                            for i in "${!ignore_list[@]}"; do
                                echo -e "  [$((i+1))] ${YELLOW}${ignore_list[$i]}${NC}"
                            done
                            read -rp "请选择要移除的编号 (直接回车取消): " del_num < /dev/tty
                            if [[ "$del_num" =~ ^[0-9]+$ ]] && [ "$del_num" -le ${#ignore_list[@]} ] && [ "$del_num" -gt 0 ]; then
                                local target_ip=${ignore_list[$((del_num-1))]}
                                local new_ignore=""
                                for ip in "${ignore_list[@]}"; do
                                    [[ "$ip" == "$target_ip" ]] && continue
                                    new_ignore="$new_ignore $ip"
                                done
                                new_ignore=$(echo "$new_ignore" | xargs)
                                sed -i "s|^ignoreip =.*|ignoreip = $new_ignore|" /etc/fail2ban/jail.local
                                systemctl restart fail2ban
                                log_success "IP $target_ip 已从白名单中移除并重启服务。"
                            else
                                log_info "操作已取消。"
                            fi
                        fi
                        sleep 2
                        ;;
                esac
                ;;
            0) break ;;
        esac
    done
}

fn_system_upgrade_optimize() {
    log_step "系统升级与内核优化" "BBR + Swap + Upgrade"
    
    log_action "正在更新包列表并升级软件包..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    log_action "正在优化内核参数 (BBR)..."
    # 确保 /etc/sysctl.conf 存在，防止 sed 报错
    if [ ! -f /etc/sysctl.conf ]; then
        log_info "/etc/sysctl.conf 不存在，正在创建..."
        touch /etc/sysctl.conf
    fi

    # 清理旧配置
    sed -i -e '/net.core.default_qdisc=fq/d' \
           -e '/net.ipv4.tcp_congestion_control=bbr/d' \
           -e '/vm.swappiness=10/d' /etc/sysctl.conf
    
    # 确保文件末尾有且只有一个空行，然后追加配置
    if [ -s /etc/sysctl.conf ]; then
        sed -i '${/^$/d;}' /etc/sysctl.conf
    fi

    cat <<EOF >> /etc/sysctl.conf

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
    sysctl -p > /dev/null 2>&1 || true
    
    create_dynamic_swap
    log_success "系统升级与内核优化完成。"
}

fn_reboot_system() {
    local current_ssh_port=$(fn_get_ssh_port)
    echo -e "\n${RED}================================================================${NC}"
    log_warn "系统即将重启，您的 SSH 连接将会断开。"
    echo -e "重启完成后，请等待 1-2 分钟，使用新端口 ${GREEN}${current_ssh_port}${NC} 重新连接。"
    echo -e "如果长时间无法连接，请前往云服务器控制台手动执行重启。"
    echo -e "${RED}================================================================${NC}"
    read -rp "确定要立即重启吗？[y/N]: " confirm_reboot < /dev/tty
    if [[ "$confirm_reboot" =~ ^[Yy]$ ]]; then
        log_action "正在重启系统..."
        reboot
        exit 0
    else
        log_info "已取消重启。请记得稍后手动重启以使所有配置（如 BBR/内核更新）生效。"
    fi
}

run_initialization() {
    while true; do
        tput reset
        echo -e "${CYAN}=== 服务器初始化与安全加固 ===${NC}"
        echo -e "  [1] ${BOLD}${YELLOW}一键全自动优化${NC} (执行以下所有项)"
        echo -e "  [2] 系统升级与内核优化 (BBR + Swap)"
        echo -e "  [3] 设置系统时区 (Asia/Shanghai)"
        echo -e "  [4] 安装并启用 UFW 防火墙 (建议无面板防火墙时使用)"
        echo -e "  [5] 修改 SSH 端口 (支持 1-65535)"
        echo -e "  [6] 安装进阶 Fail2ban (双重防护 + 自动白名单)"
        echo -e "  [7] ${RED}立即重启服务器${NC}"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------------"
        read -rp "请输入选项 [0-7]: " init_choice < /dev/tty
        
        case $init_choice in
            1)
                fn_check_base_deps
                fn_system_upgrade_optimize
                fn_set_timezone
                
                echo -e "\n${CYAN}--- 本地防火墙配置 ---${NC}"
                echo -e "如果您使用的是无面板防火墙的服务器（如部分海外 VPS），建议开启 UFW。"
                echo -e "若已有云厂商面板（如阿里云安全组），则无需重复开启。"
                read -rp "是否需要安装并启用 UFW 本地防火墙？[y/N]: " confirm_ufw_all < /dev/tty
                if [[ "$confirm_ufw_all" =~ ^[Yy]$ ]]; then
                    fn_install_ufw auto
                fi

                if ! fn_change_ssh_port; then
                    log_error "SSH 端口修改失败并已回滚。为确保安全，一键优化流程已中止。" || return 1
                fi

                fn_install_fail2ban
                log_success "一键全自动优化完成！"
                
                if [ -f /var/run/reboot-required ]; then
                    log_warn "检测到系统需要重启以应用内核更新或配置。"
                else
                    log_info "为了确保所有优化（如 BBR 和内核参数）完全生效，建议重启。"
                fi
                fn_reboot_system
                return 0
                ;;
            2) fn_system_upgrade_optimize; sleep 2 ;;
            3) fn_set_timezone; sleep 1 ;;
            4) fn_install_ufw; sleep 2 ;;
            5) fn_change_ssh_port; sleep 1 ;;
            6) fn_install_fail2ban; sleep 2 ;;
            7) fn_reboot_system; sleep 1 ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

install_1panel() {
    tput reset
    echo -e "${CYAN}即将执行【安装 1Panel】流程...${NC}"
    
    if ! command -v curl &> /dev/null; then
        log_info "未检测到 curl，正在尝试安装..."
        apt-get update && apt-get install -y curl
        if ! command -v curl &> /dev/null; then
            log_error "curl 安装失败，请手动安装后再试。" || return 1
        fi
    fi

    log_step "步骤 1/3" "运行 1Panel 官方安装脚本"
    log_warn "即将进入 1Panel 交互式安装界面，需根据其提示操作。"
    bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)" < /dev/tty
    
    log_step "步骤 2/3" "检查并确保 Docker 已安装"
    if ! command -v docker &> /dev/null; then
        log_warn "1Panel 安装程序似乎已结束，但未检测到 Docker。"
        log_action "正在尝试使用备用脚本安装 Docker..."
        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
        
        if ! command -v docker &> /dev/null; then
            log_error "备用脚本也未能成功安装 Docker. 请检查网络或手动安装 Docker 后再继续。" || return 1
        else
            log_success "备用脚本成功安装 Docker！"
        fi
    else
        log_success "Docker 已成功安装。"
    fi

    log_step "步骤 3/3" "自动化后续配置"
    local REAL_USER="${SUDO_USER:-$(whoami)}"
    if [ "$REAL_USER" != "root" ]; then
        if groups "$REAL_USER" | grep -q '\bdocker\b'; then
            log_info "用户 '${REAL_USER}' 已在 docker 用户组中。"
        else
            log_action "正在将用户 '${REAL_USER}' 添加到 docker 用户组..."
            usermod -aG docker "$REAL_USER"
            log_success "添加成功！"
            log_warn "用户组更改需【重新登录SSH】才能生效。"
            log_warn "否则直接运行下一步骤可能出现Docker权限错误。"
        fi
    else
         log_info "检测到以 root 用户运行，无需添加到 docker 用户组。"
    fi

    echo -e "\n${CYAN}================ 1Panel 安装完成 ===================${NC}"
    log_warn "重要：需牢记已设置的 1Panel 访问地址、端口、账号和密码。"
    echo -e "并确保防火墙/安全组中 ${GREEN}已放行 1Panel 的端口${NC}。"
    echo -e "\n${BOLD}可重新运行本脚本，选择【2】进入应用部署中心，再选择【3】来部署 SillyTavern。${NC}"
    log_warn "若刚才有用户被添加到 docker 组，务必先退出并重新登录SSH！"
    read -rp "请记录好以上信息，按 Enter 键返回..." < /dev/tty
}

fn_get_public_ip() {
    local ip_services=(
        "https://ifconfig.me"
        "https://myip.ipip.net"
        "https://cip.cc"
        "https://api.ipify.org"
    )
    local ip=""

    log_info "正在尝试自动获取公网IP地址..." >&2
    
    for service in "${ip_services[@]}"; do
        echo -ne "  - 正在尝试: ${YELLOW}${service}${NC}..." >&2
        ip=$(curl -s -4 --max-time 5 "$service" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
        
        if [[ -n "$ip" ]]; then
            echo -e " ${GREEN}成功!${NC}" >&2
            echo "$ip"
            return 0
        else
            echo -e " ${RED}失败${NC}" >&2
        fi
    done

    echo >&2
    log_warn "未能自动获取到公网IP地址。" >&2
    log_info "这不影响部署结果，SillyTavern容器已成功在后台运行。" >&2
    
    echo "【请手动替换为你的服务器IP】"
    return 1
}

fn_generate_password() {
    local length=${1:-34}
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

install_sillytavern() {
    # 初始化变量供全局检查函数使用
    local DOCKER_VER="-" DOCKER_STATUS="-"
    local COMPOSE_VER="-" COMPOSE_STATUS="-"
    local DOCKER_COMPOSE_CMD=""
    local CONTAINER_NAME="sillytavern"
    local IMAGE_NAME="ghcr.io/sillytavern/sillytavern:latest"

    fn_check_existing_container() {
        if docker ps -a -q -f "name=^${CONTAINER_NAME}$" | grep -q .; then
            log_warn "检测到服务器上已存在一个名为 '${CONTAINER_NAME}' 的 Docker 容器。"
            log_info "这可能来自之前的安装。若要继续，必须先处理现有容器。"
            echo -e "请选择操作："
            echo -e "  [1] ${YELLOW}停止并移除现有容器，然后继续全新安装${NC}"
            echo -e "  [2] ${RED}退出脚本，由我手动处理${NC}"
            
            local choice=""
            while [[ "$choice" != "1" && "$choice" != "2" ]]; do
                read -p "请输入选项 [1 或 2]: " choice < /dev/tty
            done
            
            case "$choice" in
                1)
                    log_action "正在停止并移除现有容器 '${CONTAINER_NAME}'..."
                    docker stop "${CONTAINER_NAME}" > /dev/null 2>&1 || true
                    docker rm "${CONTAINER_NAME}" > /dev/null 2>&1 || true
                    log_success "现有容器已成功移除。"
                    ;;
                2)
                    log_info "操作已取消。请手动执行 'docker ps -a' 查看容器状态。"
                    return 1
                    ;;
            esac
        fi
    }


    fn_apply_config_changes() {
        sed -i '1i# ✦ 咕咕助手 · 作者：清绝 | 博客：https://blog.qjyg.de' "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true # 允许外部访问/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false # 关闭IP白名单模式/" "$CONFIG_FILE"
        sed -i -E "/^[[:space:]]*hostWhitelist:/,/^[[:space:]]*hosts:/{s/^([[:space:]]*)enabled: .*/\1enabled: true # 启用 Host 白名单/}" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)sessionTimeout: .*/\1sessionTimeout: 86400 # 24小时退出登录/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)lazyLoadCharacters: .*/\1lazyLoadCharacters: true # 懒加载、点击角色卡才加载/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)memoryCacheCapacity: .*/\1memoryCacheCapacity: '${ST_CACHE_MEM}mb' # 角色卡内存缓存/" "$CONFIG_FILE"
        if [[ "$run_mode" == "1" ]]; then
            local safe_user
            local safe_pass
            safe_user=$(fn_escape_sed_str "$single_user")
            safe_pass=$(fn_escape_sed_str "$single_pass")

            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # 启用基础认证/" "$CONFIG_FILE"
            sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)username:/{s/^([[:space:]]*)username: .*/\1username: \"$safe_user\"/}" "$CONFIG_FILE"
            sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)password:/{s/^([[:space:]]*)password: .*/\1password: \"$safe_pass\"/}" "$CONFIG_FILE"
        elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # 临时开启基础认证以设置管理员/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true # 启用多用户模式/" "$CONFIG_FILE"
        fi
    }




    
    fn_confirm_and_delete_dir() {
        local dir_to_delete="$1"
        local container_name="$2"
        log_warn "目录 '$dir_to_delete' 已存在，可能包含之前的聊天记录和角色卡。"
        read -r -p "确定要【彻底清理】并继续安装吗？此操作会停止并删除旧容器。[Y/n]: " c1 < /dev/tty
        if [[ ! "${c1:-y}" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。" || return 1; fi
        read -r -p "$(echo -e "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 [Y/n]: ${NC}")" c2 < /dev/tty
        if [[ ! "${c2:-y}" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。" || return 1; fi
        read -r -p "$(echo -e "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}")" c3 < /dev/tty
        if [[ "$c3" != "yes" ]]; then fn_print_error "操作被用户取消。" || return 1; fi
        fn_print_info "正在停止并移除旧容器: $container_name..."
        docker stop "$container_name" > /dev/null 2>&1 || true
        docker rm "$container_name" > /dev/null 2>&1 || true
        log_success "旧容器已停止并移除。"
        fn_print_info "正在删除旧目录: $dir_to_delete..."
        rm -rf "$dir_to_delete"
        log_success "旧目录已彻底清理。"
    }

    fn_create_project_structure() {
        fn_print_info "正在创建项目目录结构..."
        mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/third-party" "$INSTALL_DIR/config" "$INSTALL_DIR/.gugu"
        fn_print_info "正在设置文件所有权..."
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
        log_success "项目目录创建并授权成功！"
    }

    fn_create_git_sync_config() {
        fn_print_info "正在创建 Git 同步配置文件 (.gugu/git_sync.conf)..."
        mkdir -p "$INSTALL_DIR/.gugu"
        cat <<EOF > "$INSTALL_DIR/.gugu/git_sync.conf"
# ✦ 咕咕助手 · 作者：清绝 | 博客：https://blog.qjyg.de
REPO_URL="仓库"
REPO_TOKEN="令牌"
GIT_USER_NAME="用户名"
GIT_USER_EMAIL="邮箱"

# --- 可选项 (高级同步规则，不懂可不填) ---
# 是否同步 config.yaml 文件 (true / false)。默认为不同步。
SYNC_CONFIG_YAML=""

# 用户数据映射规则 ("本地用户名:云端用户名"，使用英文冒号分隔，默认用户名是 default-user)
USER_MAP=""
EOF
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR/.gugu"
        log_success "Git 同步配置文件创建成功！"
    }

    fn_pull_with_progress_bar() {
        local target_image="$1"
        
        log_info "正在拉取镜像: ${target_image} ..."
        if docker pull "$target_image"; then
            log_success "镜像拉取成功！"
        else
            fn_print_error "镜像拉取失败。请检查网络或镜像源。" || return 1
        fi
    }


    fn_check_and_explain_status() {
        local container_name="$1"
        echo -e "\n${YELLOW}--- 容器当前状态 ---${NC}"
        docker ps -a --filter "name=${container_name}"
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "未找到")
        echo -e "\n${CYAN}--- 状态解读 ---${NC}"
        case "$status" in
            running) log_success "状态正常：容器正在健康运行。";;
            restarting) log_warn "状态异常：容器正在无限重启。"; fn_print_info "通常意味着程序内部崩溃。请使用 [2] 查看日志定位错误。";;
            exited) echo -e "${RED}状态错误：容器已停止运行。${NC}"; fn_print_info "通常是由于启动时发生致命错误。请使用 [2] 查看日志获取错误信息。";;
            未找到) echo -e "${RED}未能找到名为 '${container_name}' 的容器。${NC}";;
            *) log_warn "状态未知：容器处于 '${status}' 状态。"; fn_print_info "建议使用 [2] 查看日志进行诊断。";;
        esac
    }

    fn_display_final_info() {
        echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "║                   ${BOLD}部署成功！尽情享受吧！${NC}                   ║"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:${ST_PORT}${NC}"
        
        if [[ "$run_mode" == "1" ]]; then
            echo -e "  ${CYAN}登录账号:${NC} ${YELLOW}${single_user}${NC}"
            echo -e "  ${CYAN}登录密码:${NC} ${YELLOW}${single_pass}${NC}"
        elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
            echo -e "  ${YELLOW}登录页面:${NC} ${GREEN}http://${SERVER_IP}:${ST_PORT}/login${NC}"
        fi
        
        echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
    }


    tput reset
    echo -e "${CYAN}SillyTavern Docker 自动化安装流程${NC}"

    fn_print_step "[ 1/5 ] 环境检查与准备"
    fn_check_base_deps
    
    TARGET_USER="${SUDO_USER:-root}"
    if [ "$TARGET_USER" = "root" ]; then
        log_warn "检测到以 root 用户运行，将安装在 /root 目录。"
    fi
    INSTALL_DIR="$USER_HOME/sillytavern"
    CONFIG_FILE="$INSTALL_DIR/config/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    
    fn_check_dependencies
    fn_check_existing_container
    fn_optimize_docker
    
    SERVER_IP=$(fn_get_public_ip)

    # 稳健型内存配置计算 (带 Min/Max 保护)
    local mem_total_mb
    mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$mem_total_mb" -le 2048 ]; then
        NODE_MAX_MEM=$((mem_total_mb * 70 / 100))
    else
        NODE_MAX_MEM=$((mem_total_mb * 80 / 100))
    fi

    # 边界保护：Node 堆内存下限 256MB，上限 4096MB
    [ "$NODE_MAX_MEM" -lt 256 ] && NODE_MAX_MEM=256
    [ "$NODE_MAX_MEM" -gt 4096 ] && NODE_MAX_MEM=4096

    # 酒馆内部缓存占堆内存的 1/3
    ST_CACHE_MEM=$((NODE_MAX_MEM * 33 / 100))
    
    # 边界保护：缓存下限 64MB，上限 1024MB
    [ "$ST_CACHE_MEM" -lt 64 ] && ST_CACHE_MEM=64
    [ "$ST_CACHE_MEM" -gt 1024 ] && ST_CACHE_MEM=1024

    fn_print_step "[ 2/5 ] 选择运行模式与路径"

    while true; do
        echo "选择运行模式："
        echo -e "  [1] ${CYAN}单用户模式${NC} (弹窗认证，适合个人使用)"
        echo -e "  [2] ${CYAN}多用户模式${NC} (独立登录页，适合多人或单人使用)"
        read -p "请输入选项数字 [默认为 1]: " run_mode < /dev/tty
        run_mode=${run_mode:-1}
        [[ "$run_mode" =~ ^[12]$ ]] && break
        log_warn "无效选项，请重新选择。"
    done

    case "$run_mode" in
        1)
            read -p "请输入自定义用户名: " single_user < /dev/tty
            while true; do
                read -p "请输入自定义密码: " single_pass < /dev/tty
                if [ -z "$single_pass" ]; then
                    log_warn "密码不能为空。"
                elif ! fn_check_password_safe "$single_pass"; then
                    log_warn "密码中包含不支持的特殊字符 (\\ / \" &)，请使用纯数字、字母或常规符号。"
                else
                    break
                fi
            done
            if [ -z "$single_user" ]; then fn_print_error "用户名不能为空！"; fi
            ;;
        2)
            ;;
        *)
            fn_print_error "无效输入。" || return 1
            ;;
    esac

    local default_parent_path="$USER_HOME"
    read -rp "安装路径: SillyTavern 将被安装在 <上级目录>/sillytavern 中。请输入上级目录 [直接回车=默认: $USER_HOME]:" custom_parent_path < /dev/tty
    local parent_path="${custom_parent_path:-$default_parent_path}"
    INSTALL_DIR="${parent_path}/sillytavern"
    log_info "安装路径最终设置为: ${INSTALL_DIR}"

    fn_prompt_port_in_range ST_PORT "请输入酒馆访问端口 (1-65535) [默认 8000]: " "8000" 1 65535

    CONFIG_FILE="$INSTALL_DIR/config/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

    fn_print_step "[ 3/5 ] 创建项目文件"
    if [ -d "$INSTALL_DIR" ]; then
        fn_confirm_and_delete_dir "$INSTALL_DIR" "$CONTAINER_NAME"
    fi

    fn_create_project_structure

    fn_create_git_sync_config

    cd "$INSTALL_DIR"
    fn_print_info "工作目录已切换至: $(pwd)"

    cat <<EOF > "$COMPOSE_FILE"
services:
  sillytavern:
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    image: ${IMAGE_NAME}
    security_opt:
      - apparmor:unconfined
    environment:
      - NODE_ENV=production
      - FORCE_COLOR=1
      - NODE_OPTIONS=--max-old-space-size=${NODE_MAX_MEM}
    ports:
      - "${ST_PORT}:8000"
    volumes:
      - "./config:/home/node/app/config:z"
      - "./data:/home/node/app/data:z"
      - "./plugins:/home/node/app/plugins:z"
      - "./third-party:/home/node/app/public/scripts/extensions/third-party:z"
    restart: unless-stopped
EOF
    log_success "docker-compose.yml 文件创建成功！"

    fn_print_step "[ 4/5 ] 初始化与配置"
    if [ -n "$CUSTOM_PROXY_IMAGE" ]; then
        log_action "检测到代理镜像，正在执行 Pull & Tag 流程..."
        fn_pull_with_progress_bar "$CUSTOM_PROXY_IMAGE"
        log_info "正在重打标签: ${CUSTOM_PROXY_IMAGE} -> ${IMAGE_NAME}"
        docker tag "$CUSTOM_PROXY_IMAGE" "$IMAGE_NAME"
        log_success "代理镜像已就绪。"
    else
        fn_pull_with_progress_bar "$IMAGE_NAME"
    fi

    fn_print_info "正在进行首次启动以生成官方配置文件..."
    if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null 2>&1; then
        fn_print_error "首次启动容器失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)" || return 1
    fi
    local timeout=60
    while [ ! -f "$CONFIG_FILE" ]; do
        if [ $timeout -eq 0 ]; then
            fn_print_error "等待配置文件生成超时！请检查日志输出：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)" || return 1
        fi
        sleep 1
        ((timeout--))
    done
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" down > /dev/null 2>&1
    log_success "config.yaml 文件已生成！"
    
    fn_apply_config_changes
    if [[ "$run_mode" == "1" ]]; then
        log_success "单用户模式配置写入完成！"
    else
        fn_print_info "正在临时启动服务以设置管理员..."
        if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null 2>&1; then
            fn_print_error "临时启动容器以设置管理员失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)" || return 1
        fi
        fn_verify_container_health "$CONTAINER_NAME"
        fn_wait_for_service
        MULTI_USER_GUIDE=$(cat <<EOF

${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}
1. ${CYAN}【开放端口】${NC}
   需确保服务器后台（如阿里云/腾讯云安全组）已开放 ${GREEN}${ST_PORT}${NC} 端口。
2. ${CYAN}【访问并登录】${NC}
   打开浏览器，访问: ${GREEN}http://${SERVER_IP}:${ST_PORT}${NC}
   使用以下默认凭据登录：
     ▶ 账号: ${YELLOW}user${NC}
     ▶ 密码: ${YELLOW}password${NC}
3. ${CYAN}【设置管理员】${NC}
   登录后，立即在【用户设置】标签页的【管理员面板】中操作：
   A. ${GREEN}设置密码${NC}：为默认账户 \`default-user\` 设置一个强大的新密码。
   B. ${GREEN}创建新账户 (推荐)${NC}：
      ① 点击“新用户”。
      ② 自定义日常使用的账号和密码（建议账号用纯英文或纯数字）。
      ③ 创建后，点击新账户旁的【↑】箭头，将其身份提升为 Admin (管理员)。
${YELLOW}>>> 完成以上所有步骤后，回到本窗口按【回车键】继续 <<<${NC}
EOF
)
        echo -e "${MULTI_USER_GUIDE}"
        read -p "" < /dev/tty
        fn_print_info "正在切换到多用户登录页模式..."
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false # 关闭基础认证，启用登录页/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)enableDiscreetLogin: .*/\1enableDiscreetLogin: true # 隐藏登录用户列表/" "$CONFIG_FILE"
        log_success "多用户模式配置写入完成！"
    fi

    fn_print_step "[ 5/5 ] 启动并验证服务"
    fn_print_info "正在应用最终配置并重启服务..."
    if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate > /dev/null 2>&1; then
        fn_print_error "应用最终配置并启动服务失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)" || return 1
    fi
    fn_verify_container_health "$CONTAINER_NAME"
    fn_wait_for_service

    fn_display_final_info

    while true; do
        echo -e "\n${CYAN}--- 部署后操作 ---${NC}"
        echo -e "  [1] 查看容器状态"
        echo -e "  [2] 查看日志 ${YELLOW}(按 Ctrl+C 停止)${NC}"
        echo -e "  [3] 重新显示访问信息"
        echo -e "  [q] 退出此菜单"
        read -p "请输入选项: " choice < /dev/tty
        [[ -z "$choice" ]] && continue
        case "$choice" in
            1) fn_check_and_explain_status "$CONTAINER_NAME";;
            2)
                echo -e "\n${YELLOW}--- 实时日志 (按 Ctrl+C 停止) ---${NC}"
                trap : INT
                docker logs -f "$CONTAINER_NAME" || true
                trap 'exit 0' INT
                ;;
            3) fn_display_final_info;;
            q|Q) echo -e "\n已退出部署后菜单。"; break;;
            *) log_warn "无效输入，请输入 1, 2, 3 或 q。";;
        esac
    done
}

install_gcli2api() {
    # 初始化变量供全局检查函数使用
    local DOCKER_VER="-" DOCKER_STATUS="-"
    local COMPOSE_VER="-" COMPOSE_STATUS="-"
    local DOCKER_COMPOSE_CMD=""
    local CONTAINER_NAME="gcli2api"
    local IMAGE_NAME="ghcr.io/su-kaka/gcli2api:latest"
    
    tput reset
    echo -e "${CYAN}gcli2api Docker 自动化安装流程${NC}"
    
    fn_check_base_deps
    fn_check_dependencies
    
    fn_confirm_remove_existing_container "$CONTAINER_NAME" || return 1

    local default_parent_path="${USER_HOME}"
    read -rp "安装路径: gcli2api 将被安装在 <上级目录>/gcli2api 中。请输入上级目录 [直接回车=默认: $USER_HOME]:" custom_parent_path < /dev/tty
    local parent_path="${custom_parent_path:-$default_parent_path}"
    local INSTALL_DIR="${parent_path}/gcli2api"
    
    fn_prompt_port_in_range GCLI_PORT "请输入访问端口 (1-65535) [默认 7861]: " "7861" 1 65535

    local random_pwd=$(fn_generate_password 34)
    read -rp "请输入管理密码 [直接回车=随机生成]: " GCLI_PWD < /dev/tty
    GCLI_PWD=${GCLI_PWD:-$random_pwd}

    log_action "正在创建目录结构..."
    mkdir -p "$INSTALL_DIR/data/creds"
    
    log_action "正在生成 docker-compose.yml..."
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
# ✦ 咕咕助手 · 作者：清绝 | 博客：https://blog.qjyg.de
services:
  gcli2api:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${GCLI_PORT}:7861"
    environment:
      - PASSWORD=${GCLI_PWD}
      - PORT=7861
    volumes:
      - ./data/creds:/app/creds
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import sys, urllib.request, os; port = os.environ.get('PORT', '7861'); req = urllib.request.Request(f'http://localhost:{port}/v1/models', headers={'Authorization': 'Bearer ' + os.environ.get('PASSWORD', 'pwd')}); sys.exit(0 if urllib.request.urlopen(req, timeout=5).getcode() == 200 else 1)\""]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF

    log_action "正在启动服务..."
    cd "$INSTALL_DIR" && $DOCKER_COMPOSE_CMD up -d
    
    fn_verify_container_health "$CONTAINER_NAME"
    
    local SERVER_IP=$(fn_get_public_ip)
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "║                   ${BOLD}gcli2api 部署成功！${NC}                      ║"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:${GCLI_PORT}${NC}"
    echo -e "  ${CYAN}管理密码:${NC} ${YELLOW}${GCLI_PWD}${NC}"
    echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
}

fn_write_ais_official_env() {
    local env_file="$1"
    local api_keys="$2"

    cat <<EOF > "$env_file"
# ===================================
# Server Configuration
# ===================================
PORT=7860
HOST=0.0.0.0
WS_PORT=9998

# ===================================
# Authentication Configuration
# ===================================
API_KEYS=${api_keys}

# ===================================
# Security Configuration
# ===================================
SECURE_COOKIES=false
RATE_LIMIT_MAX_ATTEMPTS=5
RATE_LIMIT_WINDOW_MINUTES=15
INITIAL_AUTH_INDEX=0

# ===================================
# UI Configuration
# ===================================
ICON_URL=
CHECK_UPDATE=true

# ===================================
# Browser Configuration
# ===================================
CAMOUFOX_EXECUTABLE_PATH=
TARGET_DOMAIN=

# ===================================
# Request Handling Configuration
# ===================================
STREAMING_MODE=real
MAX_RETRIES=3
RETRY_DELAY=2000
FORCE_THINKING=false
FORCE_WEB_SEARCH=false
FORCE_URL_CONTEXT=false

# ===================================
# Account Switching Configuration
# ===================================
SWITCH_ON_USES=40
FAILURE_THRESHOLD=3
IMMEDIATE_SWITCH_STATUS_CODES=429,503

# ===================================
# Timezone Configuration
# ===================================
TZ=

# ===================================
# Proxy Configuration
# ===================================
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=
EOF
}

fn_migrate_ais2api_to_ibuhub() {
    local project_dir="$1"
    local compose_file="$2"
    local compose_cmd="$3"
    local container_name="${4:-ais2api}"
    local env_file="${project_dir}/app.env"

    if [ ! -d "$project_dir" ] || [ ! -f "$compose_file" ]; then
        log_error "未找到 ais2api 项目目录或 docker-compose.yml。" || return 1
    fi

    local current_image=""
    if docker ps -a --format '{{.Names}}' | grep -qx "$container_name"; then
        current_image=$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)
    fi
    if [ -z "$current_image" ] && [ -f "$compose_file" ]; then
        current_image=$(grep -E '^[[:space:]]*image:[[:space:]]*' "$compose_file" | head -n 1 | awk '{print $2}')
    fi
    if [ -z "$current_image" ]; then
        log_error "未能获取当前 ais2api 镜像信息，请确认项目配置是否完整。" || return 1
    fi

    if [[ "$current_image" != ${AIS2API_OLD_IMAGE_REPO}* ]]; then
        if [[ "$current_image" == ${AIS2API_NEW_IMAGE_REPO}* ]]; then
            log_success "当前已使用新镜像 (${current_image})，无需迁移。"
            return 0
        fi
        log_warn "当前镜像为 ${current_image}，不属于旧镜像 ${AIS2API_OLD_IMAGE_REPO}，已跳过迁移。"
        return 1
    fi

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local compose_bak="${compose_file}.bak_${ts}"
    cp -f "$compose_file" "$compose_bak"
    log_info "已备份 compose 文件: ${compose_bak}"

    local old_api_keys=""
    if [ -f "$env_file" ]; then
        local env_bak="${env_file}.bak_${ts}"
        cp -f "$env_file" "$env_bak"
        log_info "已备份环境文件: ${env_bak}"
        old_api_keys=$(grep -E '^API_KEYS=' "$env_file" | tail -n 1 | cut -d= -f2-)
    fi

    mkdir -p "${project_dir}/auth"

    log_action "正在写入新镜像官方 app.env 配置..."
    fn_write_ais_official_env "$env_file" "$old_api_keys"

    log_action "正在更新 docker-compose.yml..."
    sed -i -E "0,/^[[:space:]]*image:[[:space:]]*/s|^[[:space:]]*image:[[:space:]].*|    image: ${AIS2API_NEW_IMAGE}|" "$compose_file"
    sed -i -E 's#(\./auth:/app/)auth#\1configs/auth#g' "$compose_file"

    if ! grep -q "/app/configs/auth" "$compose_file"; then
        if grep -q "^[[:space:]]*volumes:[[:space:]]*$" "$compose_file"; then
            sed -i -E '0,/^[[:space:]]*volumes:[[:space:]]*$/s|^[[:space:]]*volumes:[[:space:]]*$|    volumes:\n      - ./auth:/app/configs/auth|' "$compose_file"
        else
            sed -i -E '0,/^[[:space:]]*-[[:space:]]*app\.env[[:space:]]*$/s|^[[:space:]]*-[[:space:]]*app\.env[[:space:]]*$|      - app.env\n    volumes:\n      - ./auth:/app/configs/auth|' "$compose_file"
        fi
    fi

    log_action "正在拉取新镜像并重建服务..."
    if ! (cd "$project_dir" && $compose_cmd pull && $compose_cmd up -d --force-recreate); then
        log_error "迁移失败：重建服务未成功，请检查日志。" || return 1
    fi

    local health_container="$container_name"
    if ! docker ps -a --format '{{.Names}}' | grep -qx "$health_container"; then
        health_container=$(grep -E '^[[:space:]]*container_name:[[:space:]]*' "$compose_file" | head -n 1 | awk '{print $2}')
    fi
    health_container="${health_container:-ais2api}"
    fn_verify_container_health "$health_container"

    log_action "正在清理旧镜像..."
    if docker rmi "$current_image" >/dev/null 2>&1 || docker rmi "$AIS2API_OLD_IMAGE" >/dev/null 2>&1; then
        log_success "旧镜像清理完成。"
    else
        log_warn "旧镜像删除失败（可能被占用或不存在），请按需手动清理。"
    fi

    log_success "ais2api 已完成迁移到新镜像：${AIS2API_NEW_IMAGE}"
    return 0
}

install_ais2api() {
    # 初始化变量供全局检查函数使用
    local DOCKER_VER="-" DOCKER_STATUS="-"
    local COMPOSE_VER="-" COMPOSE_STATUS="-"
    local DOCKER_COMPOSE_CMD=""
    local CONTAINER_NAME="ais2api"
    local IMAGE_NAME="$AIS2API_NEW_IMAGE"
    
    tput reset
    echo -e "${CYAN}ais2api Docker 自动化安装流程${NC}"
    
    fn_check_base_deps
    fn_check_dependencies
    
    fn_confirm_remove_existing_container "$CONTAINER_NAME" || return 1

    local default_parent_path="${USER_HOME}"
    read -rp "安装路径: ais2api 将被安装在 <上级目录>/ais2api 中。请输入上级目录 [直接回车=默认: $USER_HOME]:" custom_parent_path < /dev/tty
    local parent_path="${custom_parent_path:-$default_parent_path}"
    local INSTALL_DIR="${parent_path}/ais2api"
    
    fn_prompt_port_in_range AIS_PORT "请输入访问端口 (1-65535) [默认 8889]: " "8889" 1 65535

    local random_key=$(fn_generate_password 34)
    read -rp "请输入 API Key [直接回车=随机生成]: " AIS_KEY < /dev/tty
    AIS_KEY=${AIS_KEY:-$random_key}

    log_action "正在创建目录结构..."
    mkdir -p "$INSTALL_DIR/auth"
    log_info "新镜像支持在 Web 面板中进行认证配置，无需预先放入认证文件。"
    
    log_action "正在生成 app.env..."
    fn_write_ais_official_env "$INSTALL_DIR/app.env" "$AIS_KEY"

    log_action "正在生成 docker-compose.yml..."
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
services:
  ais2api:
    container_name: ${CONTAINER_NAME}
    image: ${IMAGE_NAME}
    ports:
      - "${AIS_PORT}:7860"
    env_file:
      - app.env
    volumes:
      - ./auth:/app/configs/auth
    restart: unless-stopped
EOF

    log_action "正在启动服务..."
    cd "$INSTALL_DIR" && $DOCKER_COMPOSE_CMD up -d
    
    fn_verify_container_health "$CONTAINER_NAME"
    
    local SERVER_IP=$(fn_get_public_ip)
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "║                   ${BOLD}ais2api 部署成功！${NC}                       ║"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:${AIS_PORT}${NC}"
    echo -e "  ${CYAN}API Key:${NC} ${YELLOW}${AIS_KEY}${NC}"
    echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
}

install_warp() {
    local DOCKER_VER="-" DOCKER_STATUS="-"
    local COMPOSE_VER="-" COMPOSE_STATUS="-"
    local DOCKER_COMPOSE_CMD=""
    local CONTAINER_NAME="warp"
    local IMAGE_NAME="caomingjun/warp"

    tput reset
    echo -e "${CYAN}Warp-Docker 自动化安装流程${NC}"

    fn_check_base_deps
    fn_check_dependencies

    fn_confirm_remove_existing_container "$CONTAINER_NAME" || return 1

    local default_parent_path="${USER_HOME}"
    read -rp "安装路径: Warp 将被安装在 <上级目录>/warp 中。请输入上级目录 [直接回车=默认: $USER_HOME]:" custom_parent_path < /dev/tty
    local parent_path="${custom_parent_path:-$default_parent_path}"
    local INSTALL_DIR="${parent_path}/warp"

    fn_prompt_port_in_range WARP_PORT "请输入 Warp 代理映射到宿主机的端口 (1-65535) [默认 1080]: " "1080" 1 65535

    log_action "正在创建目录结构..."
    mkdir -p "$INSTALL_DIR/data"

    log_action "正在创建 Docker 网络 'warp'..."
    docker network create warp >/dev/null 2>&1 || true

    log_action "正在生成 docker-compose.yml..."
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
# ✦ 咕咕助手 · 作者：清绝 | 博客：https://blog.qjyg.de
networks:
  warp:
    external: true
services:
  warp:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: always
    environment:
      - WARP_SLEEP=2
      - WARP_PROXY=0.0.0.0:1080
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./data:/var/lib/cloudflare-warp
    ports:
      - "127.0.0.1:${WARP_PORT}:1080"
    networks:
      - warp
EOF

    log_action "正在启动服务..."
    cd "$INSTALL_DIR" && $DOCKER_COMPOSE_CMD up -d

    fn_verify_container_health "$CONTAINER_NAME"

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "║                   ${BOLD}Warp 部署成功！${NC}                          ║"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${CYAN}代理访问地址 (容器间):${NC}"
    echo -e "    HTTP:   ${GREEN}http://warp:1080${NC}"
    echo -e "    SOCKS5: ${GREEN}socks5://warp:1080${NC}"
    echo -e "\n  ${CYAN}代理访问地址 (宿主机):${NC}"
    echo -e "    HTTP:   ${GREEN}http://127.0.0.1:${WARP_PORT}${NC}"
    echo -e "    SOCKS5: ${GREEN}socks5://127.0.0.1:${WARP_PORT}${NC}"
    echo -e "\n  ${CYAN}代理访问地址 (Docker网桥):${NC}"
    echo -e "    HTTP:   ${GREEN}http://172.17.0.1:${WARP_PORT}${NC}"
    echo -e "    SOCKS5: ${GREEN}socks5://172.17.0.1:${WARP_PORT}${NC}"
    echo -e "\n  ${CYAN}项目路径:${NC} $INSTALL_DIR"
}

fn_test_scripts_menu() {
    # 清理输入缓冲区
    while read -r -t 0.1; do :; done
    
    local test_choice
    while true; do
        tput reset
        echo -e "${BLUE}=== 常驻测试脚本 ===${NC}"
        echo -e "  [1] Region 流媒体解锁测试"
        echo -e "  [2] NodeQuality 综合测试"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " test_choice < /dev/tty
        case "$test_choice" in
            1)
                log_action "正在运行流媒体解锁测试..."
                bash <(curl -L -s check.unlock.media)
                read -rp "测试完成，按 Enter 继续..." < /dev/tty
                ;;
            2)
                log_action "正在运行 NodeQuality 综合测试..."
                bash <(curl -sL https://run.NodeQuality.com)
                read -rp "测试完成，按 Enter 继续..." < /dev/tty
                ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

fn_test_llm_api() {
    while true; do
        tput reset
        echo -e "${BLUE}=== API 接口连通性测试 ===${NC}"
        echo -e "  [1] 测试 Gemini API"
        echo -e "  [2] 测试 OpenAI API (自定义)"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " api_test_choice < /dev/tty
        case "$api_test_choice" in
            1)
                echo -e "\n${CYAN}--- Gemini API 测试 ---${NC}"
                read -rp "请输入 Gemini API KEY: " GEMINI_KEY < /dev/tty
                if [ -z "$GEMINI_KEY" ]; then log_warn "API KEY 不能为空"; sleep 1; continue; fi
                
                log_info "1. 正在测试 API 连通性 (拉取模型列表)..."
                curl -s -H 'Content-Type: application/json' \
                     -X GET "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_KEY}" | head -n 20
                
                echo -e "\n"
                read -rp "请输入测试模型名称 [默认: gemini-2.5-flash]: " GEMINI_MODEL < /dev/tty
                GEMINI_MODEL=${GEMINI_MODEL:-"gemini-2.5-flash"}
                
                log_info "2. 正在测试聊天补全功能 (${GEMINI_MODEL})..."
                curl -s -H 'Content-Type: application/json' \
                     -d "{\"contents\":[{\"parts\":[{\"text\":\"你好，讲个一句话笑话！\"}]}]}" \
                     "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}"
                
                echo -e "\n"
                read -rp "测试完成，按 Enter 继续..." < /dev/tty
                ;;
            2)
                echo -e "\n${CYAN}--- OpenAI API 测试 ---${NC}"
                read -rp "请输入 API BASE [例如: https://api.openai.com/v1]: " OPENAI_BASE < /dev/tty
                read -rp "请输入 API KEY: " OPENAI_KEY < /dev/tty
                if [ -z "$OPENAI_BASE" ] || [ -z "$OPENAI_KEY" ]; then log_warn "BASE 或 KEY 不能为空"; sleep 1; continue; fi
                
                # 确保 BASE 不以 / 结尾
                OPENAI_BASE=${OPENAI_BASE%/}
                
                log_info "1. 正在测试 API 连通性 (拉取模型列表)..."
                curl -s "$OPENAI_BASE/models" \
                  -H "Authorization: Bearer $OPENAI_KEY" | head -n 20
                
                echo -e "\n"
                read -rp "请输入测试模型名称 [默认: gemini-2.5-flash]: " OPENAI_MODEL < /dev/tty
                OPENAI_MODEL=${OPENAI_MODEL:-"gemini-2.5-flash"}
                
                log_info "2. 正在测试聊天补全功能 (${OPENAI_MODEL})..."
                curl -s "$OPENAI_BASE/chat/completions" \
                  -H "Content-Type: application/json" \
                  -H "Authorization: Bearer $OPENAI_KEY" \
                  -d "{
                    \"model\": \"$OPENAI_MODEL\",
                    \"messages\": [{\"role\": \"user\", \"content\": \"你好，讲个一句话笑话！\"}],
                    \"stream\": false
                  }"
                
                echo -e "\n"
                read -rp "测试完成，按 Enter 继续..." < /dev/tty
                ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# --- [酒馆 Host 白名单辅助函数] ---
fn_st_validate_host_entry() {
    local host="$1"

    # 去除首尾引号，兼容误输入
    host="${host#\"}"
    host="${host%\"}"
    host="${host#\'}"
    host="${host%\'}"

    # 禁止协议、路径、端口、IP 与 localhost
    if [[ -z "$host" || "$host" =~ :// || "$host" == */* || "$host" == *:* ]]; then
        return 1
    fi
    if [[ "$host" == "localhost" || "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # 普通域名：test.com
    if [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
        return 0
    fi
    # 子域匹配：.test.com（前导点）
    if [[ "$host" =~ ^\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
        return 0
    fi

    return 1
}

fn_st_get_host_whitelist_enabled() {
    local config_file="$1"
    awk '
        /^[[:space:]]*hostWhitelist:[[:space:]]*$/ { in_block=1; next }
        in_block && /^[[:space:]]*enabled:[[:space:]]*/ {
            if ($0 ~ /true/) print "true"; else print "false";
            found=1; exit
        }
        in_block && /^[^[:space:]]/ { in_block=0 }
        END { if (!found) print "false" }
    ' "$config_file"
}

fn_st_load_host_whitelist_hosts() {
    local config_file="$1"
    ST_HOSTS=()

    local parsed=""
    parsed=$(awk '
        /^[[:space:]]*hostWhitelist:[[:space:]]*$/ { in_block=1; next }
        in_block && /^[^[:space:]]/ { in_block=0 }
        in_block && /^[[:space:]]*hosts:[[:space:]]*\[/ {
            line=$0
            sub(/^[[:space:]]*hosts:[[:space:]]*\[/, "", line)
            sub(/\][[:space:]]*$/, "", line)
            gsub(/"/, "", line)
            gsub(/\047/, "", line)
            n=split(line, arr, ",")
            for (i=1; i<=n; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", arr[i])
                if (arr[i] != "") print arr[i]
            }
        }
        in_block && /^[[:space:]]*-[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            gsub(/\047/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line != "") print line
        }
    ' "$config_file")

    if [ -n "$parsed" ]; then
        while IFS= read -r host; do
            [ -n "$host" ] && ST_HOSTS+=("$host")
        done <<< "$parsed"
    fi
}

fn_st_build_hosts_inline() {
    if [ ${#ST_HOSTS[@]} -eq 0 ]; then
        echo "[]"
        return
    fi

    local out="["
    local h
    for h in "${ST_HOSTS[@]}"; do
        h="${h//\\/\\\\}"
        h="${h//\"/\\\"}"
        out+="\"$h\", "
    done
    out="${out%, }]"
    echo "$out"
}

fn_st_write_host_whitelist_config() {
    local config_file="$1"
    local hosts_inline="$2"
    local tmp_file
    tmp_file=$(mktemp)

    awk -v hosts_inline="$hosts_inline" '
        BEGIN {
            in_block=0
            block_found=0
            enabled_found=0
            hosts_found=0
        }
        {
            if ($0 ~ /^[[:space:]]*hostWhitelist:[[:space:]]*$/) {
                in_block=1
                block_found=1
                enabled_found=0
                hosts_found=0
                print
                next
            }

            if (in_block && $0 ~ /^[^[:space:]]/) {
                if (!enabled_found) print "  enabled: true"
                if (!hosts_found) print "  hosts: " hosts_inline
                in_block=0
            }

            if (in_block) {
                if ($0 ~ /^[[:space:]]*enabled:[[:space:]]*/) {
                    print "  enabled: true"
                    enabled_found=1
                    next
                }
                if ($0 ~ /^[[:space:]]*hosts:[[:space:]]*/) {
                    print "  hosts: " hosts_inline
                    hosts_found=1
                    next
                }
                # 清理旧的多行 hosts 列表项，防止残留
                if (hosts_found && $0 ~ /^[[:space:]]*-[[:space:]]+/) {
                    next
                }
            }

            print
        }
        END {
            if (in_block) {
                if (!enabled_found) print "  enabled: true"
                if (!hosts_found) print "  hosts: " hosts_inline
            }

            if (!block_found) {
                print ""
                print "# Host whitelist configuration. Recommended if you are using a listen mode"
                print "hostWhitelist:"
                print "  enabled: true"
                print "  scan: true"
                print "  hosts: " hosts_inline
            }
        }
    ' "$config_file" > "$tmp_file"

    if [ $? -ne 0 ]; then
        rm -f "$tmp_file"
        log_error "写入 Host 白名单配置失败。"
        return 1
    fi

    mv "$tmp_file" "$config_file"
}

fn_st_host_whitelist_manager() {
    local project_dir="$1"
    local config_file="$2"
    local compose_cmd="$3"

    while true; do
        fn_st_load_host_whitelist_hosts "$config_file"
        local current_enabled
        current_enabled=$(fn_st_get_host_whitelist_enabled "$config_file")

        tput reset
        echo -e "${BLUE}=== 酒馆 Host 白名单管理 ===${NC}"
        echo -e "状态: $( [[ "$current_enabled" == "true" ]] && echo -e "${GREEN}已启用${NC}" || echo -e "${YELLOW}未启用${NC}" )"
        echo -e "${YELLOW}安全提醒：Host 白名单属于关键安全防护，必须保持开启。${NC}"
        echo -e "填写方式："
        echo -e "  1) 只放行一个域名：填写 ${CYAN}test.com${NC}"
        echo -e "  2) 放行该域名下所有子域：填写 ${CYAN}.test.com${NC}（前面有一个点）"
        echo -e "  3) 多个域名可用空格、英文逗号或中文逗号分隔"
        echo -e "  4) 不要填写网址前缀、端口、路径或 IP"
        echo -e "------------------------"
        if [ ${#ST_HOSTS[@]} -eq 0 ]; then
            echo -e "当前白名单域名: ${YELLOW}(空)${NC}"
        else
            echo -e "当前白名单域名:"
            local i=1
            local host_item
            for host_item in "${ST_HOSTS[@]}"; do
                echo -e "  [$i] ${CYAN}${host_item}${NC}"
                ((i++))
            done
        fi
        echo -e "------------------------"
        echo -e "  [1] 添加域名 (支持多个，空格/逗号分隔)"
        echo -e "  [2] 删除指定域名 (按编号)"
        echo -e "  [3] 清空全部域名"
        echo -e "  [4] 重新开启白名单防护（安全必须开启）"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " host_choice < /dev/tty
        [[ -z "$host_choice" ]] && continue

        case "$host_choice" in
            1)
                read -rp "请输入要放行的域名（可多个）: " host_input < /dev/tty
                if [ -z "$host_input" ]; then
                    log_warn "输入为空，已取消。"
                    sleep 1
                    continue
                fi

                local normalized_input
                normalized_input=$(echo "$host_input" | tr ',，;；、' '     ')
                read -ra host_candidates <<< "$normalized_input"

                local added_count=0
                local invalid_hosts=()
                local candidate
                for candidate in "${host_candidates[@]}"; do
                    candidate=$(echo "$candidate" | xargs)
                    candidate="${candidate#\"}"
                    candidate="${candidate%\"}"
                    candidate="${candidate#\'}"
                    candidate="${candidate%\'}"
                    candidate=${candidate,,}
                    [ -z "$candidate" ] && continue

                    if ! fn_st_validate_host_entry "$candidate"; then
                        invalid_hosts+=("$candidate")
                        continue
                    fi

                    local exists=false
                    local existing
                    for existing in "${ST_HOSTS[@]}"; do
                        if [ "$existing" = "$candidate" ]; then
                            exists=true
                            break
                        fi
                    done
                    if [ "$exists" = false ]; then
                        ST_HOSTS+=("$candidate")
                        ((added_count++))
                    fi
                done

                if [ $added_count -eq 0 ] && [ ${#invalid_hosts[@]} -eq 0 ]; then
                    log_warn "没有可新增的域名（可能全部重复）。"
                    sleep 1
                    continue
                fi

                local hosts_inline
                hosts_inline=$(fn_st_build_hosts_inline)
                fn_st_write_host_whitelist_config "$config_file" "$hosts_inline" || { sleep 2; continue; }
                log_info "正在重启酒馆以应用白名单配置..."
                cd "$project_dir" && $compose_cmd restart
                log_success "已更新白名单配置。"
                if [ ${#invalid_hosts[@]} -gt 0 ]; then
                    log_warn "以下内容未识别为有效域名，已跳过: ${invalid_hosts[*]}"
                    log_info "提示：子域匹配请写成 .test.com（前面带点），且不要填写协议、端口或路径。"
                fi
                sleep 2
                ;;
            2)
                if [ ${#ST_HOSTS[@]} -eq 0 ]; then
                    log_warn "当前无可删除域名。"
                    sleep 1
                    continue
                fi

                read -rp "请输入要删除的编号: " del_index < /dev/tty
                if [[ ! "$del_index" =~ ^[0-9]+$ ]] || [ "$del_index" -lt 1 ] || [ "$del_index" -gt ${#ST_HOSTS[@]} ]; then
                    log_warn "编号无效。"
                    sleep 1
                    continue
                fi

                unset 'ST_HOSTS[del_index-1]'
                ST_HOSTS=("${ST_HOSTS[@]}")

                local hosts_inline
                hosts_inline=$(fn_st_build_hosts_inline)
                fn_st_write_host_whitelist_config "$config_file" "$hosts_inline" || { sleep 2; continue; }
                log_info "正在重启酒馆以应用白名单配置..."
                cd "$project_dir" && $compose_cmd restart
                log_success "域名已删除。"
                sleep 2
                ;;
            3)
                read -rp "确认清空全部白名单域名？[y/N]: " confirm_clear < /dev/tty
                if [[ ! "$confirm_clear" =~ ^[Yy]$ ]]; then
                    log_info "操作已取消。"
                    sleep 1
                    continue
                fi

                ST_HOSTS=()
                fn_st_write_host_whitelist_config "$config_file" "[]" || { sleep 2; continue; }
                log_info "正在重启酒馆以应用白名单配置..."
                cd "$project_dir" && $compose_cmd restart
                log_success "白名单域名已清空。"
                sleep 2
                ;;
            4)
                local hosts_inline
                hosts_inline=$(fn_st_build_hosts_inline)
                fn_st_write_host_whitelist_config "$config_file" "$hosts_inline" || { sleep 2; continue; }
                log_info "正在重启酒馆以应用白名单配置..."
                cd "$project_dir" && $compose_cmd restart
                log_success "白名单防护已开启。"
                sleep 2
                ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# --- [酒馆运维辅助函数] ---
fn_st_proxy_manager() {
    local project_dir=$1
    local config_file=$2
    local compose_file=$3
    local compose_cmd=$4

    while true; do
        tput reset
        echo -e "${BLUE}=== 酒馆代理配置管理 ===${NC}"
        local proxy_enabled=$(grep -A 5 "requestProxy:" "$config_file" | grep "enabled:" | head -n 1 | awk '{print $2}')
        local proxy_url=$(grep -A 5 "requestProxy:" "$config_file" | grep "url:" | head -n 1 | cut -d'"' -f2)
        
        echo -e "当前状态: $( [[ "$proxy_enabled" == "true" ]] && echo -e "${GREEN}已启用${NC}" || echo -e "${RED}已禁用${NC}" )"
        echo -e "当前代理: ${CYAN}${proxy_url:-未配置}${NC}"
        echo -e "------------------------"
        echo -e "  [1] 自动配置 Warp 代理 (warp:1080)"
        echo -e "  [2] 手动配置自定义代理"
        echo -e "  [3] 禁用并删除代理配置"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " proxy_choice < /dev/tty
        [[ -z "$proxy_choice" ]] && continue
        
        case "$proxy_choice" in
            1)
                log_action "正在检查 Warp 环境..."
                if ! docker ps -a --format '{{.Names}}' | grep -q '^warp$'; then
                    log_warn "未检测到 Warp 容器。"
                    read -rp "是否立即安装 Warp？[Y/n]: " confirm_warp < /dev/tty
                    if [[ "${confirm_warp:-y}" =~ ^[Yy]$ ]]; then
                        install_warp || continue
                    else
                        continue
                    fi
                fi
                
                log_action "正在配置酒馆代理为 Warp..."
                # 仅在 requestProxy 块内修改
                sed -i -E "/requestProxy:/,/url:/{s/enabled: .*/enabled: true/}" "$config_file"
                sed -i -E "/requestProxy:/,/url:/{s|url: .*|url: \"socks5://warp:1080\"|}" "$config_file"
                
                # 1. 确保全局 networks 块存在
                if ! grep -q "^networks:" "$compose_file"; then
                    echo -e "\nnetworks:\n  warp:\n    external: true" >> "$compose_file"
                elif ! sed -n '/^networks:/,$p' "$compose_file" | grep -q "^  warp:"; then
                    sed -i '/^networks:/a \  warp:\n    external: true' "$compose_file"
                fi
                
                # 2. 为 sillytavern 服务添加网络连接 (置后放置)
                if ! sed -n "/^[[:space:]]*sillytavern:/,/^\([a-z]\|$\)/p" "$compose_file" | grep -q "\- warp"; then
                    if command -v python3 &> /dev/null; then
                        python3 -c "
import re, os
path = '$compose_file'
if os.path.exists(path):
    with open(path, 'r') as f: content = f.read()
    match = re.search(r'^(\s*sillytavern:.*?\n)(?=(^\S|\Z))', content, re.M | re.S)
    if match:
        block = match.group(1).rstrip()
        if 'networks:' not in block:
            block += '\n    networks:\n      - warp'
        else:
            # 如果已有 networks，先移除旧的 networks 块再重新加到最后，确保置后
            lines = block.split('\n')
            new_lines = []
            net_lines = []
            in_net = False
            for line in lines:
                if re.match(r'^\s+networks:', line):
                    in_net = True
                    continue
                if in_net and re.match(r'^\s+-', line):
                    net_lines.append(line)
                    continue
                if in_net and not re.match(r'^\s+-', line) and line.strip():
                    in_net = False
                if not in_net:
                    new_lines.append(line)
            
            block = '\n'.join(new_lines).rstrip()
            block += '\n    networks:'
            for nl in net_lines: block += '\n' + nl
            block += '\n      - warp'
            
        new_content = content[:match.start(1)] + block + '\n' + content[match.end(1):]
        with open(path, 'w') as f: f.write(new_content)
" 2>/dev/null
                    else
                        # 兜底 sed 逻辑
                        if sed -n "/^[[:space:]]*sillytavern:/,/^\([a-z]\|$\)/p" "$compose_file" | grep -q "networks:"; then
                            sed -i "/^[[:space:]]*sillytavern:/,/^\([a-z]\|$\)/ { /networks:/a \      - warp" -e "}" "$compose_file"
                        else
                            sed -i "/^[[:space:]]*sillytavern:/a \    networks:\n      - warp" "$compose_file"
                        fi
                    fi
                fi
                
                log_info "正在重启酒馆以应用更改..."
                cd "$project_dir" && $compose_cmd up -d --force-recreate
                log_success "Warp 代理配置完成！"
                sleep 2
                ;;
            2)
                echo -e "\n${CYAN}请输入代理地址 (格式: 协议://[用户名:密码@]IP或域名:端口)${NC}"
                read -rp "代理地址: " manual_url < /dev/tty
                if [[ "$manual_url" =~ ^(http|https|socks|socks5|socks4|pac)://.+:[0-9]+$ ]]; then
                    log_action "正在应用自定义代理..."
                    sed -i -E "/requestProxy:/,/url:/{s/enabled: .*/enabled: true/}" "$config_file"
                    local safe_url=$(fn_escape_sed_str "$manual_url")
                    sed -i -E "/requestProxy:/,/url:/{s|url: .*|url: \"$safe_url\"|}" "$config_file"
                    
                    # 清理可能残留的 warp 网络连接
                    if command -v python3 &> /dev/null; then
                        python3 -c "
import re, os
path = '$compose_file'
if os.path.exists(path):
    with open(path, 'r') as f: content = f.read()
    st_match = re.search(r'^(\s*sillytavern:.*?\n)(?=(^\S|\Z))', content, re.M | re.S)
    if st_match:
        block = st_match.group(1)
        block = re.sub(r'^\s*-\s*warp\s*$\n?', '', block, flags=re.M)
        block = re.sub(r'^\s*networks:\s*\n(?!\s*-)', '', block, flags=re.M)
        content = content[:st_match.start(1)] + block + content[st_match.end(1):]
    with open(path, 'w') as f: f.write(content)
" 2>/dev/null
                    fi

                    cd "$project_dir" && $compose_cmd up -d --force-recreate
                    log_success "自定义代理配置完成！"
                else
                    log_error "格式不正确。"
                fi
                sleep 2
                ;;
            3)
                log_action "正在禁用并清理代理配置..."
                sed -i -E "/requestProxy:/,/enabled:/{s/enabled: .*/enabled: false/}" "$config_file"
                
                # 优先使用 Python 处理，因为它对多行逻辑更友好
                if command -v python3 &> /dev/null; then
                    python3 -c "
import re, os
path = '$compose_file'
if os.path.exists(path):
    with open(path, 'r') as f: content = f.read()
    # 1. 清理 sillytavern 服务块内的网络引用
    st_match = re.search(r'^(\s*sillytavern:.*?\n)(?=(^\S|\Z))', content, re.M | re.S)
    if st_match:
        block = st_match.group(1)
        block = re.sub(r'^\s*-\s*warp\s*$\n?', '', block, flags=re.M)
        block = re.sub(r'^\s*networks:\s*\n(?!\s*-)', '', block, flags=re.M)
        content = content[:st_match.start(1)] + block + content[st_match.end(1):]
    
    # 2. 检查是否还有其他服务在使用 warp 网络
    if not re.search(r'^\s+-\s+warp\s*$', content, re.M):
        # 3. 清理全局 networks 定义块
        net_match = re.search(r'^networks:.*?\n(?=(^\S|\Z))', content, re.M | re.S)
        if net_match:
            net_block = net_match.group(0)
            net_block = re.sub(r'^\s+warp:\s*\n\s+external:\s*true\s*\n?', '', net_block, flags=re.M)
            if net_block.strip() == 'networks:':
                content = content[:net_match.start(0)] + content[net_match.end(0):]
            else:
                content = content[:net_match.start(0)] + net_block + content[net_match.end(0):]
    
    with open(path, 'w') as f: f.write(content)
" 2>/dev/null
                fi
                
                # 兜底使用 sed (针对没有 python 的环境)
                sed -i -E "/^[[:space:]]*sillytavern:/,/^([^[:space:]]|$)/ { /^[[:space:]]*- warp$/d }" "$compose_file"
                # 如果全局 networks 块中只剩下 warp 且没有其他服务引用，尝试删除全局定义
                if ! grep -qE "^[[:space:]]+-[[:space:]]+warp" "$compose_file"; then
                    sed -i "/^networks:/,/^[^[:space:]]/ { /^[[:space:]]*warp:/,+1 d }" "$compose_file"
                    sed -i "/^networks:[[:space:]]*$/d" "$compose_file"
                fi

                cd "$project_dir" && $compose_cmd up -d --force-recreate
                log_success "代理配置及网络连接已禁用并清理。"
                sleep 2
                ;;
            0) break ;;
        esac
    done
}

fn_ais_proxy_manager() {
    local project_dir=$1
    local compose_file=$2
    local compose_cmd=$3

    while true; do
        tput reset
        echo -e "${BLUE}=== ais2api 代理配置管理 ===${NC}"
        local proxy_url=$(grep -E "HTTP_PROXY=" "$compose_file" | head -n 1 | cut -d'=' -f2)
        
        echo -e "当前状态: $( [[ -n "$proxy_url" ]] && echo -e "${GREEN}已启用${NC}" || echo -e "${RED}已禁用${NC}" )"
        echo -e "当前代理: ${CYAN}${proxy_url:-未配置}${NC}"
        echo -e "------------------------"
        echo -e "  [1] 自动配置 Warp 代理 (http://warp:1080)"
        echo -e "  [2] 禁用并删除代理配置"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " ais_proxy_choice < /dev/tty
        [[ -z "$ais_proxy_choice" ]] && continue
        
        case "$ais_proxy_choice" in
            1)
                local target_url="http://warp:1080"
                log_action "正在检查 Warp 环境..."
                if ! docker ps -a --format '{{.Names}}' | grep -q '^warp$'; then
                    log_warn "未检测到 Warp 容器。"
                    read -rp "是否立即安装 Warp？[Y/n]: " confirm_warp < /dev/tty
                    if [[ "${confirm_warp:-y}" =~ ^[Yy]$ ]]; then
                        install_warp || continue
                    else
                        continue
                    fi
                fi

                log_action "正在配置 ais2api 代理..."
                
                # 1. 如果是 Warp，确保全局 networks 块存在
                if [[ "$target_url" == "http://warp:1080" ]]; then
                    if ! grep -q "^networks:" "$compose_file"; then
                        echo -e "\nnetworks:\n  warp:\n    external: true" >> "$compose_file"
                    elif ! sed -n '/^networks:/,$p' "$compose_file" | grep -q "^  warp:"; then
                        sed -i '/^networks:/a \  warp:\n    external: true' "$compose_file"
                    fi
                fi

                # 2. 使用 Python 注入环境变量和网络 (置后放置)
                if command -v python3 &> /dev/null; then
                    python3 -c "
import re, os
path = '$compose_file'
target_url = '$target_url'
if os.path.exists(path):
    with open(path, 'r') as f: content = f.read()
    match = re.search(r'^(\s*ais2api:.*?\n)(?=(^\S|\Z))', content, re.M | re.S)
    if match:
        block = match.group(1).rstrip()
        lines = block.split('\n')
        new_lines = []
        env_lines = []
        net_lines = []
        in_env = False
        in_net = False
        
        for line in lines:
            if re.match(r'^\s+environment:', line):
                in_env = True; in_net = False; continue
            if re.match(r'^\s+networks:', line):
                in_net = True; in_env = False; continue
            
            if in_env:
                if re.match(r'^\s+-', line):
                    if not any(x in line for x in ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY']):
                        env_lines.append(line)
                    continue
                elif line.strip(): in_env = False
            
            if in_net:
                if re.match(r'^\s+-', line):
                    if '- warp' not in line: net_lines.append(line)
                    continue
                elif line.strip(): in_net = False
            
            if not in_env and not in_net:
                new_lines.append(line)
        
        block = '\n'.join(new_lines).rstrip()
        # 添加 environment
        block += '\n    environment:'
        for el in env_lines: block += '\n' + el
        block += f'\n      - HTTP_PROXY={target_url}\n      - HTTPS_PROXY={target_url}\n      - ALL_PROXY={target_url}'
        
        # 添加 networks
        if 'warp' in target_url or net_lines:
            block += '\n    networks:'
            for nl in net_lines: block += '\n' + nl
            if 'warp' in target_url: block += '\n      - warp'
            
        new_content = content[:match.start(1)] + block + '\n' + content[match.end(1):]
        with open(path, 'w') as f: f.write(new_content)
" 2>/dev/null
                fi

                log_info "正在重启 ais2api 以应用更改..."
                cd "$project_dir" && $compose_cmd up -d --force-recreate
                log_success "ais2api 代理配置完成！"
                sleep 2
                ;;
            2)
                log_action "正在禁用并清理代理配置..."
                if command -v python3 &> /dev/null; then
                    python3 -c "
import re, os
path = '$compose_file'
if os.path.exists(path):
    with open(path, 'r') as f: content = f.read()
    match = re.search(r'^(\s*ais2api:.*?\n)(?=(^\S|\Z))', content, re.M | re.S)
    if match:
        block = match.group(1)
        block = re.sub(r'^\s*-\s*(HTTP|HTTPS|ALL)_PROXY=.*?\n', '', block, flags=re.M)
        block = re.sub(r'^\s*environment:\s*\n(?!\s*-)', '', block, flags=re.M)
        block = re.sub(r'^\s*-\s*warp\s*$\n?', '', block, flags=re.M)
        block = re.sub(r'^\s*networks:\s*\n(?!\s*-)', '', block, flags=re.M)
        content = content[:match.start(1)] + block + content[match.end(1):]
    
    if not re.search(r'^\s+-\s+warp\s*$', content, re.M):
        net_match = re.search(r'^networks:.*?\n(?=(^\S|\Z))', content, re.M | re.S)
        if net_match:
            net_block = net_match.group(0)
            net_block = re.sub(r'^\s+warp:\s*\n\s+external:\s*true\s*\n?', '', net_block, flags=re.M)
            if net_block.strip() == 'networks:':
                content = content[:net_match.start(0)] + content[net_match.end(0):]
            else:
                content = content[:net_match.start(0)] + net_block + content[net_match.end(0):]
    with open(path, 'w') as f: f.write(content)
" 2>/dev/null
                fi
                cd "$project_dir" && $compose_cmd up -d --force-recreate
                log_success "代理配置及网络连接已禁用并清理。"
                sleep 2
                ;;
            0) break ;;
        esac
    done
}

fn_st_switch_to_single() {
    local project_dir=$1
    local config_file=$2
    local compose_cmd=$3
    
    log_action "正在切换为单用户模式..."
    read -rp "请输入新的用户名: " new_user < /dev/tty
    while true; do
        read -rp "请输入新的密码: " new_pass < /dev/tty
        if [ -z "$new_pass" ]; then
            log_warn "密码不能为空。"
        elif ! fn_check_password_safe "$new_pass"; then
            log_warn "密码中包含不支持的特殊字符 (\\ / \" &)，请使用纯数字、字母或常规符号。"
        else
            break
        fi
    done

    if [ -z "$new_user" ]; then
        log_error "用户名不能为空，操作已取消。"
        return 1
    fi

    local safe_user
    local safe_pass
    safe_user=$(fn_escape_sed_str "$new_user")
    safe_pass=$(fn_escape_sed_str "$new_pass")

    sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: false # 禁用多用户模式/" "$config_file"
    sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # 启用基础认证/" "$config_file"
    sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)username:/{s/^([[:space:]]*)username: .*/\1username: \"$safe_user\"/}" "$config_file"
    sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)password:/{s/^([[:space:]]*)password: .*/\1password: \"$safe_pass\"/}" "$config_file"
    
    log_info "正在重启容器以应用更改..."
    cd "$project_dir" && $compose_cmd up -d --force-recreate
    log_success "已成功切换为单用户模式！"
}

fn_st_switch_to_multi() {
    local project_dir=$1
    local config_file=$2
    local compose_cmd=$3
    local container_name="sillytavern"

    log_action "正在切换为多用户模式..."
    
    # 获取当前单用户凭据用于引导
    local current_user=$(grep -A 2 "basicAuthUser:" "$config_file" | grep "username:" | cut -d'"' -f2)
    local current_pass=$(grep -A 2 "basicAuthUser:" "$config_file" | grep "password:" | cut -d'"' -f2)
    
    log_info "正在开启多用户模式并重启服务..."
    sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true # 启用多用户模式/" "$config_file"
    
    cd "$project_dir" && $compose_cmd up -d --force-recreate
    
    # 获取公网IP和端口
    local SERVER_IP=$(fn_get_public_ip)
    local ST_PORT=$(grep -E '^\s+-\s+"[0-9]+:8000"' "$project_dir/docker-compose.yml" | grep -oE '[0-9]+' | head -n 1)
    
    MULTI_USER_GUIDE=$(cat <<EOF

${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}
1. ${CYAN}【访问并登录】${NC}
   打开浏览器，访问: ${GREEN}http://${SERVER_IP}:${ST_PORT}${NC}
   使用您当前的凭据登录：
     ▶ 账号: ${YELLOW}${current_user:-user}${NC}
     ▶ 密码: ${YELLOW}${current_pass:-password}${NC}
2. ${CYAN}【设置管理员】${NC}
   登录后，立即在【用户设置】标签页的【管理员面板】中操作：
   A. ${GREEN}设置密码${NC}：为默认账户 \`default-user\` 设置一个强大的新密码。
   B. ${GREEN}创建新账户 (推荐)${NC}：将其身份提升为 Admin (管理员)。
${YELLOW}>>> 完成以上所有步骤后，回到本窗口按【回车键】继续 <<<${NC}
EOF
)
    echo -e "${MULTI_USER_GUIDE}"
    read -p "" < /dev/tty
    
    log_info "正在切换到多用户登录页模式..."
    sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false # 关闭基础认证，启用登录页/" "$config_file"
    sed -i -E "s/^([[:space:]]*)enableDiscreetLogin: .*/\1enableDiscreetLogin: true # 隐藏登录用户列表/" "$config_file"
    
    cd "$project_dir" && $compose_cmd up -d --force-recreate
    log_success "已成功切换为多用户模式！"
}

fn_st_change_credentials() {
    local config_file=$1
    local compose_cmd=$2
    local project_dir=$3

    local current_user=$(grep -A 2 "basicAuthUser:" "$config_file" | grep "username:" | cut -d'"' -f2)
    local current_pass=$(grep -A 2 "basicAuthUser:" "$config_file" | grep "password:" | cut -d'"' -f2)

    echo -e "\n${CYAN}--- 更改用户名密码 ---${NC}"
    echo -e "当前用户名: ${YELLOW}${current_user}${NC}"
    echo -e "当前密码: ${YELLOW}${current_pass}${NC}"
    echo -e "------------------------"
    echo -e "  [1] 修改用户名和密码"
    echo -e "  [2] 仅修改用户名"
    echo -e "  [3] 仅修改密码"
    echo -e "  [0] 取消"
    read -rp "请选择: " cred_choice < /dev/tty

    local new_user="$current_user"
    local new_pass="$current_pass"

    case "$cred_choice" in
        1)
            read -rp "请输入新用户名: " new_user < /dev/tty
            while true; do
                read -rp "请输入新密码: " new_pass < /dev/tty
                if [ -z "$new_pass" ]; then
                    log_warn "密码不能为空。"
                elif ! fn_check_password_safe "$new_pass"; then
                    log_warn "密码中包含不支持的特殊字符 (\\ / \" &)，请使用纯数字、字母或常规符号。"
                else
                    break
                fi
            done
            ;;
        2)
            read -rp "请输入新用户名: " new_user < /dev/tty
            ;;
        3)
            while true; do
                read -rp "请输入新密码: " new_pass < /dev/tty
                if [ -z "$new_pass" ]; then
                    log_warn "密码不能为空。"
                elif ! fn_check_password_safe "$new_pass"; then
                    log_warn "密码中包含不支持的特殊字符 (\\ / \" &)，请使用纯数字、字母或常规符号。"
                else
                    break
                fi
            done
            ;;
        *) return 0 ;;
    esac

    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        log_error "用户名和密码不能为空！"
        return 1
    fi

    local safe_user
    local safe_pass
    safe_user=$(fn_escape_sed_str "$new_user")
    safe_pass=$(fn_escape_sed_str "$new_pass")

    sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)username:/{s/^([[:space:]]*)username: .*/\1username: \"$safe_user\"/}" "$config_file"
    sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)password:/{s/^([[:space:]]*)password: .*/\1password: \"$safe_pass\"/}" "$config_file"
    
    log_info "正在重启容器以应用更改..."
    cd "$project_dir" && $compose_cmd restart
    log_success "凭据修改成功！"
}

fn_st_toggle_beautify() {
    local project_dir=$1
    local compose_file=$2
    local compose_cmd=$3
    local is_beautified=$4

    if [ "$is_beautified" = true ]; then
        log_action "正在关闭登录页美化..."
        sed -i '/\.\/custom\/login\.html/d' "$compose_file"
        sed -i '/\.\/custom\/images/d' "$compose_file"
        log_success "已从配置中移除美化挂载。"
    else
        log_action "正在开启登录页美化..."
        mkdir -p "$project_dir/custom/images"
        
        echo -e "\n${YELLOW}---【 开启美化前置操作 】---${NC}"
        echo -e "请确保您已将 ${CYAN}login.html${NC} 文件放置在以下目录："
        echo -e "路径: ${GREEN}$project_dir/custom/login.html${NC}"
        echo -e "----------------------------"
        read -rp "确认已放置文件？按 Enter 继续 (输入 q 取消): " confirm_file < /dev/tty
        
        if [[ "$confirm_file" == "q" ]]; then
            log_info "操作已取消。"
            return 1
        fi

        if [ ! -f "$project_dir/custom/login.html" ]; then
            log_error "未检测到文件: $project_dir/custom/login.html"
            log_warn "请先放置文件后再开启美化，否则容器将无法启动。"
            return 1
        fi

        if ! grep -q "custom/login.html" "$compose_file"; then
            # 在 volumes 块中插入挂载项
            sed -i '/volumes:/a \      - "./custom/login.html:/home/node/app/public/login.html:z"\n      - "./custom/images:/home/node/app/public/images:z"' "$compose_file"
        fi
        log_success "已成功添加美化挂载配置。"
    fi

    log_info "正在重建容器以应用更改..."
    cd "$project_dir" && $compose_cmd up -d --force-recreate
}

fn_st_docker_manager() {
    local container_name="sillytavern"
    local compose_cmd
    compose_cmd=$(fn_detect_compose_cmd || true)
    if [ -z "$compose_cmd" ]; then
        log_error "未检测到 docker-compose 或 docker compose，请确认 Docker 环境是否正常。" || return 1
    fi

    local project_dir
    project_dir=$(fn_resolve_project_dir "$container_name" "sillytavern")

    local config_file="${project_dir}/config/config.yaml"
    local compose_file="${project_dir}/docker-compose.yml"

    # 适配挂载目录不同的情况：如果 config/config.yaml 不存在，但根目录下存在 config.yaml
    if [ ! -f "$config_file" ] && [ -f "${project_dir}/config.yaml" ]; then
        config_file="${project_dir}/config.yaml"
    fi

    if [ ! -d "$project_dir" ] || [ ! -f "$compose_file" ] || [ ! -f "$config_file" ]; then
        log_error "未能找到酒馆项目目录、docker-compose.yml 或 config.yaml 文件 (路径: $project_dir)。" || return 1
    fi

    while true; do
        # 状态检测
        local is_multi_user=false
        if grep -q "enableUserAccounts: true" "$config_file" 2>/dev/null; then
            is_multi_user=true
        fi

        local is_beautified=false
        if grep -q "custom/login.html" "$compose_file" 2>/dev/null; then
            is_beautified=true
        fi

        tput reset
        echo -e "${BLUE}=== 酒馆 Docker 运维管理 ===${NC}"
        echo -e "项目路径: ${CYAN}${project_dir}${NC}"
        echo -ne "当前模式: "
        if [ "$is_multi_user" = true ]; then echo -e "${GREEN}多用户模式${NC}"; else echo -e "${YELLOW}单用户模式${NC}"; fi
        echo -ne "登录页美化: "
        if [ "$is_beautified" = true ]; then echo -e "${GREEN}已开启${NC}"; else echo -e "${RED}已关闭${NC}"; fi
        echo -e "------------------------"
        echo -e "  [1] 重启酒馆 (restart)"
        echo -e "  [2] 重建酒馆 (recreate)"
        echo -e "  [3] 更新酒馆 (pull & up)"
        
        if [ "$is_multi_user" = true ]; then
            echo -e "  [4] ${CYAN}切换为单用户模式${NC}"
            if [ "$is_beautified" = true ]; then
                echo -e "  [5] ${CYAN}关闭登录页美化${NC}"
            else
                echo -e "  [5] ${CYAN}开启登录页美化${NC}"
            fi
        else
            echo -e "  [4] ${CYAN}切换为多用户模式${NC}"
            echo -e "  [5] ${CYAN}更改用户名密码${NC}"
        fi

        echo -e "  [6] 查看运行状态 (ps)"
        echo -e "  [7] 查看资源占用 (stats)"
        echo -e "  [8] 查看实时日志 (logs -f)"
        echo -e "  [9] ${CYAN}代理配置管理${NC}"
        echo -e "  [10] ${CYAN}Host 白名单域名管理${NC}"
        echo -e "  [x] 彻底卸载酒馆"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " st_choice < /dev/tty
        [[ -z "$st_choice" ]] && continue
        case "$st_choice" in
            1)
                log_action "正在重启酒馆..."
                cd "$project_dir" && $compose_cmd restart
                read -rp "操作完成，按 Enter 继续..." < /dev/tty
                ;;
            2)
                log_action "正在强制重建酒馆容器..."
                cd "$project_dir" && $compose_cmd up -d --force-recreate --remove-orphans
                read -rp "操作完成，按 Enter 继续..." < /dev/tty
                ;;
            3)
                log_action "正在拉取最新镜像并更新..."
                cd "$project_dir" && $compose_cmd pull && $compose_cmd up -d --remove-orphans
                read -rp "操作完成，按 Enter 继续..." < /dev/tty
                ;;
            4)
                if [ "$is_multi_user" = true ]; then
                    fn_st_switch_to_single "$project_dir" "$config_file" "$compose_cmd"
                else
                    fn_st_switch_to_multi "$project_dir" "$config_file" "$compose_cmd"
                fi
                read -rp "操作完成，按 Enter 继续..." < /dev/tty
                ;;
            5)
                if [ "$is_multi_user" = true ]; then
                    fn_st_toggle_beautify "$project_dir" "$compose_file" "$compose_cmd" "$is_beautified"
                else
                    fn_st_change_credentials "$config_file" "$compose_cmd" "$project_dir"
                fi
                read -rp "操作完成，按 Enter 继续..." < /dev/tty
                ;;
            6)
                echo -e "\n${CYAN}--- 容器状态 ---${NC}"
                cd "$project_dir" && $compose_cmd ps
                read -rp "按 Enter 继续..." < /dev/tty
                ;;
            7)
                echo -e "\n${CYAN}--- 资源占用 (按 Ctrl+C 退出) ---${NC}"
                trap : INT
                docker stats "$container_name"
                trap 'exit 0' INT
                ;;
            8)
                echo -e "\n${CYAN}--- 实时日志 (按 Ctrl+C 退出) ---${NC}"
                trap : INT
                cd "$project_dir" && $compose_cmd logs -f --tail 1000
                trap 'exit 0' INT
                ;;
            9)
                fn_st_proxy_manager "$project_dir" "$config_file" "$compose_file" "$compose_cmd"
                ;;
            10)
                fn_st_host_whitelist_manager "$project_dir" "$config_file" "$compose_cmd"
                ;;
            x|X)
                if fn_uninstall_docker_app "sillytavern" "SillyTavern" "$project_dir" "ghcr.io/sillytavern/sillytavern:latest"; then
                    sleep 2
                    break
                fi
                ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

fn_warp_docker_manager() {
    local container_name="warp"
    local display_name="Warp-Docker"
    local compose_cmd
    compose_cmd=$(fn_detect_compose_cmd || true)
    if [ -z "$compose_cmd" ]; then
        log_error "未检测到 Docker Compose。" || return 1
    fi

    local project_dir
    project_dir=$(fn_resolve_project_dir "$container_name" "warp")

    if [ ! -d "$project_dir" ]; then
        log_error "未能找到项目目录。" || return 1
    fi

    while true; do
        tput reset
        echo -e "${BLUE}=== ${display_name} 运维管理 ===${NC}"
        echo -e "项目路径: ${CYAN}${project_dir}${NC}"
        echo -e "------------------------"
        echo -e "  [1] 查看代理访问地址"
        echo -e "  [2] 查看 Warp 当前 IP"
        echo -e "  [3] 更换 Warp IP (Rotate Keys)"
        echo -e "  [4] 重启服务 (restart)"
        echo -e "  [5] 查看运行状态 (ps)"
        echo -e "  [6] 查看实时日志 (logs -f)"
        echo -e "  [x] 彻底卸载服务"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " warp_choice < /dev/tty
        [[ -z "$warp_choice" ]] && continue
        case "$warp_choice" in
            1)
                local warp_port=$(grep "127.0.0.1:" "$project_dir/docker-compose.yml" | head -n 1 | sed -E 's/.*127.0.0.1:([0-9]+):1080.*/\1/' | grep -E '^[0-9]+$' || echo "1080")
                echo -e "\n${CYAN}代理访问地址 (容器间):${NC}"
                echo -e "  HTTP:   ${GREEN}http://warp:1080${NC}"
                echo -e "  SOCKS5: ${GREEN}socks5://warp:1080${NC}"
                echo -e "\n${CYAN}代理访问地址 (宿主机):${NC}"
                echo -e "  HTTP:   ${GREEN}http://127.0.0.1:${warp_port}${NC}"
                echo -e "  SOCKS5: ${GREEN}socks5://127.0.0.1:${warp_port}${NC}"
                echo -e "\n${CYAN}代理访问地址 (Docker网桥):${NC}"
                echo -e "  HTTP:   ${GREEN}http://172.17.0.1:${warp_port}${NC}"
                echo -e "  SOCKS5: ${GREEN}socks5://172.17.0.1:${warp_port}${NC}"
                echo -e "\n${YELLOW}提示: 容器间通信仅限已加入 warp 网络的容器。${NC}"
                read -rp "按 Enter 继续..." < /dev/tty
                ;;
            2)
                echo -e "\n${CYAN}--- Warp IP 信息 ---${NC}"
                docker exec "$container_name" sh -c 'printf "IPv4: %s\nIPv6: %s\nLOC:  %s (%s)\n" "$(curl -4s ifconfig.me)" "$(curl -6s ifconfig.me)" "$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep "loc=" | cut -d= -f2)" "$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep "colo=" | cut -d= -f2)"'
                read -rp "按 Enter 继续..." < /dev/tty
                ;;
            3)
                log_action "正在更换 Warp IP..."
                docker exec "$container_name" warp-cli tunnel rotate-keys
                log_success "指令已发送，IP 将在几秒内更新。"
                sleep 2
                ;;
            4) cd "$project_dir" && $compose_cmd restart; read -rp "按 Enter 继续..." < /dev/tty ;;
            5) echo -e "\n${CYAN}--- 状态 ---${NC}"; cd "$project_dir" && $compose_cmd ps; read -rp "按 Enter 继续..." < /dev/tty ;;
            6)
                echo -e "\n${CYAN}--- 日志 (Ctrl+C 退出) ---${NC}"
                trap : INT
                cd "$project_dir" && $compose_cmd logs -f --tail 100
                trap 'exit 0' INT
                ;;
            x|X)
                local image_to_remove=$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null)
                if fn_uninstall_docker_app "$container_name" "$display_name" "$project_dir" "$image_to_remove"; then
                    sleep 2
                    break
                fi
                ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

fn_find_ais2api_container_name() {
    # 1) 优先固定名
    if docker ps -a --format '{{.Names}}' | grep -q '^ais2api$'; then
        echo "ais2api"
        return
    fi

    # 2) 回退按镜像识别
    docker ps -a --format '{{.Names}}|{{.Image}}' | awk -F'|' '
        tolower($2) ~ /ghcr\.io\/ibuhub\/aistudio-to-api/ { print $1; exit }
        tolower($2) ~ /ellinalopez\/cloud-studio/ { print $1; exit }
    '
}

fn_api_docker_manager() {
    local container_name=$1
    local display_name=$2
    local service_type="${3:-$container_name}"
    local compose_cmd
    compose_cmd=$(fn_detect_compose_cmd || true)
    if [ -z "$compose_cmd" ]; then
        log_error "未检测到 Docker Compose。" || return 1
    fi

    local project_dir
    project_dir=$(fn_resolve_project_dir "$container_name" "$service_type")

    if [ -z "$project_dir" ] || [ ! -d "$project_dir" ]; then
        log_error "未能找到项目目录。" || return 1
    fi

    local compose_file="${project_dir}/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        log_error "未找到 docker-compose.yml: ${compose_file}" || return 1
    fi

    while true; do
        tput reset
        echo -e "${BLUE}=== ${display_name} 运维管理 ===${NC}"
        echo -e "项目路径: ${CYAN}${project_dir}${NC}"
        echo -e "------------------------"
        echo -e "  [1] 重启服务 (restart)"
        echo -e "  [2] 重建服务 (recreate)"
        echo -e "  [3] 更新镜像 (pull & up)"
        echo -e "  [4] 查看运行状态 (ps)"
        echo -e "  [5] 查看实时日志 (logs -f)"
        if [[ "$service_type" == "ais2api" ]]; then
            echo -e "  [6] ${CYAN}代理配置管理${NC}"
            echo -e "  [7] ${CYAN}迁移到新镜像 (ibuhub)${NC}"
        fi
        echo -e "  [x] 彻底卸载服务"
        echo -e "  [0] 返回上一级"
        echo -e "------------------------"
        read -rp "请输入选项: " api_choice < /dev/tty
        [[ -z "$api_choice" ]] && continue
        case "$api_choice" in
            1) cd "$project_dir" && $compose_cmd restart; read -rp "按 Enter 继续..." < /dev/tty ;;
            2) cd "$project_dir" && $compose_cmd up -d --force-recreate; read -rp "按 Enter 继续..." < /dev/tty ;;
            3) cd "$project_dir" && $compose_cmd pull && $compose_cmd up -d; read -rp "按 Enter 继续..." < /dev/tty ;;
            4) echo -e "\n${CYAN}--- 状态 ---${NC}"; cd "$project_dir" && $compose_cmd ps; read -rp "按 Enter 继续..." < /dev/tty ;;
            5)
                echo -e "\n${CYAN}--- 日志 (Ctrl+C 退出) ---${NC}"
                trap : INT
                cd "$project_dir" && $compose_cmd logs -f --tail 100
                trap 'exit 0' INT
                ;;
            6)
                if [[ "$service_type" == "ais2api" ]]; then
                    fn_ais_proxy_manager "$project_dir" "$compose_file" "$compose_cmd"
                else
                    log_warn "无效输入"
                fi
                ;;
            7)
                if [[ "$service_type" == "ais2api" ]]; then
                    fn_migrate_ais2api_to_ibuhub "$project_dir" "$compose_file" "$compose_cmd" "$container_name"
                    read -rp "操作完成，按 Enter 继续..." < /dev/tty
                else
                    log_warn "无效输入"
                fi
                ;;
            x|X)
                local image_to_remove=$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null)
                if fn_uninstall_docker_app "$container_name" "$display_name" "$project_dir" "$image_to_remove"; then
                    sleep 2
                    break
                fi
                ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# --- [二级菜单: 应用部署中心] ---
fn_deploy_menu() {
    while true; do
        tput reset
        fn_show_main_header
        echo -e "\n${BLUE}==================== [ 应用部署中心 ] ====================${NC}"
        echo -e "  [1] 安装 Docker"
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            echo -e "  [2] 安装 1Panel 面板"
        fi
        echo -e "  [3] 部署 酒馆"
        echo -e "  [4] 部署 gcli2api"
        echo -e "  [5] 部署 ais2api"
        echo -e "  [6] 部署 Warp"
        echo -e "------------------------------------------------------"
        echo -e "  [0] 返回上一级"
        echo -e "${BLUE}======================================================${NC}"
        read -rp "请输入选项 [0-6]: " deploy_choice < /dev/tty
        case "$deploy_choice" in
            1) log_action "正在安装 Docker..."; bash <(curl -sSL https://linuxmirrors.cn/docker.sh); read -rp $'\n操作完成，按 Enter 键返回...' < /dev/tty ;;
            2) [ "$IS_DEBIAN_LIKE" = true ] && install_1panel || log_warn "系统不支持" ;;
            3) install_sillytavern; read -rp $'\n操作完成，按 Enter 键返回...' < /dev/tty ;;
            4) install_gcli2api; read -rp $'\n操作完成，按 Enter 键返回...' < /dev/tty ;;
            5) install_ais2api; read -rp $'\n操作完成，按 Enter 键返回...' < /dev/tty ;;
            6) install_warp; read -rp $'\n操作完成，按 Enter 键返回...' < /dev/tty ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# --- [二级菜单: 应用运维管理] ---
fn_manage_menu() {
    while true; do
        tput reset
        fn_show_main_header
        echo -e "\n${BLUE}==================== [ 应用运维管理 ] ====================${NC}"
        
        local has_app=false
        # 1. 酒馆管理
        if docker ps -a --format '{{.Names}}' | grep -q '^sillytavern$'; then
            echo -e "  [1] ${GREEN}酒馆运维管理${NC}"
            has_app=true
        fi
        # 2. gcli2api 管理
        if docker ps -a --format '{{.Names}}' | grep -q '^gcli2api$'; then
            echo -e "  [2] ${GREEN}gcli2api 运维管理${NC}"
            has_app=true
        fi
        # 3. ais2api 管理
        local ais_container_name=""
        ais_container_name=$(fn_find_ais2api_container_name)
        if [ -n "$ais_container_name" ] || [ -f "${USER_HOME}/ais2api/docker-compose.yml" ]; then
            echo -e "  [3] ${GREEN}ais2api 运维管理${NC}"
            has_app=true
        fi
        # 4. 1Panel 管理
        if command -v 1pctl &> /dev/null; then
            echo -e "  [4] ${GREEN}1Panel 运维管理${NC}"
            has_app=true
        fi
        # 5. Warp 管理
        if docker ps -a --format '{{.Names}}' | grep -q '^warp$'; then
            echo -e "  [5] ${GREEN}Warp 运维管理${NC}"
            has_app=true
        fi

        if [ "$has_app" = false ]; then
            echo -e "  ${YELLOW}(未检测到已安装的应用)${NC}"
        fi

        echo -e "------------------------------------------------------"
        echo -e "  [0] 返回上一级"
        echo -e "${BLUE}======================================================${NC}"
        read -rp "请输入选项: " manage_choice < /dev/tty
        case "$manage_choice" in
            1) docker ps -a --format '{{.Names}}' | grep -q '^sillytavern$' && fn_st_docker_manager || log_warn "未安装" ;;
            2) docker ps -a --format '{{.Names}}' | grep -q '^gcli2api$' && fn_api_docker_manager "gcli2api" "gcli2api" || log_warn "未安装" ;;
            3)
                local ais_runtime_name=""
                ais_runtime_name=$(fn_find_ais2api_container_name)
                if [ -n "$ais_runtime_name" ]; then
                    fn_api_docker_manager "$ais_runtime_name" "ais2api" "ais2api"
                elif [ -f "${USER_HOME}/ais2api/docker-compose.yml" ]; then
                    fn_api_docker_manager "ais2api" "ais2api" "ais2api"
                else
                    log_warn "未安装"
                fi
                ;;
            4) command -v 1pctl &> /dev/null && fn_1panel_manager || log_warn "未安装" ;;
            5) docker ps -a --format '{{.Names}}' | grep -q '^warp$' && fn_warp_docker_manager || log_warn "未安装" ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# --- [二级菜单: 系统安全与工具] ---
fn_tools_menu() {
    while true; do
        tput reset
        fn_show_main_header
        echo -e "\n${BLUE}==================== [ 系统安全与工具 ] ====================${NC}"
        echo -e "  [1] 测试脚本 (流媒体/综合测试)"
        echo -e "  [2] API 接口连通性测试"
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            echo -e "  [3] 系统安全清理"
        fi
        if command -v fail2ban-client &> /dev/null; then
            echo -e "  [4] Fail2ban 运维管理"
        fi
        if command -v ufw &> /dev/null; then
            echo -e "  [5] UFW 防火墙运维管理"
        fi
        echo -e "------------------------------------------------------"
        echo -e "  [0] 返回上一级"
        echo -e "${BLUE}======================================================${NC}"
        read -rp "请输入选项 [0-5]: " tools_choice < /dev/tty
        case "$tools_choice" in
            1) fn_test_scripts_menu ;;
            2) fn_test_llm_api ;;
            3) [ "$IS_DEBIAN_LIKE" = true ] && run_system_cleanup || log_warn "系统不支持" ;;
            4) command -v fail2ban-client &> /dev/null && fn_fail2ban_manager || log_warn "未安装" ;;
            5) command -v ufw &> /dev/null && fn_ufw_manager || log_warn "未安装" ;;
            0) break ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        tput reset
        fn_show_main_header
        
        # 系统兼容性提示 (仅在非 Debian 系且在主菜单时显示一次)
        if [ "$IS_DEBIAN_LIKE" = false ]; then
            echo -e "\n${YELLOW}提示: 检测到系统为 ${DETECTED_OS}，部分功能受限。${NC}"
        fi

        echo -e "\n${BLUE}==================== [ 核心功能 ] ====================${NC}"
        echo -e "  [1] 服务器初始化与安全加固 (BBR/Swap/SSH)"
        echo -e "  [2] 应用部署中心 (1Panel/酒馆/API工具)"
        echo -e "  [3] 应用运维管理 (重启/更新/卸载)"
        echo -e "  [4] 系统安全与工具 (防火墙/清理/测试)"
        echo -e "${BLUE}==================== [ 脚本设置 ] ====================${NC}"
        echo -e "  [u] 检查更新    [x] 卸载脚本    [q] 退出脚本"
        echo -e "${BLUE}======================================================${NC}"
        
        read -rp "请输入选项 [1-4, u, x, q]: " choice < /dev/tty

        case "$choice" in
            1)
                if [ "$IS_DEBIAN_LIKE" = true ]; then
                    run_initialization
                else
                    log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"
                    sleep 2
                fi
                ;;
            2) fn_deploy_menu ;;
            3) fn_manage_menu ;;
            4) fn_tools_menu ;;
            u|U)
                fn_check_update
                read -rp "按 Enter 返回..." < /dev/tty
                ;;
            x|X)
                fn_uninstall_gugu
                read -rp "按 Enter 返回..." < /dev/tty
                ;;
            q|Q)
                echo -e "\n感谢使用，再见！"; exit 0
                ;;
            *)
                echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 1
                ;;
        esac
    done
}

# --- [启动逻辑] ---
fn_init_user_home
fn_ensure_valid_cwd || true
fn_auto_install
# 仅在已安装模式下启动时检查更新，避免干扰初次运行
[[ "$0" == "$GUGU_PATH" ]] && fn_check_update
main_menu
