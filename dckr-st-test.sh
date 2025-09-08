#!/usr/bin/env bash

# SillyTavern 助手 v1.0
# 作者: Qingjue | 小红书号: 826702880

set -e
set -o pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[1;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# --- 全局操作系统检测 ---
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
# --- ------------------ ---


log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "\n${RED}[ERROR] $1${NC}\n"; exit 1; }
log_action() { echo -e "${YELLOW}[ACTION] $1${NC}"; }
log_step() { echo -e "\n${BLUE}--- $1: $2 ---${NC}"; }
log_success() { echo -e "${GREEN}✓ $1${NC}"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
       echo -e "\n${RED}错误: 此脚本需要 root 权限执行。${NC}"
       echo -e "请尝试使用 ${YELLOW}sudo bash $0${NC} 来运行。\n"
       exit 1
    fi
}

fn_optimize_docker() {
    log_action "是否需要进行 Docker 优化（配置日志限制与镜像加速）？"
    log_info "此操作将：1. 限制日志大小防止磁盘占满。 2. 测试并配置最快的镜像源。"
    read -rp "强烈推荐执行，是否继续？[Y/n]: " confirm_optimize < /dev/tty
    if [[ ! "${confirm_optimize:-y}" =~ ^[Yy]$ ]]; then
        log_info "已跳过 Docker 优化。"
        return
    fi

    if ! command -v jq &> /dev/null; then
        log_info "优化需要 jq 工具，正在尝试安装..."
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            apt-get update && apt-get install -y jq
        else
            if command -v yum &> /dev/null; then yum install -y epel-release && yum install -y jq; elif command -v dnf &> /dev/null; then dnf install -y epel-release && dnf install -y jq; fi
        fi
        if ! command -v jq &> /dev/null; then log_error "jq 安装失败，请手动安装后重试。"; fi
        log_success "jq 安装成功！"
    fi

    local DAEMON_JSON="/etc/docker/daemon.json"
    local final_config
    final_config=$(cat "$DAEMON_JSON" 2>/dev/null || echo "{}")

    # --- 步骤1: 镜像测速与配置 (全新逻辑) ---
    log_info "正在检测 Docker 镜像源可用性 (将测试所有源以找出最优解)..."
    # 使用了更完整的镜像列表
    local mirrors=(
        "docker.io" "https://docker.1ms.run" "https://hub1.nat.tf" "https://docker.1panel.live" 
        "https://dockerproxy.1panel.live" "https://hub.rat.dev" "https://docker.m.ixdev.cn" 
        "https://hub2.nat.tf" "https://docker.1panel.dev" "https://docker.amingg.com" "https://docker.xuanyuan.me" 
        "https://dytt.online" "https://lispy.org" "https://docker.xiaogenban1993.com" 
        "https://docker-0.unsee.tech" "https://666860.xyz"
    )
    docker rmi hello-world > /dev/null 2>&1 || true
    local results=""; local official_hub_time=9999
    for mirror in "${mirrors[@]}"; do
        local pull_target="hello-world"; local display_name="$mirror"; local timeout_duration=10
        if [[ "$mirror" == "docker.io" ]]; then timeout_duration=15; display_name="Official Docker Hub"; else pull_target="${mirror#https://}/library/hello-world"; fi
        echo -ne "  - 正在测试: ${YELLOW}${display_name}${NC}..."
        local start_time; start_time=$(date +%s.%N)
        if (timeout -k 15 "$timeout_duration" docker pull "$pull_target" >/dev/null) 2>/dev/null; then
            local end_time; end_time=$(date +%s.%N); local duration; duration=$(echo "$end_time - $start_time" | bc)
            printf " ${GREEN}%.2f 秒${NC}\n" "$duration"
            results+="${duration}|${mirror}|${display_name}\n"
            docker rmi "$pull_target" > /dev/null 2>&1 || true
            if [[ "$mirror" == "docker.io" ]]; then official_hub_time=$duration; fi
        else
            echo -e " ${RED}超时或失败${NC}"
        fi
    done

    local mirrors_json="[]"
    # 决策逻辑：只有当官方源非常慢(>10秒)或超时时，才启用备用镜像
    if (($(echo "$official_hub_time > 10" | bc -l))); then
        log_warn "官方 Docker Hub 连接缓慢或超时，将自动配置最快的备用镜像。"
        local sorted_mirrors; sorted_mirrors=$(echo -e "$results" | grep -v '|docker.io|' | LC_ALL=C sort -n)
        if [ -n "$sorted_mirrors" ]; then
            # 这里您可以将 head -n 4 改为 3 或其他数字
            local best_mirrors; best_mirrors=($(echo "$sorted_mirrors" | head -n 5 | cut -d'|' -f2))
            log_success "将配置最快的 ${#best_mirrors[@]} 个镜像源。"
            mirrors_json=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//' | awk '{print "["$0"]"}')
        else
            log_warn "所有备用镜像均测试失败！将不配置镜像加速。"
        fi
    else
        log_success "官方 Docker Hub 速度良好 ( ${official_hub_time}s )，无需配置镜像加速。"
    fi
    final_config=$(echo "$final_config" | jq --argjson mirrors "$mirrors_json" '."registry-mirrors" = $mirrors')

    # --- 步骤2: 日志配置 ---
    log_info "正在添加日志大小限制配置..."
    final_config=$(echo "$final_config" | jq '. + {"log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}}')
    log_success "日志配置已添加。"

    # --- 步骤3: 应用所有配置 ---
    log_action "正在应用所有优化配置..."
    echo "$final_config" | sudo tee "$DAEMON_JSON" > /dev/null
    if sudo systemctl restart docker; then
        log_success "Docker 服务已重启，优化配置已生效！"
    else
        log_error "Docker 服务重启失败！请检查 ${DAEMON_JSON} 格式。"
    fi
}


run_system_cleanup() {
    check_root
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

    # 再次检查 Docker 是否存在
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
    if [ -f /swapfile ]; then
        log_info "Swap 文件 /swapfile 已存在，跳过创建。"
        return 0
    fi

    # 获取物理内存大小 (MB)
    local mem_total_mb
    mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')

    local swap_size_mb
    local swap_size_display

    # 根据内存大小决定Swap大小
    if [ "$mem_total_mb" -lt 2048 ]; then # 小于 2GB 内存
        swap_size_mb=$((mem_total_mb * 2))
    elif [ "$mem_total_mb" -lt 8192 ]; then # 2GB - 8GB 内存
        swap_size_mb=$mem_total_mb
    else # 大于 8GB 内存
        swap_size_mb=4096 # 设置一个 4GB 的上限
    fi

    # 使用 bc 进行浮点运算，精确计算显示值，并处理开头为"."的情况 (如 .8 -> 0.8)
    swap_size_display=$(echo "scale=1; $swap_size_mb / 1024" | bc | sed 's/^\./0./')G

    log_action "检测到物理内存为 ${mem_total_mb}MB，将创建 ${swap_size_display} 的 Swap 文件..."
    fallocate -l "${swap_size_mb}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_success "Swap 文件创建、启用并已设置为开机自启。"
}


run_initialization() {
    tput reset
    echo -e "${CYAN}即将执行【服务器初始化】流程...${NC}"

    log_step "步骤 1" "配置云服务商安全组"
    log_info "执行前，必须在云服务商控制台完成安全组/防火墙配置。"
    log_info "需放行以下两个TCP端口的入站流量："
    echo -e "  - ${YELLOW}22${NC}: 当前SSH连接使用的端口。"
    echo -e "  - ${YELLOW}一个新的高位端口${NC}: 范围 ${GREEN}49152-65535${NC}，将用作新SSH端口。"
    log_warn "若新SSH端口未在安全组放行，脚本执行后将导致SSH无法连接。"
    read -rp "确认已完成上述配置后，按 Enter 键继续。" < /dev/tty

    log_step "步骤 2" "设置系统时区"
    log_action "正在设置时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai
    log_success "时区设置完成。当前系统时间: $(date +"%Y-%m-%d %H:%M:%S")"

    log_step "步骤 3" "修改SSH服务端口"
    log_info "目的: 更改默认22端口，降低被自动化攻击的风险。"
    read -rp "请输入新的SSH端口号 (范围 49152 - 65535): " NEW_SSH_PORT < /dev/tty
    if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 49152 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
        log_error "输入无效。端口号必须是 49152-65535 之间的数字。"
    fi
    log_action "正在修改配置文件 /etc/ssh/sshd_config..."
    sed -i.bak "s/^#\?Port [0-9]\+/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    log_success "SSH端口已在配置中更新为 ${NEW_SSH_PORT}。"

    log_step "步骤 4" "安装Fail2ban"
    log_info "目的: 自动阻止有恶意登录企图的IP地址。"
    log_action "正在更新包列表并安装 Fail2ban..."
    apt-get update
    apt-get install -y fail2ban
    systemctl enable --now fail2ban
    log_success "Fail2ban 安装并配置为开机自启。"

    log_step "步骤 5" "应用并验证新的SSH端口"
    log_action "正在重启SSH服务以应用新端口 ${NEW_SSH_PORT}..."
    systemctl restart sshd
    log_info "SSH服务已重启。现在必须验证新端口的连通性。"
    echo "-----------------------------------------------------------------------"
    log_warn "操作1: 打开一个新终端窗口。"
    log_warn "操作2: 尝试使用新端口 ${GREEN}${NEW_SSH_PORT}${RED} 连接服务器。"
    log_warn "操作3: ${GREEN}连接成功后${RED}，回到本窗口按 Enter 键继续。"
    log_warn "操作4: ${RED}连接失败时${RED}，回到本窗口按 ${YELLOW}Ctrl+C${RED} 中止脚本 (22端口仍可用)。"
    echo "-----------------------------------------------------------------------"
    read -rp "请进行验证操作..." < /dev/tty

    log_step "步骤 6" "升级系统软件包"
    log_info "目的: 应用最新的安全补丁和软件更新。"
    log_action "正在执行系统升级，此过程可能需要一些时间，请耐心等待..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    log_success "所有软件包已升级至最新版本。"

    log_step "步骤 7" "优化内核参数并创建Swap"
    log_info "目的: 启用BBR优化网络，并创建Swap防止内存溢出。"
    log_action "正在向 /etc/sysctl.conf 添加配置..."
    sed -i -e '/net.core.default_qdisc=fq/d' \
           -e '/net.ipv4.tcp_congestion_control=bbr/d' \
           -e '/vm.swappiness=10/d' /etc/sysctl.conf
    cat <<EOF >> /etc/sysctl.conf

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
    log_success "内核参数配置完成。"

    create_dynamic_swap

    log_step "步骤 8" "应用配置并准备重启"
    log_action "正在应用内核参数..."
    sysctl -p
    log_info "所有配置已写入。服务器需要重启以使所有更改完全生效。"
    read -n 1 -r -p "是否立即重启服务器? [Y/n] " REPLY < /dev/tty
    echo

    log_step "步骤 9" "重启后操作指南"
    log_info "服务器重启后，使用新端口 ${GREEN}${NEW_SSH_PORT}${NC} 成功登录，然后再次运行本脚本选择【步骤2】。"
    echo -e "  - ${YELLOW}验证(可选):${NC} 执行 'sudo sysctl net.ipv4.tcp_congestion_control && free -h' 检查BBR和Swap。"
    echo -e "  - ${YELLOW}安全(重要):${NC} 确认一切正常后，需登录云平台，从安全组中${BOLD}移除旧的22端口规则${NC}。"

    if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
        log_info "服务器将立即重启..."
        reboot
        exit 0
    else
        log_info "已选择稍后重启。请在方便时手动执行 'sudo reboot'。"
    fi
}

install_1panel() {
    tput reset
    echo -e "${CYAN}即将执行【安装 1Panel】流程...${NC}"
    
    if ! command -v curl &> /dev/null; then
        log_info "未检测到 curl，正在尝试安装..."
        apt-get update && apt-get install -y curl
        if ! command -v curl &> /dev/null; then
            log_error "curl 安装失败，请手动安装后再试。"
        fi
    fi

    log_step "步骤 1/3" "运行 1Panel 官方安装脚本"
    log_warn "即将进入 1Panel 交互式安装界面，需根据其提示操作。"
    read -rp "按 Enter 键开始..." < /dev/tty
    bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
    
    log_step "步骤 2/3" "检查并确保 Docker 已安装"
    if ! command -v docker &> /dev/null; then
        log_warn "1Panel 安装程序似乎已结束，但未检测到 Docker。"
        log_action "正在尝试使用备用脚本安装 Docker..."
        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
        
        if ! command -v docker &> /dev/null; then
            log_error "备用脚本也未能成功安装 Docker。请检查网络或手动安装 Docker 后再继续。"
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
    echo -e "并确保云服务商的防火墙/安全组中 ${GREEN}已放行 1Panel 的端口${NC}。"
    echo -e "\n${BOLD}可重新运行本脚本，选择【步骤3】来部署 SillyTavern。${NC}"
    log_warn "若刚才有用户被添加到 docker 组，务必先退出并重新登录SSH！"
}

install_sillytavern() {
    local BC_VER="-" BC_STATUS="-"
    local CURL_VER="-" CURL_STATUS="-"
    local TAR_VER="-" TAR_STATUS="-"
    local DOCKER_VER="-" DOCKER_STATUS="-"
    local COMPOSE_VER="-" COMPOSE_STATUS="-"
    local CONTAINER_NAME="sillytavern"
    local IMAGE_NAME="ghcr.io/sillytavern/sillytavern:latest"

    fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
    fn_print_info() { echo -e "  $1"; }
    fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; exit 1; }

    fn_report_dependencies() {
        fn_print_info "--- 环境诊断摘要 ---"
        printf "${BOLD}%-18s %-20s %-20s${NC}\n" "工具" "检测到的版本" "状态"
        printf "${CYAN}%-18s %-20s %-20s${NC}\n" "------------------" "--------------------" "--------------------"
        print_status_line() { 
            local name="$1" version="$2" status="$3"
            local color="$GREEN"
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

    fn_get_cleaned_version_num() { echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }

    fn_check_dependencies() {
        fn_print_info "--- 依赖环境诊断开始 (将自动安装缺失的基础工具) ---"
        local missing_pkgs=()
        for pkg in "bc" "curl" "tar"; do
            if ! command -v "$pkg" &> /dev/null; then
                missing_pkgs+=("$pkg")
            fi
        done

        if [ ${#missing_pkgs[@]} -gt 0 ]; then
            log_action "检测到缺失的基础工具: ${missing_pkgs[*]}，正在尝试自动安装..."
            if [ "$IS_DEBIAN_LIKE" = true ]; then
                apt-get update && apt-get install -y "${missing_pkgs[@]}"
            else
                if command -v yum &> /dev/null; then yum install -y "${missing_pkgs[@]}"; elif command -v dnf &> /dev/null; then dnf install -y "${missing_pkgs[@]}"; else log_warn "无法确定包管理器，请手动安装: ${missing_pkgs[*]}"; fi
            fi
        fi

        # --- 重新检查并报告 ---
        local all_deps_ok=true
        for pkg in "bc" "curl" "tar"; do
            if command -v "$pkg" &> /dev/null; then
                declare "${pkg^^}_VER"="$(fn_get_cleaned_version_num "$($pkg --version 2>/dev/null || echo 'N/A')")"; declare "${pkg^^}_STATUS"="OK"
            else
                declare "${pkg^^}_STATUS"="Not Found"; all_deps_ok=false
            fi
        done
        if [ "$all_deps_ok" = false ]; then fn_print_error "部分基础依赖自动安装失败，请手动安装后重试。"; fi

        # --- Docker 和 Compose 检查与交互式安装 ---
        local docker_check_needed=true
        while $docker_check_needed; do
            if ! command -v docker &> /dev/null; then
                DOCKER_STATUS="Not Found"
            else
                DOCKER_VER=$(fn_get_cleaned_version_num "$(docker --version)"); DOCKER_STATUS="OK"
            fi
            if command -v docker-compose &> /dev/null; then
                DOCKER_COMPOSE_CMD="docker-compose"; COMPOSE_VER="v$(fn_get_cleaned_version_num "$($DOCKER_COMPOSE_CMD version)")"; COMPOSE_STATUS="OK (v1)"
            elif docker compose version &> /dev/null; then
                DOCKER_COMPOSE_CMD="docker compose"; COMPOSE_VER=$(docker compose version | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n 1); COMPOSE_STATUS="OK (v2)"
            else
                DOCKER_COMPOSE_CMD=""; COMPOSE_STATUS="Not Found"
            fi

            if [[ "$DOCKER_STATUS" == "Not Found" || "$COMPOSE_STATUS" == "Not Found" ]]; then
                if [ "$IS_DEBIAN_LIKE" = true ]; then
                    log_warn "未检测到 Docker 或 Docker-Compose。"
                    read -rp "是否立即尝试自动安装 Docker? [Y/n]: " confirm_install_docker < /dev/tty
                    if [[ "${confirm_install_docker:-y}" =~ ^[Yy]$ ]]; then
                        log_action "正在使用官方推荐脚本安装 Docker..."
                        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
                        # 安装后再次循环检查
                        continue
                    else
                        fn_print_error "用户选择不安装 Docker，脚本无法继续。"
                    fi
                else
                    # 非 Debian 系统直接报错
                    fn_print_error "未检测到 Docker 或 Docker-Compose。请在您的系统 (${DETECTED_OS}) 上手动安装它们后重试。"
                fi
            else
                # Docker 和 Compose 都已存在，检查通过，结束循环
                docker_check_needed=false
            fi
        done

        fn_report_dependencies

        local current_user="${SUDO_USER:-$(whoami)}"
        if ! groups "$current_user" | grep -q '\bdocker\b' && [ "$(id -u)" -ne 0 ]; then
            fn_print_error "当前用户不在 docker 用户组。请执行【步骤2】或手动添加后，【重新登录SSH】再试。"
        fi
        log_success "所有依赖项检查通过！"
    }



    fn_apply_config_changes() {
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
        elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
            sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true # 临时开启基础认证以设置管理员/" "$CONFIG_FILE"
            sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true # 启用多用户模式/" "$CONFIG_FILE"
        fi
    }


    fn_get_public_ip() {
        local ip
        ip=$(curl -s --max-time 5 https://api.ipify.org) || ip=$(curl -s --max-time 5 https://ifconfig.me) || ip=$(hostname -I | awk '{print $1}')
        echo "$ip"
    }
    
    fn_confirm_and_delete_dir() {
        local dir_to_delete="$1"
        local container_name="$2"
        log_warn "目录 '$dir_to_delete' 已存在，可能包含之前的聊天记录和角色卡。"
        read -r -p "确定要【彻底清理】并继续安装吗？此操作会停止并删除旧容器。[Y/n]: " c1 < /dev/tty
        if [[ ! "${c1:-y}" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。"; fi
        read -r -p "$(echo -e "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 [Y/n]: ${NC}")" c2 < /dev/tty
        if [[ ! "${c2:-y}" =~ ^[Yy]$ ]]; then fn_print_error "操作被用户取消。"; fi
        read -r -p "$(echo -e "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}")" c3 < /dev/tty
        if [[ "$c3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi
        fn_print_info "正在停止并移除旧容器: $container_name..."
        docker stop "$container_name" > /dev/null 2>&1 || true
        docker rm "$container_name" > /dev/null 2>&1 || true
        log_success "旧容器已停止并移除。"
        fn_print_info "正在删除旧目录: $dir_to_delete..."
        sudo rm -rf "$dir_to_delete"
        log_success "旧目录已彻底清理。"
    }

    fn_create_project_structure() {
        fn_print_info "正在创建项目目录结构..."
        mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
        fn_print_info "正在设置文件所有权..."
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
        log_success "项目目录创建并授权成功！"
    }

    fn_pull_with_progress_bar() {
        local compose_file="$1"
        local docker_compose_cmd="$2"
        local time_estimate_table="$3"
        local PULL_LOG
        PULL_LOG=$(mktemp)
        trap 'rm -f "$PULL_LOG"' EXIT
        
        $docker_compose_cmd -f "$compose_file" pull > "$PULL_LOG" 2>&1 &
        local pid=$!
        while kill -0 $pid 2>/dev/null; do
            clear || true 
            echo -e "${time_estimate_table}"
            echo -e "\n${CYAN}--- 实时拉取进度 (下方为最新日志) ---${NC}"
            grep -E 'Downloading|Extracting|Pull complete|Verifying Checksum|Already exists' "$PULL_LOG" | tail -n 5 || true
            sleep 1
        done
        
        wait $pid
        local exit_code=$?
        trap - EXIT

        clear || true

        if [ $exit_code -ne 0 ]; then
            echo -e "${RED}Docker 镜像拉取失败！${NC}" >&2
            echo -e "${YELLOW}以下是来自 Docker 的原始错误日志：${NC}" >&2
            echo "--------------------------------------------------" >&2
            cat "$PULL_LOG" >&2
            echo "--------------------------------------------------" >&2
            rm -f "$PULL_LOG"
            fn_print_error "请根据以上日志排查问题，可能原因包括网络不通、镜像源失效或 Docker 服务异常。"
        else
            rm -f "$PULL_LOG"
            log_success "镜像拉取成功！"
        fi
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
            status=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "error")
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

    fn_check_and_explain_status() {
        local container_name="$1"
        echo -e "\n${YELLOW}--- 容器当前状态 ---${NC}"
        docker ps -a --filter "name=${container_name}"
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "notfound")
        echo -e "\n${CYAN}--- 状态解读 ---${NC}"
        case "$status" in
            running) log_success "状态正常：容器正在健康运行。";;
            restarting) log_warn "状态异常：容器正在无限重启。"; fn_print_info "通常意味着程序内部崩溃。请使用 [2] 查看日志定位错误。";;
            exited) echo -e "${RED}状态错误：容器已停止运行。${NC}"; fn_print_info "通常是由于启动时发生致命错误。请使用 [2] 查看日志获取错误信息。";;
            notfound) echo -e "${RED}未能找到名为 '${container_name}' 的容器。${NC}";;
            *) log_warn "状态未知：容器处于 '${status}' 状态。"; fn_print_info "建议使用 [2] 查看日志进行诊断。";;
        esac
    }

    fn_display_final_info() {
        echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "║                   ${BOLD}部署成功！尽情享受吧！${NC}                   ║"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        
        if [[ "$run_mode" == "1" ]]; then
            echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:8000${NC}"
            echo -e "  ${CYAN}登录账号:${NC} ${YELLOW}${single_user}${NC}"
            echo -e "  ${CYAN}登录密码:${NC} ${YELLOW}${single_pass}${NC}"
        elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
            echo -e "\n  ${YELLOW}登录页面:${NC} ${GREEN}http://${SERVER_IP}:8000/login${NC}"
        fi
        
        echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
    }

    tput reset
    echo -e "${CYAN}SillyTavern Docker 自动化安装流程${NC}"

    fn_print_step "[ 1/5 ] 环境检查与准备"
    if [ "$(id -u)" -ne 0 ]; then fn_print_error "此脚本需要 root 权限运行。请使用 'sudo' 执行。"; fi
    TARGET_USER="${SUDO_USER:-root}"
    if [ "$TARGET_USER" = "root" ]; then
        USER_HOME="/root"
        log_warn "检测到以 root 用户运行，将安装在 /root 目录。"
    else
        USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        if [ -z "$USER_HOME" ]; then fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"; fi
    fi
    INSTALL_DIR="$USER_HOME/sillytavern"
    CONFIG_FILE="$INSTALL_DIR/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    fn_check_dependencies

# 调用新的统一优化函数
fn_optimize_docker
    
    SERVER_IP=$(fn_get_public_ip)

    fn_print_step "[ 2/5 ] 选择运行模式与路径"

    # 定义统一的默认路径
    local default_path="$USER_HOME/sillytavern"

    echo "选择运行模式："
    echo -e "  [1] ${CYAN}单用户模式${NC} (弹窗认证，适合个人使用)"
    echo -e "  [2] ${CYAN}多用户模式${NC} (独立登录页，适合多人或单人使用)"
    echo -e "  [3] ${RED}维护者模式${NC} (作者专用，普通用户请勿选择！)"
    read -p "请输入选项数字 [默认为 1]: " run_mode < /dev/tty
    run_mode=${run_mode:-1}

    # 根据模式执行特定操作，但不改变路径逻辑
    case "$run_mode" in
        1)
            read -p "请输入自定义用户名: " single_user < /dev/tty
            read -p "请输入自定义密码: " single_pass < /dev/tty
            if [ -z "$single_user" ] || [ -z "$single_pass" ]; then fn_print_error "用户名和密码不能为空！"; fi
            ;;
        2)
            # 多用户模式无需额外输入
            ;;
        3)
            log_warn "已进入维护者模式，此模式需要手动准备特殊文件。"
            ;;
        *)
            fn_print_error "无效输入，脚本已终止."
            ;;
    esac

    # 统一的路径设置提示
    read -rp "请输入安装路径 [默认: ${default_path}]: " custom_path < /dev/tty
    INSTALL_DIR="${custom_path:-$default_path}"
    log_info "安装路径最终设置为: ${INSTALL_DIR}"


# 更新配置文件路径变量
CONFIG_FILE="$INSTALL_DIR/config.yaml"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"


    fn_print_step "[ 3/5 ] 创建项目文件"
    if [ -d "$INSTALL_DIR" ]; then
        fn_confirm_and_delete_dir "$INSTALL_DIR" "$CONTAINER_NAME"
    fi

    if [[ "$run_mode" == "3" ]]; then
        fn_print_info "正在创建开发者模式项目目录结构..."
        mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
        mkdir -p "$INSTALL_DIR/custom/images"
        touch "$INSTALL_DIR/custom/login.html"
        fn_print_info "正在设置文件所有权..."
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
        log_success "开发者项目目录创建并授权成功！"
    else
        fn_create_project_structure
    fi

    
    cd "$INSTALL_DIR"
    fn_print_info "工作目录已切换至: $(pwd)"

    if [[ "$run_mode" == "3" ]]; then
    cat <<EOF > "$COMPOSE_FILE"
services:
  sillytavern:
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    image: ${IMAGE_NAME}
    environment:
      - NODE_ENV=production
      - FORCE_COLOR=1
    ports:
      - "8000:8000"
    volumes:
      - "./:/home/node/app/config:Z"
      - "./data:/home/node/app/data:Z"
      - "./plugins:/home/node/app/plugins:Z"
      - "./public/scripts/extensions/third-party:/home/node/app/public/scripts/extensions/third-party:Z"
      # --- 以下为自定义版特有挂载 ---
      - "./custom/login.html:/home/node/app/public/login.html:Z"
      - "./custom/images:/home/node/app/public/images:Z"
    restart: unless-stopped
EOF
    else
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
    ports:
      - "8000:8000"
    volumes:
      - "./:/home/node/app/config:Z"
      - "./data:/home/node/app/data:Z"
      - "./plugins:/home/node/app/plugins:Z"
      - "./public/scripts/extensions/third-party:/home/node/app/public/scripts/extensions/third-party:Z"
    restart: unless-stopped
EOF
    fi
    log_success "docker-compose.yml 文件创建成功！"

    if [[ "$run_mode" == "3" ]]; then
        log_warn "维护者模式：请现在将您的自定义文件 (如 login.html) 放入 '$INSTALL_DIR/custom' 目录。"
        read -rp "文件放置完毕后，按 Enter 键继续..." < /dev/tty
    fi

    fn_print_step "[ 4/5 ] 初始化与配置"
    fn_print_info "即将拉取 SillyTavern 镜像，下载期间将持续显示预估时间。"
    TIME_ESTIMATE_TABLE=$(cat <<EOF
  下载速度取决于网络带宽，以下为预估时间参考：
  ${YELLOW}┌──────────────────────────────────────────────────┐${NC}
  ${YELLOW}│${NC} ${CYAN}带宽${NC}      ${BOLD}|${NC} ${CYAN}下载速度${NC}    ${BOLD}|${NC} ${CYAN}预估最快时间${NC}           ${YELLOW}│${NC}
  ${YELLOW}├──────────────────────────────────────────────────┤${NC}
  ${YELLOW}│${NC} 1M 带宽   ${BOLD}|${NC} ~0.125 MB/s ${BOLD}|${NC} 约 27 分钟             ${YELLOW}│${NC}
  ${YELLOW}│${NC} 2M 带宽   ${BOLD}|${NC} ~0.25 MB/s  ${BOLD}|${NC} 约 13.5 分钟           ${YELLOW}│${NC}
  ${YELLOW}│${NC} 10M 带宽  ${BOLD}|${NC} ~1.25 MB/s  ${BOLD}|${NC} 约 2.7 分钟            ${YELLOW}│${NC}
  ${YELLOW}│${NC} 100M 带宽 ${BOLD}|${NC} ~12.5 MB/s  ${BOLD}|${NC} 约 16 秒               ${YELLOW}│${NC}
  ${YELLOW}└──────────────────────────────────────────────────┘${NC}
EOF
)
    fn_pull_with_progress_bar "$COMPOSE_FILE" "$DOCKER_COMPOSE_CMD" "$TIME_ESTIMATE_TABLE"
    fn_print_info "正在进行首次启动以生成官方配置文件..."
    if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null 2>&1; then
        fn_print_error "首次启动容器失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
    fi
    local timeout=60
    while [ ! -f "$CONFIG_FILE" ]; do
        if [ $timeout -eq 0 ]; then
            fn_print_error "等待配置文件生成超时！请检查日志输出：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
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
            fn_print_error "临时启动容器以设置管理员失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
        fi
        fn_verify_container_health "$CONTAINER_NAME"
        fn_wait_for_service
        MULTI_USER_GUIDE=$(cat <<EOF

${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}
1. ${CYAN}【开放端口】${NC}
   需确保服务器后台（如阿里云/腾讯云安全组）已开放 ${GREEN}8000${NC} 端口。
2. ${CYAN}【访问并登录】${NC}
   打开浏览器，访问: ${GREEN}http://${SERVER_IP}:8000${NC}
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
        fn_print_error "应用最终配置并启动服务失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
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
        case "$choice" in
            1) fn_check_and_explain_status "$CONTAINER_NAME";;
            2) echo -e "\n${YELLOW}--- 实时日志 (按 Ctrl+C 停止) ---${NC}"; docker logs -f "$CONTAINER_NAME" || true;;
            3) fn_display_final_info;;
            q|Q) echo -e "\n已退出部署后菜单。"; break;;
            *) log_warn "无效输入，请输入 1, 2, 3 或 q。";;
        esac
    done
}

main_menu() {
    while true; do
        tput reset
        echo -e "${CYAN}╔═════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     ${BOLD}SillyTavern 助手 v1.5${NC}       ${CYAN}║${NC}"
        echo -e "${CYAN}║   by Qingjue | XHS:826702880    ${CYAN}║${NC}"
        echo -e "${CYAN}╚═════════════════════════════════╝${NC}"

        if [ "$IS_DEBIAN_LIKE" = false ]; then
            echo -e "\n${YELLOW}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║                        【 系统兼容性提示 】                            ║${NC}"
            echo -e "${YELLOW}╠═════════════════════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${YELLOW}║${NC} 检测到您的系统为: ${CYAN}${DETECTED_OS}${NC}"
            echo -e "${YELLOW}║${NC} 本脚本专为 Debian/Ubuntu 优化，因此部分功能在您的系统上不可用。         ${YELLOW}║${NC}"
            echo -e "${YELLOW}║─────────────────────────────────────────────────────────────────────────────║${NC}"
            echo -e "${YELLOW}║ ${RED}不可用功能:${NC} [1] 服务器初始化, [2] 安装1Panel, [4] 系统清理        ${YELLOW}║${NC}"
            echo -e "${YELLOW}║ ${GREEN}可 用 功 能:${NC} [3] 部署 SillyTavern (内置Docker优化)               ${YELLOW}║${NC}"
            echo -e "${YELLOW}║─────────────────────────────────────────────────────────────────────────────║${NC}"
            echo -e "${YELLOW}║ ${BOLD}请注意：要使用可用功能，您必须先手动安装好 Docker 和 Docker-Compose。${NC}   ${YELLOW}║${NC}"
            echo -e "${YELLOW}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
        else
            echo -e "\n${BOLD}使用说明 (Debian/Ubuntu):${NC}"
            echo -e "  • ${YELLOW}全新服务器${NC}: 请按 ${GREEN}1 -> 2 -> 3${NC} 的顺序分步执行。"
            echo -e "  • ${YELLOW}已有Docker环境${NC}: 可直接从【步骤3】开始。"
        fi

        echo -e "\n${BLUE}================================== 菜 单 ==================================${NC}"
        
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            echo -e " ${GREEN}[1] 服务器初始化 (安全加固、系统优化)${NC}"
            echo -e " ${GREEN}[2] 安装 1Panel 面板 (会自动安装Docker)${NC}"
        fi
        
        echo -e " ${GREEN}[3] 部署 SillyTavern (基于Docker)${NC}"
        echo -e "---------------------------------------------------------------------------"

        if [ "$IS_DEBIAN_LIKE" = true ]; then
            echo -e " ${CYAN}[4] 系统安全清理 (清理缓存和无用镜像)${NC}"
        fi

        echo -e "${BLUE}===========================================================================${NC}"
        echo -e " ${YELLOW}[q] 退出脚本${NC}\n"

        local valid_options="q,3"
        if [ "$IS_DEBIAN_LIKE" = true ]; then valid_options+=",1,2,4"; fi
        read -rp "请输入选项 [${valid_options}]: " choice < /dev/tty

        case "$choice" in
            1) 
                if [ "$IS_DEBIAN_LIKE" = true ]; then check_root; run_initialization; else log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"; sleep 2; fi
                ;;
            2) 
                if [ "$IS_DEBIAN_LIKE" = true ]; then check_root; install_1panel; read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty; else log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"; sleep 2; fi
                ;;
            3) 
                check_root; install_sillytavern; read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty
                ;;
            4)
                if [ "$IS_DEBIAN_LIKE" = true ]; then run_system_cleanup; read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty; else log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"; sleep 2; fi
                ;;
            q|Q) 
                echo -e "\n感谢使用，再见！"; exit 0 
                ;;
            *) 
                echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 2 
                ;;
        esac
    done
}

main_menu
