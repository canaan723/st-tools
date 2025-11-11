#!/usr/bin/env bash

# 咕咕助手 v2.45test
# 作者: 清绝 | 网址: blog.qjyg.de

# --- [核心] 确保脚本由 Bash 执行 ---
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 此脚本需要使用 bash 解释器运行。" >&2
    echo "请尝试使用: bash $0" >&2
    exit 1
fi
# --- -------------------------- ---

fn_ssh_rollback() {
    fn_print_tip "检测到新SSH端口连接失败，正在执行回滚操作..."
    # 采用更安全的 drop-in 配置后，回滚只需删除自定义文件
    if [ -f "/etc/ssh/sshd_config.d/99-custom-port.conf" ]; then
        rm -f "/etc/ssh/sshd_config.d/99-custom-port.conf"
        log_info "已移除自定义SSH端口配置文件。"
    elif [ -f "/etc/ssh/sshd_config.bak" ]; then
        # 保留对旧版修改方式的回滚兼容
        mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        log_info "已通过备份文件恢复 sshd_config。"
    fi
    systemctl restart sshd
    fn_print_ok "SSH配置已恢复到修改前状态。端口恢复正常。"
    log_info "脚本将退出。请检查云服务商的防火墙/NAT映射设置后重试。"
}

set -e
set -o pipefail

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

log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "\n${RED}✗ $1${NC}\n"; exit 1; }
log_action() { echo -e "${YELLOW}→ $1${NC}"; }
log_step() { echo -e "\n${BLUE}--- $1: $2 ---${NC}"; } # 暂时保留，后续可能进一步简化

# 新增简洁输出函数
fn_print_ok() { echo -e "${GREEN}✓ $1${NC}"; }
fn_print_tip() { echo -e "${CYAN}💡 $1${NC}"; }

fn_show_main_header() {
    echo -e "${YELLOW}>> ${GREEN}咕咕助手 v2.45test${NC}"
    echo -e "   ${BOLD}\033[0;37m作者: 清绝 | 网址: blog.qjyg.de${NC}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
       echo -e "\n${RED}错误: 此脚本需要 root 权限执行。${NC}"
       echo -e "请尝试使用 ${YELLOW}sudo bash $0${NC} 来运行。\n"
       exit 1
    fi
}

fn_check_base_deps() {
    local missing_pkgs=()
    local required_pkgs=("bc" "curl" "tar")

    log_info "正在检查基础依赖: ${required_pkgs[*]}..."
    for pkg in "${required_pkgs[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_action "检测到缺失的工具: ${missing_pkgs[*]}，正在尝试自动安装..."
        local install_cmd=""
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            apt-get update > /dev/null 2>&1
            install_cmd="apt-get install -y"
        elif command -v dnf &> /dev/null; then
            install_cmd="dnf install -y"
        elif command -v yum &> /dev/null; then
            install_cmd="yum install -y"
        fi

        if [ -n "$install_cmd" ]; then
            if ! $install_cmd "${missing_pkgs[@]}"; then
                log_error "部分基础依赖自动安装失败，请手动执行 '$install_cmd ${missing_pkgs[*]}' 后重试。"
            fi
            fn_print_ok "所有缺失的基础依赖已安装成功。"
        else
            log_error "您的系统 (${DETECTED_OS}) 不支持自动安装。请手动安装缺失的工具: ${missing_pkgs[*]}"
        fi
    else
        fn_print_ok "基础依赖完整。"
    fi
}


# 全局数组，用于存储 daemon.json 的配置项
DAEMON_JSON_PARTS=()

# 全局数组，定义所有可用的 Docker 镜像源
readonly DOCKER_MIRRORS=(
    "https://docker.1ms.run (北京)"
    "https://hub1.nat.tf (上海)"
    "https://docker.1panel.live (北京)"
    "https://dockerproxy.1panel.live (北京)"
    "https://hub.rat.dev"
    "https://docker.m.ixdev.cn (北京)"
    "https://hub2.nat.tf"
    "https://docker.1panel.dev"
    "https://docker.amingg.com (腾讯广州)"
    "https://docker.xuanyuan.me (腾讯上海)"
    "https://dytt.online"
    "https://lispy.org"
    "https://docker.xiaogenban1993.com"
    "https://docker-0.unsee.tech"
    "https://666860.xyz"
    "https://hubproxy-advj.onrender.com"
)

# Internal function to test Docker mirrors and return sorted results
fn_internal_test_mirrors() {
    log_info "正在自动检测 Docker 镜像源可用性..."
    # 将官方源和全局镜像列表合并进行测试
    local mirrors_to_test=("docker.io" "${DOCKER_MIRRORS[@]}")

    docker rmi hello-world > /dev/null 2>&1 || true
    local results=""; local official_hub_ok=false
    for full_mirror_entry in "${mirrors_to_test[@]}"; do
        # 从 "https://url.com (描述)" 中提取 URL
        local mirror_url; mirror_url=$(echo "$full_mirror_entry" | awk '{print $1}')
        
        local pull_target="hello-world"; local display_name="$full_mirror_entry"; local timeout_duration=10
        if [[ "$mirror_url" == "docker.io" ]]; then
            timeout_duration=15
            display_name="Official Docker Hub"
        else
            pull_target="${mirror_url#https://}/library/hello-world"
        fi
        
        echo -ne "  - 正在测试: ${YELLOW}${display_name}${NC}..."
        local start_time; start_time=$(date +%s.%N)
        if (timeout -k 15 "$timeout_duration" docker pull "$pull_target" >/dev/null) 2>/dev/null; then
            local end_time; end_time=$(date +%s.%N); local duration; duration=$(echo "$end_time - $start_time" | bc)
            printf " ${GREEN}%.2f 秒${NC}\n" "$duration"
            if [[ "$mirror_url" != "docker.io" ]]; then results+="${duration}|${mirror_url}|${display_name}\n"; fi
            docker rmi "$pull_target" > /dev/null 2>&1 || true
            if [[ "$mirror_url" == "docker.io" ]]; then official_hub_ok=true; break; fi
        else
            echo -e " ${RED}超时或失败${NC}"
        fi
    done

    if [ "$official_hub_ok" = true ]; then
        # Return a special value to indicate official hub is fine
        echo "OFFICIAL_HUB_OK"
    else
        # Return the sorted results
        if [ -n "$results" ]; then
            echo -e "$results" | grep '.' | LC_ALL=C sort -n
        fi
    fi
}

# Function to configure Docker logging settings
fn_configure_docker_logging() {
    log_action "限制 Docker 日志大小以防磁盘占满？"
    read -rp "推荐执行 [Y/n]: " confirm_log < /dev/tty
    if [[ "${confirm_log:-y}" =~ ^[Yy]$ ]]; then
        DAEMON_JSON_PARTS+=('"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}')
        fn_print_ok "已添加 Docker 日志限制配置 (10MB x 3个文件)。"
    else
        log_info "已跳过 Docker 日志限制配置。"
    fi
}

# Function to configure Docker registry mirrors
fn_configure_docker_mirrors() {
    log_action "配置 Docker 镜像加速？"
    read -rp "国内服务器推荐 [Y/n]: " confirm_mirror < /dev/tty
    if [[ ! "${confirm_mirror:-y}" =~ ^[Yy]$ ]]; then
        log_info "已跳过 Docker 镜像加速配置。"
        return
    fi

    echo -e "  [1] ${CYAN}自动测速${NC} (推荐，自动选择最快的可用镜像)"
    echo -e "  [2] ${CYAN}手动选择${NC} (从预设列表中选择一个或多个)"
    echo -e "  [3] ${CYAN}自定义填写${NC} (输入你自己的镜像地址)"
    read -rp "选择配置方式 [默认为 1]: " choice < /dev/tty
    choice=${choice:-1}

    local mirrors_json_array=""

    case "$choice" in
        1)
            local test_results; test_results=$(fn_internal_test_mirrors)
            if [[ "$test_results" == "OFFICIAL_HUB_OK" ]]; then
                fn_print_ok "官方 Docker Hub 可用，将直接使用官方源，不配置镜像加速。"
            else
                fn_print_tip "官方 Docker Hub 连接失败，将自动从可用备用镜像中配置最快的源。"
                if [ -n "$test_results" ]; then
                    local best_mirrors; best_mirrors=($(echo -e "$test_results" | head -n 3 | cut -d'|' -f2))
                    fn_print_ok "将配置最快的 ${#best_mirrors[@]} 个镜像源。"
                    mirrors_json_array=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//')
                else
                    fn_print_tip "所有备用镜像均测试失败！将不配置镜像加速。"
                fi
            fi
            ;;
        2)
            log_action "请从以下列表中选择一个或多个镜像源 (用空格分隔序号):"
            for i in "${!DOCKER_MIRRORS[@]}"; do
                echo "  [$((i+1))] ${DOCKER_MIRRORS[$i]}"
            done
            read -rp "输入序号: " -a selected_indices < /dev/tty
            local selected_mirrors=()
            for index in "${selected_indices[@]}"; do
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#DOCKER_MIRRORS[@]}" ]; then
                    # 从 "https://url.com (描述)" 中提取 URL
                    selected_mirrors+=("$(echo "${DOCKER_MIRRORS[$((index-1))]}" | awk '{print $1}')")
                fi
            done
            if [ ${#selected_mirrors[@]} -gt 0 ]; then
                fn_print_ok "已选择 ${#selected_mirrors[@]} 个镜像源。"
                mirrors_json_array=$(printf '"%s",' "${selected_mirrors[@]}" | sed 's/,$//')
            else
                fn_print_tip "未选择任何有效的镜像源。"
            fi
            ;;
        3)
            log_action "输入自定义 Docker 镜像地址 (例如: https://docker.my-mirror.com):"
            read -rp "> " custom_mirror < /dev/tty
            if [ -n "$custom_mirror" ]; then
                fn_print_ok "已设置自定义镜像源。"
                mirrors_json_array="\"$custom_mirror\""
            else
                fn_print_tip "输入为空，未配置自定义镜像源。"
            fi
            ;;
        *)
            fn_print_tip "无效输入，将不配置 Docker 镜像加速。"
            ;;
    esac

    if [ -n "$mirrors_json_array" ]; then
        DAEMON_JSON_PARTS+=("\"registry-mirrors\": [${mirrors_json_array}]")
        fn_print_ok "已添加 Docker 镜像加速配置。"
    fi
}

# Main function to orchestrate Docker optimizations
fn_optimize_docker() {
    log_step "步骤" "Docker 优化配置 (可选)"
    
    DAEMON_JSON_PARTS=() # Reset config parts array

    fn_configure_docker_logging
    echo # Add a newline for better readability
    fn_configure_docker_mirrors

    fn_apply_docker_optimization
}

fn_apply_docker_optimization() {
    if [ ${#DAEMON_JSON_PARTS[@]} -eq 0 ]; then
        log_info "没有需要应用的 Docker 配置，已跳过。"
        return
    fi

    local DAEMON_JSON="/etc/docker/daemon.json"
    log_action "正在应用 Docker 优化配置..."

    if [ -f "$DAEMON_JSON" ]; then
        fn_print_tip "检测到现有的 Docker 配置文件 ${DAEMON_JSON}。"
        fn_print_tip "此操作将覆盖现有配置，请注意备份。"
        read -rp "确认覆盖并继续? [Y/n]: " confirm_overwrite < /dev/tty
        if [[ ! "${confirm_overwrite:-y}" =~ ^[Yy]$ ]]; then
            log_info "已取消 Docker 优化配置，未修改 ${DAEMON_JSON}。"
            return
        fi
    fi
    
    # 逐行生成格式化的 JSON 文件，确保格式正确
    {
        echo "{"
        local last_idx=$((${#DAEMON_JSON_PARTS[@]} - 1))
        for i in "${!DAEMON_JSON_PARTS[@]}"; do
            local part="${DAEMON_JSON_PARTS[$i]}"
            if [ "$i" -eq "$last_idx" ]; then
                echo "  $part"
            else
                echo "  $part,"
            fi
        done
        echo "}"
    } | sudo tee "$DAEMON_JSON" > /dev/null
 
     if sudo systemctl restart docker; then
        fn_print_ok "Docker 服务已重启，优化配置已生效！"
    else
        log_error "Docker 服务重启失败！请检查 ${DAEMON_JSON} 格式。"
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
    read -rp "确认继续? [Y/n]: " confirm < /dev/tty
    if [[ ! "${confirm:-y}" =~ ^[Yy]$ ]]; then
        log_info "操作已取消。"
        return
    fi

    log_info "正在清理 apt 缓存..."
    apt-get clean -y
    fn_print_ok "apt 缓存清理完成。"

    log_info "正在压缩 journald 日志..."
    journalctl --vacuum-size=100M
    fn_print_ok "journald 日志压缩完成。"

    if command -v docker &> /dev/null; then
        log_info "正在清理 Docker 系统..."
        docker system prune -f
        fn_print_ok "Docker 系统清理完成。"
    else
        fn_print_tip "未检测到 Docker，已跳过 Docker 系统清理步骤。"
    fi
 
    fn_print_ok "系统安全清理已全部完成！"
}


create_dynamic_swap() {
    if [ -f /swapfile ]; then
        log_info "Swap 文件 /swapfile 已存在，跳过创建。"
        return 0
    fi

    local mem_total_mb
    mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')

    local swap_size_mb
    local swap_size_display

    if [ "$mem_total_mb" -lt 1024 ]; then
        swap_size_mb=$((mem_total_mb * 2))
    else
        swap_size_mb=2048
    fi

    swap_size_display=$(echo "scale=1; $swap_size_mb / 1024" | bc | sed 's/^\./0./')G

    log_action "检测到物理内存为 ${mem_total_mb}MB，将创建 ${swap_size_display} 的 Swap 文件..."
    fallocate -l "${swap_size_mb}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fn_print_ok "Swap 文件创建、启用并已设置为开机自启。"
}


fn_init_prepare_firewall() {
    fn_print_tip "请在云服务商控制台放行以下端口："
    echo -e "  - ${YELLOW}22${NC}: 当前SSH端口"
    echo -e "  - ${YELLOW}新高位端口${NC}: 范围 ${GREEN}49152-65535${NC} (用于新SSH端口)"
    fn_print_tip "未放行新SSH端口将导致连接失败！"
    read -rp "确认已放行? [Y/n]: " confirm < /dev/tty
}

fn_init_set_timezone() {
    log_action "设置时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai
    fn_print_ok "时区已设为 Asia/Shanghai。当前时间: $(date +"%H:%M:%S")"
}

fn_init_change_ssh_port() {
    fn_print_tip "更改默认22端口，降低被攻击风险。"
    read -rp "新SSH端口 (49152-65535): " NEW_SSH_PORT < /dev/tty
    if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 49152 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
        log_error "端口无效。请输 49152-65535 之间的数字。"
    fi
    
    local ssh_config_dir="/etc/ssh/sshd_config.d"
    local custom_config_file="${ssh_config_dir}/99-custom-port.conf"
    
    log_action "创建SSH端口配置文件 ${custom_config_file}..."
    mkdir -p "$ssh_config_dir"
    echo "Port $NEW_SSH_PORT" > "$custom_config_file"
    
    fn_print_ok "SSH端口已更新为 ${NEW_SSH_PORT}。"
    export NEW_SSH_PORT
}

fn_init_install_fail2ban() {
    fn_print_tip "安装 Fail2ban，自动阻止恶意登录IP。"
    if command -v fail2ban-client &> /dev/null; then
        fn_print_ok "Fail2ban 已安装并启用。"
        systemctl enable --now fail2ban
        return 0
    fi

    log_action "安装 Fail2ban..."
    apt-get update > /dev/null 2>&1
    apt-get install -y fail2ban > /dev/null 2>&1
    systemctl enable --now fail2ban
    fn_print_ok "Fail2ban 安装并设为开机自启。"
}

fn_init_configure_fail2ban() {
    fn_print_tip "配置 Fail2ban 监控新 SSH 端口，增强安全。"
    if [ -z "$NEW_SSH_PORT" ]; then
        fn_print_tip "未设新 SSH 端口，跳过 Fail2ban 配置。"
        return 0
    fi

    local jail_local_path="/etc/fail2ban/jail.local"
    log_action "更新 Fail2ban 配置 ${jail_local_path}..."

    cat <<EOF | sudo tee "$jail_local_path" > /dev/null
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime = 3600
findtime = 300
maxretry = 5

[sshd]
enabled = true
filter = sshd
port = $NEW_SSH_PORT
logpath = /var/log/auth.log
action = %(action_)s[port="%(port)s", protocol="%(protocol)s", logpath="%(logpath)s", chain="%(chain)s"]
banaction = iptables-multiport
EOF

    if [ $? -eq 0 ]; then
        fn_print_ok "Fail2ban 已配置监控端口 ${NEW_SSH_PORT}。"
        log_action "重启 Fail2ban 服务..."
        systemctl restart fail2ban
        fn_print_ok "Fail2ban 服务已重启。"
    else
        log_error "更新 Fail2ban 配置失败。"
    fi
}
 
fn_init_validate_ssh() {
    if [ -z "$NEW_SSH_PORT" ]; then
        log_error "未设新 SSH 端口，无法验证。"
        return 1
    fi
    
    log_action "重启 SSH 服务以应用新端口 ${NEW_SSH_PORT}..."
    systemctl restart sshd
    fn_print_tip "SSH 服务已重启。请立即验证新端口连通性。"

    echo -e "\n${BOLD}${YELLOW}--- 重要提示 ---${NC}"
    echo -e "请立即打开新终端，用新端口 ${GREEN}${NEW_SSH_PORT}${NC} 连接服务器。"
    echo -e "${BOLD}${YELLOW}----------------${NC}\n"

    while true; do
        read -rp "新端口连接成功? [Y/n]: " choice < /dev/tty
        case $choice in
            "" | [Yy]* )
                fn_print_ok "新端口可用。SSH 端口已成功更换为 ${NEW_SSH_PORT}！"
                rm -f /etc/ssh/sshd_config.bak
                break
                ;;
            [Nn]* )
                fn_ssh_rollback
                exit 1
                ;;
            * )
                fn_print_tip "无效输入。请按 Y/n。"
                ;;
        esac
    done
}

fn_init_upgrade_system() {
    fn_print_tip "应用最新安全补丁和软件更新。"
    log_action "系统升级中 (可能较久)..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" > /dev/null 2>&1
    fn_print_ok "所有软件包已升级。"
}

fn_init_optimize_kernel() {
    fn_print_tip "启用 BBR 优化网络，创建 Swap 防内存溢出。"
    log_action "添加内核配置到 /etc/sysctl.conf..."
    sed -i -e '/net.core.default_qdisc=fq/d' \
           -e '/net.ipv4.tcp_congestion_control=bbr/d' \
           -e '/vm.swappiness=10/d' /etc/sysctl.conf
    cat <<EOF >> /etc/sysctl.conf
 
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
    fn_print_ok "内核参数配置完成。"

    create_dynamic_swap
}

run_initialization() {
    tput reset
    echo -e "${CYAN}--- 服务器初始化 ---${NC}"
    fn_print_tip "此流程将对服务器进行安全加固和系统优化。"

    fn_check_base_deps

    local init_step_funcs=(
        "fn_init_upgrade_system"
        "fn_init_prepare_firewall"
        "fn_init_change_ssh_port"
        "fn_init_validate_ssh"
        "fn_init_install_fail2ban"
        "fn_init_configure_fail2ban" # 配置 Fail2ban
        "fn_init_set_timezone"
        "fn_init_optimize_kernel"
    )
    local init_step_descs=(
        "系统升级 (安全补丁)"
        "防火墙准备 (端口放行提醒)"
        "修改 SSH 端口 (增强安全)"
        "验证新 SSH 端口"
        "安装 Fail2ban (防暴力破解)"
        "配置 Fail2ban (监控新端口)"
        "设置系统时区 (Asia/Shanghai)"
        "优化内核 (BBR, Swap)"
    )

    local ssh_port_changed=false
    local kernel_optimized=false
    local reboot_needed=false

    for i in "${!init_step_funcs[@]}"; do
        local step_func="${init_step_funcs[$i]}"
        local step_desc="${init_step_descs[$i]}"
        
        if [[ "$step_func" == "fn_init_validate_ssh" && "$ssh_port_changed" == false ]]; then
            fn_print_tip "未修改 SSH 端口，跳过 [验证新 SSH 端口]。"
            continue
        fi

        echo
        log_action "要执行 [${step_desc}] 吗?"
        read -rp "确认? [Y/n]: " confirm_step < /dev/tty
        if [[ ! "${confirm_step:-y}" =~ ^[Yy]$ ]]; then
            fn_print_tip "跳过: ${step_desc}"
            continue
        fi

        log_step "$((i + 1))/${#init_step_funcs[@]}" "${step_desc}"
        "$step_func"

        if [[ "$step_func" == "fn_init_change_ssh_port" ]]; then ssh_port_changed=true; fi
        if [[ "$step_func" == "fn_init_optimize_kernel" || "$step_func" == "fn_init_upgrade_system" ]]; then reboot_needed=true; fi
        if [[ "$step_func" == "fn_init_optimize_kernel" ]]; then kernel_optimized=true; fi
    done

    echo
    log_step "收尾" "应用配置与重启"

    if [[ "$kernel_optimized" == true ]]; then
        log_action "应用内核参数..."
        sysctl -p
        fn_print_ok "内核参数已应用。"
    fi

    if [[ "$reboot_needed" == false && "$ssh_port_changed" == false ]]; then
        fn_print_ok "所有步骤完成，无需特殊操作。"
        return 0
    fi
    
    fn_print_tip "部分更改需重启生效。建议重启服务器。"
    local post_reboot_guide=""
    if [[ "$ssh_port_changed" == true ]]; then post_reboot_guide+="\n  - ${YELLOW}安全提示:${NC} 重启后请用新端口 ${GREEN}${NEW_SSH_PORT}${NC} 登录, 确认正常后${BOLD}移除旧的22端口规则${NC}。"; fi
    if [[ "$kernel_optimized" == true ]]; then post_reboot_guide+="\n  - ${YELLOW}验证提示:${NC} 重启后可执行 'sudo sysctl net.ipv4.tcp_congestion_control && free -h' 检查BBR和Swap。"; fi
    if [[ -n "$post_reboot_guide" ]]; then echo -e "\n${BLUE}--- 重启后指南 ---${NC}${post_reboot_guide}"; fi

    read -rp $'\n立即重启服务器? [Y/n]: ' REPLY < /dev/tty
    echo

    if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
        log_info "服务器将立即重启..."
        reboot
        exit 0
    else
        fn_print_tip "已选择稍后重启。请手动执行 'sudo reboot'。"
    fi
}

install_1panel() {
    tput reset
    echo -e "${CYAN}--- 安装 1Panel 面板 ---${NC}"
    fn_print_tip "此流程将安装 1Panel 面板，并自动安装 Docker。"
    
    if ! command -v curl &> /dev/null; then
        log_action "未检测到 curl，尝试安装..."
        apt-get update > /dev/null 2>&1 && apt-get install -y curl > /dev/null 2>&1
        if ! command -v curl &> /dev/null; then
            log_error "curl 安装失败，请手动安装后再试。"
        fi
    fi

    log_step "1" "运行 1Panel 官方安装脚本"
    fn_print_tip "即将进入 1Panel 交互式安装界面，请按提示操作。"
    read -rp "按 Enter 开始安装 1Panel..." < /dev/tty
    bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
    
    log_step "2" "检查 Docker 安装情况"
    if ! command -v docker &> /dev/null; then
        fn_print_tip "1Panel 安装后未检测到 Docker。"
        log_action "尝试使用备用脚本安装 Docker..."
        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
        
        if ! command -v docker &> /dev/null; then
            log_error "备用脚本也未能安装 Docker。请检查网络或手动安装。"
        else
            fn_print_ok "备用脚本成功安装 Docker！"
        fi
    else
        fn_print_ok "Docker 已成功安装。"
    fi

    log_step "3" "配置用户 Docker 权限"
    local REAL_USER="${SUDO_USER:-$(whoami)}"
    if [ "$REAL_USER" != "root" ]; then
        if groups "$REAL_USER" | grep -q '\bdocker\b'; then
            fn_print_tip "用户 '${REAL_USER}' 已在 docker 用户组。"
        else
            log_action "将用户 '${REAL_USER}' 添加到 docker 用户组..."
            usermod -aG docker "$REAL_USER"
            fn_print_ok "添加成功！"
            fn_print_tip "用户组更改需【重新登录SSH】才能生效！"
            fn_print_tip "否则下一步可能出现 Docker 权限错误。"
        fi
    else
         fn_print_tip "以 root 用户运行，无需添加到 docker 用户组。"
    fi

    echo -e "\n${CYAN}--- 1Panel 安装完成 ---${NC}"
    fn_print_tip "重要：请牢记 1Panel 访问地址、端口、账号和密码。"
    fn_print_tip "确保云服务商防火墙/安全组中 ${GREEN}已放行 1Panel 端口${NC}。"
    fn_print_tip "可重新运行本脚本，选择【部署 SillyTavern】。"
    fn_print_tip "若有用户被添加到 docker 组，请务必先退出并重新登录SSH！"
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
    fn_print_tip "未能自动获取到公网IP地址。" >&2
    log_info "这不影响部署结果，SillyTavern容器已成功在后台运行。" >&2
    
    echo "【请手动替换为你的服务器IP】"
    return 1
}

install_sillytavern() {
    local DOCKER_VER="-" DOCKER_STATUS="-"
    local COMPOSE_VER="-" COMPOSE_STATUS="-"
    local CONTAINER_NAME="sillytavern"
    local IMAGE_NAME="ghcr.io/sillytavern/sillytavern:latest"

    # fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; } # 已替换为 log_step

    fn_check_existing_container() {
        if docker ps -a -q -f "name=^${CONTAINER_NAME}$" | grep -q .; then
            fn_print_tip "检测到服务器上已存在一个名为 '${CONTAINER_NAME}' 的 Docker 容器。"
            log_info "这可能来自之前的安装。若要继续，必须先处理现有容器。"
            echo -e "请选择操作："
            echo -e "  [1] ${YELLOW}停止并移除现有容器，然后继续全新安装 (此操作不删除数据文件)${NC}"
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
                    fn_print_ok "现有容器已成功移除。"
                    ;;
                2)
                    log_info "脚本已退出。请手动执行 'docker ps -a' 查看容器状态。"
                    exit 0
                    ;;
            esac
        fi
    }

    fn_report_dependencies() {
        log_info "--- Docker 环境诊断摘要 ---"
        printf "${BOLD}%-18s %-20s %-20s${NC}\n" "工具" "检测到的版本" "状态"
        printf "${CYAN}%-18s %-20s %-20s${NC}\n" "------------------" "--------------------" "--------------------"
        print_status_line() {
            local name="$1" version="$2" status="$3"
            local color="$GREEN"
            if [[ "$status" == "Not Found" ]]; then color="$RED"; fi
            printf "%-18s %-20s ${color}%-20s${NC}\n" "$name" "$version" "$status"
        }
        print_status_line "Docker" "$DOCKER_VER" "$DOCKER_STATUS"
        print_status_line "Docker Compose" "$COMPOSE_VER" "$COMPOSE_STATUS"
        echo ""
    }

    fn_get_cleaned_version_num() { echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }

    fn_check_dependencies() {
        log_info "--- Docker 环境诊断开始 ---"
        
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
                    fn_print_tip "未检测到 Docker 或 Docker-Compose。"
                    read -rp "是否立即尝试自动安装 Docker? [Y/n]: " confirm_install_docker < /dev/tty
                    if [[ "${confirm_install_docker:-y}" =~ ^[Yy]$ ]]; then
                        log_action "正在使用官方推荐脚本安装 Docker..."
                        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
                        continue
                    else
                        log_error "用户选择不安装 Docker，脚本无法继续。"
                    fi
                else
                    log_error "未检测到 Docker 或 Docker-Compose。请在您的系统 (${DETECTED_OS}) 上手动安装它们后重试。"
                fi
            else
                docker_check_needed=false
            fi
        done

        fn_report_dependencies

        local current_user="${SUDO_USER:-$(whoami)}"
        if ! groups "$current_user" | grep -q '\bdocker\b' && [ "$(id -u)" -ne 0 ]; then
            log_error "当前用户不在 docker 用户组。请执行【步骤2】或手动添加后，【重新登录SSH】再试。"
        fi
        fn_print_ok "Docker 环境检查通过！"
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
    
    fn_confirm_and_delete_dir() {
        local dir_to_delete="$1"
        local container_name="$2"
        log_warn "目录 '$dir_to_delete' 已存在，可能包含之前的聊天记录和角色卡。"
        read -r -p "确定要【彻底清理】并继续安装吗？此操作会停止并删除旧容器。[Y/n]: " c1 < /dev/tty
        if [[ ! "${c1:-y}" =~ ^[Yy]$ ]]; then log_error "操作被用户取消。"; fi
        read -r -p "$(echo -e "${YELLOW}警告：此操作将永久删除该目录下的所有数据！请再次确认 [Y/n]: ${NC}")" c2 < /dev/tty
        if [[ ! "${c2:-y}" =~ ^[Yy]$ ]]; then log_error "操作被用户取消。"; fi
        read -r -p "$(echo -e "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}")" c3 < /dev/tty
        if [[ "$c3" != "yes" ]]; then log_error "操作被用户取消。"; fi
        log_info "正在停止并移除旧容器: $container_name..."
        docker stop "$container_name" > /dev/null 2>&1 || true
        docker rm "$container_name" > /dev/null 2>&1 || true
        fn_print_ok "旧容器已停止并移除。"
        log_info "正在删除旧目录: $dir_to_delete..."
        sudo rm -rf "$dir_to_delete"
        fn_print_ok "旧目录已彻底清理。"
    }

    fn_create_project_structure() {
        log_info "正在创建项目目录结构..."
        mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
        log_info "正在设置文件所有权..."
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
        fn_print_ok "项目目录创建并授权成功！"
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
            log_error "请根据以上日志排查问题，可能原因包括网络不通、镜像源失效或 Docker 服务异常。"
        else
            rm -f "$PULL_LOG"
            fn_print_ok "镜像拉取成功！"
        fi
    }

    fn_verify_container_health() {
        local container_name="$1"
        local retries=10
        local interval=3
        local spinner="/-\|"
        log_info "正在确认容器健康状态..."
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
        log_info "以下是容器的最新日志，以帮助诊断问题："
        echo -e "${YELLOW}--- 容器日志开始 ---${NC}"
        docker logs "$container_name" --tail 50 || echo "无法获取容器日志。"
        echo -e "${YELLOW}--- 容器日志结束 ---${NC}"
        log_error "部署失败。请检查以上日志以确定问题原因。"
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
            running) fn_print_ok "状态正常：容器正在健康运行。";;
            restarting) fn_print_tip "状态异常：容器正在无限重启。"; fn_print_info "通常意味着程序内部崩溃。请使用 [2] 查看日志定位错误。";;
            exited) echo -e "${RED}状态错误：容器已停止运行。${NC}"; log_info "通常是由于启动时发生致命错误。请使用 [2] 查看日志获取错误信息。";;
            notfound) echo -e "${RED}未能找到名为 '${container_name}' 的容器。${NC}";;
            *) fn_print_tip "状态未知：容器处于 '${status}' 状态。"; fn_print_info "建议使用 [2] 查看日志进行诊断。";;
        esac
    }

    fn_display_final_info() {
        echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "║                   ${BOLD}部署成功！尽情享受吧！${NC}                   ║"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo -e "\n  ${CYAN}访问地址:${NC} ${GREEN}http://${SERVER_IP}:8000${NC}"
        
        if [[ "$run_mode" == "1" ]]; then
            echo -e "  ${CYAN}登录账号:${NC} ${YELLOW}${single_user}${NC}"
            echo -e "  ${CYAN}登录密码:${NC} ${YELLOW}${single_pass}${NC}"
        elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
            echo -e "  ${YELLOW}登录页面:${NC} ${GREEN}http://${SERVER_IP}:8000/login${NC}"
        fi
        
        echo -e "  ${CYAN}项目路径:${NC} $INSTALL_DIR"
    }


    tput reset
    echo -e "${CYAN}SillyTavern Docker 自动化安装流程${NC}"

    log_step "1/5" "环境检查与准备"
    fn_check_base_deps
    
    TARGET_USER="${SUDO_USER:-root}"
    if [ "$TARGET_USER" = "root" ]; then
        USER_HOME="/root"
        fn_print_tip "检测到以 root 用户运行，将安装在 /root 目录。"
    else
        USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        if [ -z "$USER_HOME" ]; then fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"; fi
    fi
    INSTALL_DIR="$USER_HOME/sillytavern"
    CONFIG_FILE="$INSTALL_DIR/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    
    fn_check_dependencies

    fn_check_existing_container

    fn_optimize_docker
    
    SERVER_IP=$(fn_get_public_ip)

    log_step "2/5" "选择运行模式与路径"

    echo "选择运行模式："
    echo -e "  [1] ${CYAN}单用户模式${NC} (弹窗认证，适合个人使用)"
    echo -e "  [2] ${CYAN}多用户模式${NC} (独立登录页，适合多人或单人使用)"
    echo -e "  [3] ${RED}维护者模式${NC} (作者专用，普通用户请勿选择！)"
    read -p "请输入选项数字 [默认为 1]: " run_mode < /dev/tty
    run_mode=${run_mode:-1}

    case "$run_mode" in
        1)
            read -p "请输入自定义用户名: " single_user < /dev/tty
            read -p "请输入自定义密码: " single_pass < /dev/tty
            if [ -z "$single_user" ] || [ -z "$single_pass" ]; then log_error "用户名和密码不能为空！"; fi
            ;;
        2)
            ;;
        3)
            fn_print_tip "已进入维护者模式，此模式需要手动准备特殊文件。"
            ;;
        *)
            log_error "无效输入，脚本已终止."
            ;;
    esac

    local default_parent_path="$USER_HOME"
    read -rp "安装路径: SillyTavern 将被安装在 <上级目录>/sillytavern 中。请输入上级目录 [直接回车=默认: $USER_HOME]:" custom_parent_path < /dev/tty
    local parent_path="${custom_parent_path:-$default_parent_path}"
    INSTALL_DIR="${parent_path}/sillytavern"
    log_info "安装路径最终设置为: ${INSTALL_DIR}"

    CONFIG_FILE="$INSTALL_DIR/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

    log_step "3/5" "创建项目文件"
    if [ -d "$INSTALL_DIR" ]; then
        fn_confirm_and_delete_dir "$INSTALL_DIR" "$CONTAINER_NAME"
    fi

    if [[ "$run_mode" == "3" ]]; then
        log_info "正在创建开发者模式项目目录结构..."
        mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
        mkdir -p "$INSTALL_DIR/custom/images"
        touch "$INSTALL_DIR/custom/login.html"
        log_info "正在设置文件所有权..."
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
        fn_print_ok "开发者项目目录创建并授权成功！"
    else
        fn_create_project_structure
    fi

    cd "$INSTALL_DIR"
    log_info "工作目录已切换至: $(pwd)"

    if [[ "$run_mode" == "3" ]]; then
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
    fn_print_ok "docker-compose.yml 文件创建成功！"

    if [[ "$run_mode" == "3" ]]; then
        fn_print_tip "维护者模式：请现在将您的自定义文件 (如 login.html) 放入 '$INSTALL_DIR/custom' 目录。"
        read -rp "文件放置完毕后，按 Enter 键继续..." < /dev/tty
    fi

    log_step "4/5" "初始化与配置"
    log_info "即将拉取 SillyTavern 镜像，下载期间将持续显示预估时间。"
    TIME_ESTIMATE_TABLE=$(cat <<EOF
  下载速度取决于网络带宽，以下为预估时间参考：
  ${YELLOW}┌──────────────────────────────────────────────────┐${NC}
  ${YELLOW}│${NC} ${CYAN}带宽${NC}      ${BOLD}|${NC} ${CYAN}下载速度${NC}    ${BOLD}|${NC} ${CYAN}预估最快时间${NC}           ${YELLOW}│${NC}
  ${YELLOW}├──────────────────────────────────────────────────┤${NC}
  ${YELLOW}│${NC} 1M 带宽   ${BOLD}|${NC} ~0.125 MB/s ${BOLD}|${NC} 约 1 小时 14 分 31 秒 ${YELLOW}│${NC}
  ${YELLOW}│${NC} 2M 带宽   ${BOLD}|${NC} ~0.25 MB/s  ${BOLD}|${NC} 约 37 分 15 秒        ${YELLOW}│${NC}
  ${YELLOW}│${NC} 10M 带宽  ${BOLD}|${NC} ~1.25 MB/s  ${BOLD}|${NC} 约 7 分 27 秒         ${YELLOW}│${NC}
  ${YELLOW}│${NC} 100M 带宽 ${BOLD}|${NC} ~12.5 MB/s  ${BOLD}|${NC} 约 45 秒              ${YELLOW}│${NC}
  ${YELLOW}└──────────────────────────────────────────────────┘${NC}
EOF
)
    fn_pull_with_progress_bar "$COMPOSE_FILE" "$DOCKER_COMPOSE_CMD" "$TIME_ESTIMATE_TABLE"
    log_info "正在进行首次启动以生成官方配置文件..."
    if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null 2>&1; then
        log_error "首次启动容器失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
    fi
    local timeout=60
    while [ ! -f "$CONFIG_FILE" ]; do
        if [ $timeout -eq 0 ]; then
            log_error "等待配置文件生成超时！请检查日志输出：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
        fi
        sleep 1
        ((timeout--))
    done
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" down > /dev/null 2>&1
    fn_print_ok "config.yaml 文件已生成！"
    
    fn_apply_config_changes
    if [[ "$run_mode" == "1" ]]; then
        fn_print_ok "单用户模式配置写入完成！"
    else
        log_info "正在临时启动服务以设置管理员..."
        if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null 2>&1; then
            log_error "临时启动容器以设置管理员失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
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
        log_info "正在切换到多用户登录页模式..."
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false # 关闭基础认证，启用登录页/" "$CONFIG_FILE"
        sed -i -E "s/^([[:space:]]*)enableDiscreetLogin: .*/\1enableDiscreetLogin: true # 隐藏登录用户列表/" "$CONFIG_FILE"
        fn_print_ok "多用户模式配置写入完成！"
    fi

    log_step "5/5" "启动并验证服务"
    log_info "正在应用最终配置并重启服务..."
    if ! $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate > /dev/null 2>&1; then
        log_error "应用最终配置并启动服务失败！请检查以下日志：\n$($DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail 50)"
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
            *) fn_print_tip "无效输入，请输入 1, 2, 3 或 q。";;
        esac
    done
}

main_menu() {
    while true; do
        tput reset
        fn_show_main_header
        echo

        # 简化系统兼容性提示和使用说明
        if [ "$IS_DEBIAN_LIKE" = false ]; then
            fn_print_tip "系统: ${DETECTED_OS}。部分功能仅支持 Debian/Ubuntu。"
            fn_print_tip "可用: [3] 部署 SillyTavern (需手动安装 Docker/Compose)。"
        else
            fn_print_tip "全新服务器: 建议 1 -> 2 -> 3 顺序执行。"
            fn_print_tip "已有 Docker: 可直接从 [3] 开始。"
        fi

        echo -e "\n${BLUE}--- 菜单 ---${NC}"
        
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            echo -e " ${GREEN}[1] 服务器初始化 (安全、优化)${NC}"
            echo -e " ${GREEN}[2] 安装 1Panel 面板 (含 Docker)${NC}"
        fi
        
        echo -e " ${GREEN}[3] 部署 SillyTavern (Docker 版)${NC}"
        
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            echo -e " ${CYAN}[4] 系统清理 (缓存、Docker 垃圾)${NC}"
        fi

        echo -e "${BLUE}------------${NC}"
        echo -e " ${YELLOW}[q] 退出${NC}\n"

        local options_str="3"
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            options_str="1,2,3,4"
        fi
        local valid_options="${options_str},q"
        read -rp "请输入选项 [${valid_options}]: " choice < /dev/tty

        case "$choice" in
            1) 
                if [ "$IS_DEBIAN_LIKE" = true ]; then 
                    check_root
                    run_initialization
                    read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty
                else 
                    fn_print_tip "您的系统 (${DETECTED_OS}) 不支持此功能。"
                    sleep 2
                fi
                ;;
            2) 
                if [ "$IS_DEBIAN_LIKE" = true ]; then 
                    check_root
                    install_1panel
                    while read -r -t 0.1; do :; done
                    read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty
                else 
                    fn_print_tip "您的系统 (${DETECTED_OS}) 不支持此功能。"
                    sleep 2
                fi
                ;;
            3) 
                check_root
                install_sillytavern
                while read -r -t 0.1; do :; done
                read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty
                ;;
            4)
                if [ "$IS_DEBIAN_LIKE" = true ]; then 
                    check_root
                    run_system_cleanup
                    while read -r -t 0.1; do :; done
                    read -rp $'\n操作完成，按 Enter 键返回主菜单...' < /dev/tty
                else 
                    fn_print_tip "您的系统 (${DETECTED_OS}) 不支持此功能。"
                    sleep 2
                fi
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
