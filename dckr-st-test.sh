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
    log_warn "检测到新SSH端口连接失败，正在执行回滚操作..."
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
    log_success "SSH配置已恢复到修改前状态。端口恢复正常。"
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
log_success() { echo -e "${GREEN}✓ $1${NC}"; }

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
        if [ "$IS_DEBIAN_LIKE" = true ]; then
            apt-get update > /dev/null 2>&1
            if ! apt-get install -y "${missing_pkgs[@]}"; then
                log_error "部分基础依赖自动安装失败，请手动执行 'apt-get install -y ${missing_pkgs[*]}' 后重试。"
            fi
            log_success "所有缺失的基础依赖已安装成功。"
        else
            log_error "您的系统 (${DETECTED_OS}) 不支持自动安装。请手动安装缺失的工具: ${missing_pkgs[*]}"
        fi
    else
        log_success "基础依赖完整。"
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
        DAEMON_JSON_PARTS+=('"log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}')
        log_success "已添加 Docker 日志限制配置。"
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
                log_success "官方 Docker Hub 可用，将直接使用官方源，不配置镜像加速。"
            else
                log_warn "官方 Docker Hub 连接失败，将自动从可用备用镜像中配置最快的源。"
                if [ -n "$test_results" ]; then
                    local best_mirrors; best_mirrors=($(echo -e "$test_results" | head -n 3 | cut -d'|' -f2))
                    log_success "将配置最快的 ${#best_mirrors[@]} 个镜像源。"
                    mirrors_json_array=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//')
                else
                    log_warn "所有备用镜像均测试失败！将不配置镜像加速。"
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
                log_success "已选择 ${#selected_mirrors[@]} 个镜像源。"
                mirrors_json_array=$(printf '"%s",' "${selected_mirrors[@]}" | sed 's/,$//')
            else
                log_warn "未选择任何有效的镜像源。"
            fi
            ;;
        3)
            log_action "输入自定义 Docker 镜像地址 (例如: https://docker.my-mirror.com):"
            read -rp "> " custom_mirror < /dev/tty
            if [ -n "$custom_mirror" ]; then
                log_success "已设置自定义镜像源。"
                mirrors_json_array="\"$custom_mirror\""
            else
                log_warn "输入为空，未配置自定义镜像源。"
            fi
            ;;
        *)
            log_warn "无效输入，将不配置 Docker 镜像加速。"
            ;;
    esac

    if [ -n "$mirrors_json_array" ]; then
        DAEMON_JSON_PARTS+=("\"registry-mirrors\": [${mirrors_json_array}]")
        log_success "已添加 Docker 镜像加速配置。"
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

    local final_json_content
    final_json_content=$(printf ", %s" "${DAEMON_JSON_PARTS[@]}")
    final_json_content="{ ${final_json_content:2} }" # Remove leading comma and space
 
    local DAEMON_JSON="/etc/docker/daemon.json"
    log_action "正在应用 Docker 优化配置..."

    if [ -f "$DAEMON_JSON" ]; then
        log_warn "检测到现有的 Docker 配置文件 ${DAEMON_JSON}。"
        log_warn "此操作将覆盖现有配置，请注意备份。"
        read -rp "确认覆盖并继续? [Y/n]: " confirm_overwrite < /dev/tty
        if [[ ! "${confirm_overwrite:-y}" =~ ^[Yy]$ ]]; then
            log_info "已取消 Docker 优化配置，未修改 ${DAEMON_JSON}。"
            return
        fi
    fi
    
    echo "$final_json_content" | sudo tee "$DAEMON_JSON" > /dev/null
    if sudo systemctl restart docker; then
        log_success "Docker 服务已重启，优化配置已生效！"
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
    log_success "Swap 文件创建、启用并已设置为开机自启。"
}


fn_init_prepare_firewall() {
    fn_print_tip "请在云服务商控制台放行以下端口："
    fn_print_info "- ${YELLOW}22${NC}: 当前SSH端口"
    fn_print_info "- ${YELLOW}新高位端口${NC}: 范围 ${GREEN}49152-65535${NC} (用于新SSH端口)"
    log_warn "未放行新SSH端口将导致连接失败！"
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
                log_warn "无效输入。请按 Y/n。"
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
    log_warn "即将进入 1Panel 交互式安装界面，请按提示操作。"
    read -rp "按 Enter 开始安装 1Panel..." < /dev/tty
    bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
    
    log_step "2" "检查 Docker 安装情况"
    if ! command -v docker &> /dev/null; then
        log_warn "1Panel 安装后未检测到 Docker。"
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
            log_warn "用户组更改需【重新登录SSH】才能生效！"
            log_warn "否则下一步可能出现 Docker 权限错误。"
        fi
    else
         fn_print_tip "以 root 用户运行，无需添加到 docker 用户组。"
    fi

    echo -e "\n${CYAN}--- 1Panel 安装完成 ---${NC}"
    log_warn "重要：请牢记 1Panel 访问地址、端口、账号和密码。"
    log_warn "确保云服务商防火墙/安全组中 ${GREEN}已放行 1Panel 端口${NC}。"
    fn_print_tip "可重新运行本脚本，选择【部署 SillyTavern】。"
    log_warn "若有用户被添加到 docker 组，请务必先退出并重新登录SSH！"
}

# --- SillyTavern 安装流程的辅助函数 ---

# 全局变量，用于在不同函数间传递状态
DOCKER_COMPOSE_CMD=""
SILLY_TAVERN_IMAGE=""
INSTALL_TYPE="" # 'overseas', 'mainland', or 'custom'
# 自定义模式下的变量
SERVER_IP=""
INSTALL_DIR=""
CONFIG_FILE=""
COMPOSE_FILE=""
TARGET_USER=""
USER_HOME=""
run_mode=""
single_user=""
single_pass=""

fn_print_step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }
fn_print_info() { echo -e "  $1"; }
fn_print_error() { echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2; exit 1; }

fn_get_cleaned_version_num() { echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }

fn_ensure_docker_running() {
    # Use `docker info` as a reliable check for daemon connectivity.
    if docker info > /dev/null 2>&1; then
        log_info "Docker daemon 状态正常，连接成功。"
        return 0
    fi

    log_warn "无法连接到 Docker daemon。这可能是因为它没有运行或已经停止。"
    
    if ! command -v systemctl &> /dev/null; then
        # This case is for non-systemd systems.
        fn_print_error "Docker 服务未运行，且系统中未找到 systemctl 命令，无法自动启动。请在手动启动 Docker 后重试。"
        return 1
    fi

    log_action "正在尝试使用 systemctl 启动 Docker 服务..."
    # Use `|| true` to prevent `set -e` from exiting the script if systemctl fails.
    systemctl start docker > /dev/null 2>&1 || true
    
    log_info "等待 5 秒以确保 Docker 服务完成初始化..."
    sleep 5

    if ! docker info > /dev/null 2>&1; then
        # The daemon is still not running. Now we give the user the specific systemd commands.
        fn_print_error "尝试启动 Docker 服务后，仍然无法连接到 Docker daemon。这通常意味着 Docker 服务本身存在配置问题或已损坏。请在终端中手动执行以下命令来诊断根本原因：\n\n  1. ${YELLOW}systemctl status docker.service${NC}\n  2. ${YELLOW}journalctl -xeu docker.service${NC}\n\n根据错误信息修复 Docker 后，再重新运行本脚本。"
    else
        log_success "Docker 服务已成功启动。"
    fi
}
 
fn_report_dependencies() {
    local DOCKER_VER="$1" DOCKER_STATUS="$2" COMPOSE_VER="$3" COMPOSE_STATUS="$4"
    local overall_status="${GREEN}OK ✓${NC}"
    if [[ "$DOCKER_STATUS" == "Not Found" || "$COMPOSE_STATUS" == "Not Found" ]]; then
        overall_status="${RED}异常 ✗${NC}"
    fi
    fn_print_info "→ Docker 环境: ${overall_status} (Docker: ${DOCKER_VER} ${DOCKER_STATUS}, Compose: ${COMPOSE_VER} ${COMPOSE_STATUS})"
}

fn_check_dependencies() {
    fn_print_info "检查 Docker 环境..."
    local DOCKER_VER="-" DOCKER_STATUS="-" COMPOSE_VER="-" COMPOSE_STATUS="-"
    
    local docker_check_needed=true
    while $docker_check_needed; do
        if ! command -v docker &> /dev/null; then
            DOCKER_STATUS="未找到"
        else
            DOCKER_VER=$(fn_get_cleaned_version_num "$(docker --version)"); DOCKER_STATUS="正常"
        fi
        if command -v docker-compose &> /dev/null; then
            DOCKER_COMPOSE_CMD="docker-compose"; COMPOSE_VER="v$(fn_get_cleaned_version_num "$($DOCKER_COMPOSE_CMD version)")"; COMPOSE_STATUS="正常 (v1)"
        elif docker compose version &> /dev/null; then
            DOCKER_COMPOSE_CMD="docker compose"; COMPOSE_VER=$(docker compose version | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n 1); COMPOSE_STATUS="正常 (v2)"
        else
            DOCKER_COMPOSE_CMD=""; COMPOSE_STATUS="未找到"
        fi

        if [[ "$DOCKER_STATUS" == "未找到" || "$COMPOSE_STATUS" == "未找到" ]]; then
            if [ "$IS_DEBIAN_LIKE" = true ]; then
                log_warn "Docker 或 Docker-Compose 未安装。"
                read -rp "按 Enter 自动安装 Docker (Ctrl+C 退出)..." < /dev/tty
                log_action "使用官方脚本安装 Docker..."
                bash <(curl -sSL https://linuxmirrors.cn/docker.sh) > /dev/null 2>&1
                continue
            else
                fn_print_error "Docker 或 Docker-Compose 未安装。请在您的系统 (${DETECTED_OS}) 上手动安装后重试。"
            fi
        else
            docker_check_needed=false
        fi
    done

    fn_report_dependencies "$DOCKER_VER" "$DOCKER_STATUS" "$COMPOSE_VER" "$COMPOSE_STATUS"

    local current_user="${SUDO_USER:-$(whoami)}"
    if ! groups "$current_user" | grep -q '\bdocker\b' && [ "$(id -u)" -ne 0 ]; then
        fn_print_error "当前用户不在 docker 用户组。请执行【安装 1Panel】或手动添加后，【重新登录SSH】再试。"
    fi
    fn_print_ok "Docker 环境检查通过！"
}

fn_check_existing_container() {
    local container_name="$1"
    if docker ps -a -q -f "name=^${container_name}$" | grep -q .; then
        log_warn "检测到服务器上已存在一个名为 '${container_name}' 的 Docker 容器。"
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
                log_action "正在停止并移除现有容器 '${container_name}'..."
                docker stop "${container_name}" > /dev/null 2>&1 || true
                docker rm "${container_name}" > /dev/null 2>&1 || true
                log_success "现有容器已成功移除。"
                ;;
            2)
                log_info "脚本已退出。请手动执行 'docker ps -a' 查看容器状态。"
                exit 0
                ;;
        esac
    fi
}

fn_pull_sillytavern_image() {
    log_info "这是部署中最关键的一步。如果拉取失败，请尝试配置镜像加速或使用自定义镜像。"

    echo "选择 SillyTavern 镜像源："
    echo -e "  [1] ${CYAN}官方镜像${NC} (ghcr.io/sillytavern/sillytavern:latest)"
    echo -e "  [2] ${YELLOW}自定义${NC} (输入完整镜像地址)"
    read -rp "选项 [默认为 1]: " choice < /dev/tty
    choice=${choice:-1}

    case "$choice" in
        1)
            SILLY_TAVERN_IMAGE="ghcr.io/sillytavern/sillytavern:latest"
            ;;
        2)
            read -rp "输入自定义镜像地址: " custom_image < /dev/tty
            if [ -z "$custom_image" ]; then
                fn_print_error "自定义镜像地址不能为空！"
            fi
            SILLY_TAVERN_IMAGE="$custom_image"
            ;;
        *)
            fn_print_error "无效输入，脚本已终止。"
            ;;
    esac

    fn_pull_image_with_progress "$SILLY_TAVERN_IMAGE"
}

fn_pull_image_with_progress() {
    local image_to_pull="$1"
    if [ -z "$image_to_pull" ]; then
        fn_print_error "调用 fn_pull_image_with_progress 时未提供镜像名称。"
    fi

    log_action "正在拉取镜像: ${image_to_pull}"
    echo -e "\n${CYAN}--- Docker 正在拉取，请关注以下原生进度条 ---${NC}"
    if ! docker pull "$image_to_pull"; then
        fn_print_error "Docker 镜像拉取失败！请检查网络或镜像地址后重试。"
    fi
    fn_print_ok "镜像 ${image_to_pull} 拉取成功！"
}

fn_get_public_ip() {
    local ip_services=(
        "https://ifconfig.me" "https://myip.ipip.net" "https://cip.cc" "https://api.ipify.org"
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
    echo "【请手动替换为你的服务器IP】"
    return 1
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
    docker logs "$container_name" --tail 50 || echo "无法获取容器日志。"
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

fn_display_final_info() {
    fn_print_ok "部署成功！尽情享受吧！"
    
    if [[ "$INSTALL_TYPE" == "custom" ]]; then
        if [[ "$run_mode" == "1" ]]; then
            # 自定义 - 单用户模式
            fn_print_tip "访问地址: ${GREEN}http://${SERVER_IP}:8000${NC}"
            fn_print_tip "登录账号: ${YELLOW}${single_user}${NC}"
            fn_print_tip "登录密码: ${YELLOW}${single_pass}${NC}"
        elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
            # 自定义 - 多用户/维护者模式
            fn_print_tip "访问地址 (平时用): ${GREEN}http://${SERVER_IP}:8000${NC}"
            fn_print_tip "登录页地址 (验证账号密码): ${GREEN}http://${SERVER_IP}:8000/login${NC}"
        fi
    else
        # 自动化模式 (海外/大陆)
        fn_print_tip "访问地址: ${GREEN}http://${SERVER_IP}:8000${NC}"
    fi
    
    fn_print_tip "项目路径: $INSTALL_DIR"
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

fn_create_project_structure() {
    fn_print_info "正在创建项目目录结构..."
    mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
    chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
    log_success "项目目录创建并授权成功！"
}

fn_confirm_and_delete_dir() {
    local dir_to_delete="$1" container_name="$2"
    log_warn "目录 '$dir_to_delete' 已存在，可能包含旧数据。"
    log_warn "为了进行全新安装，必须清理该目录。此操作不可逆！"
    read -r -p "按 Enter 键确认【彻底清理】并继续 (或按 Ctrl+C 退出脚本)..." < /dev/tty
    read -r -p "$(echo -e "${RED}最后警告：数据将无法恢复！请输入 'yes' 以确认删除: ${NC}")" c3 < /dev/tty
    if [[ "$c3" != "yes" ]]; then fn_print_error "操作被用户取消。"; fi
    docker stop "$container_name" > /dev/null 2>&1 || true
    docker rm "$container_name" > /dev/null 2>&1 || true
    sudo rm -rf "$dir_to_delete"
    log_success "旧目录和容器已彻底清理。"
}

fn_apply_config_changes() {
    sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)lazyLoadCharacters: .*/\1lazyLoadCharacters: true/" "$CONFIG_FILE"
    if [[ "$run_mode" == "1" ]]; then
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true/" "$CONFIG_FILE"
        sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)username:/{s/^([[:space:]]*)username: .*/\1username: \"$single_user\"/}" "$CONFIG_FILE"
        sed -i -E "/^([[:space:]]*)basicAuthUser:/,/^([[:space:]]*)password:/{s/^([[:space:]]*)password: .*/\1password: \"$single_pass\"/}" "$CONFIG_FILE"
    elif [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
        sed -i -E "s/^([[:space:]]*)enableUserAccounts: .*/\1enableUserAccounts: true/" "$CONFIG_FILE"
    fi
}

fn_create_compose_file() {
    local compose_file_path="$1"
    local container_name="$2"
    local image_name="$3"
    local current_run_mode="$4"

    if [[ "$current_run_mode" == "3" ]]; then
        # 维护者模式
        cat <<EOF > "$compose_file_path"
services:
  sillytavern:
    container_name: ${container_name}
    image: ${image_name}
    hostname: ${container_name}
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
        # 普通或专家模式
        cat <<EOF > "$compose_file_path"
services:
  sillytavern:
    container_name: ${container_name}
    image: ${image_name}
    hostname: ${container_name}
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
}

fn_generate_initial_config() {
    local compose_cmd="$1"
    local compose_file="$2"
    local config_file="$3"

    fn_print_info "正在进行首次启动以生成官方配置文件..."
    if ! $compose_cmd -f "$compose_file" up -d > /dev/null 2>&1; then
        fn_print_error "首次启动容器失败！请检查日志。"
    fi

    local timeout=60
    while [ ! -f "$config_file" ]; do
        if [ $timeout -eq 0 ]; then
            fn_print_error "等待配置文件生成超时！请检查容器日志。"
        fi
        sleep 1
        ((timeout--))
    done

    if ! $compose_cmd -f "$compose_file" down > /dev/null 2>&1; then
        log_warn "首次关闭容器时出错，但这通常不影响后续步骤。"
    fi
    log_success "config.yaml 文件已生成！"
}

fn_post_deployment_menu() {
    local container_name="$1"
    while true; do
        echo -e "\n${CYAN}--- 部署后操作 ---${NC}"
        echo -e "  [1] 容器状态\n  [2] 查看日志\n  [3] 访问信息\n  [q] 退出"
        read -rp "选择操作: " choice < /dev/tty
        case "$choice" in
            1) fn_check_and_explain_status "$container_name";;
            2) docker logs -f "$container_name" || true;;
            3) fn_display_final_info;;
            q|Q) break;;
            *) log_warn "无效输入。";;
        esac
    done
}

# --- 安装流程的主函数 ---

install_sillytavern() {
    tput reset
    echo -e "${CYAN}--- 部署 SillyTavern ---${NC}"
    fn_print_tip "此流程将通过 Docker 部署 SillyTavern。"

    fn_ensure_docker_running
 
    fn_select_server_type
 
    case "$INSTALL_TYPE" in
        "overseas")
            run_overseas_install
            ;;
        "mainland")
            run_mainland_install
            ;;
        "custom")
            run_custom_install
            ;;
    esac
}

fn_select_server_type() {
    log_step "1" "选择安装模式"
    fn_print_tip "请选择适合您服务器的安装模式："
    echo -e "  [1] ${CYAN}海外服务器${NC} (自动安装，直连官方源)"
    echo -e "  [2] ${YELLOW}大陆服务器${NC} (自动安装，自动配置镜像加速)"
    echo -e "  [3] ${GREEN}完全自定义${NC} (手动配置所有步骤)"
    read -rp "选择模式 [默认为 1]: " choice < /dev/tty
    choice=${choice:-1}

    case "$choice" in
        1)
            INSTALL_TYPE="overseas"
            fn_print_ok "已选 [海外服务器] 模式。"
            ;;
        2)
            INSTALL_TYPE="mainland"
            fn_print_ok "已选 [大陆服务器] 模式。"
            ;;
        3)
            INSTALL_TYPE="custom"
            fn_print_ok "已选 [完全自定义] 模式。"
            ;;
        *)
            log_warn "无效输入，默认使用 [海外服务器] 模式。"
            INSTALL_TYPE="overseas"
            ;;
    esac
}

run_automated_install() {
    local install_type="$1" # "overseas" or "mainland"
    local mode_name=""
    if [[ "$install_type" == "overseas" ]]; then mode_name="海外服务器"; else mode_name="大陆服务器"; fi

    fn_print_step "[ ${mode_name} ] 环境检查与准备"
    fn_check_base_deps
    fn_check_dependencies

    fn_print_step "[ ${mode_name} ] 自动配置 Docker"
    DAEMON_JSON_PARTS=()
    DAEMON_JSON_PARTS+=('"log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}')
    
    if [[ "$install_type" == "mainland" ]]; then
        log_info "正在为大陆服务器自动配置最快镜像源..."
        local test_results; test_results=$(fn_internal_test_mirrors)
        if [[ "$test_results" != "OFFICIAL_HUB_OK" && -n "$test_results" ]]; then
            # 使用 awk 更稳定地提取镜像地址，并限制最多1个
            local best_mirrors_str; best_mirrors_str=$(echo -e "$test_results" | awk -F'|' '{print $2}' | head -n 3)
            # 使用 mapfile 或 read -a 是更安全的做法，避免 word splitting 问题
            read -r -d '' -a best_mirrors < <(printf '%s\n' "$best_mirrors_str")
            
            if [ ${#best_mirrors[@]} -gt 0 ]; then
                log_success "将自动配置最快的 ${#best_mirrors[@]} 个镜像源。"
                local mirrors_json_array; mirrors_json_array=$(printf '"%s",' "${best_mirrors[@]}" | sed 's/,$//')
                DAEMON_JSON_PARTS+=("\"registry-mirrors\": [${mirrors_json_array}]")
            else
                log_warn "所有备用镜像均测试失败！将不配置镜像加速。"
            fi
        elif [[ "$test_results" == "OFFICIAL_HUB_OK" ]]; then
            log_success "官方 Docker Hub 可用，无需配置镜像加速。"
        else
            log_warn "所有备用镜像均测试失败！将不配置镜像加速。"
        fi
    else
        log_info "海外服务器，跳过镜像加速配置。"
    fi
    fn_apply_docker_optimization

    fn_print_step "[ ${mode_name} ] 自动拉取镜像"
    SILLY_TAVERN_IMAGE="ghcr.io/sillytavern/sillytavern:latest"
    fn_pull_image_with_progress "$SILLY_TAVERN_IMAGE"

    TARGET_USER="${SUDO_USER:-root}"
    if [ "$TARGET_USER" = "root" ]; then USER_HOME="/root"; else USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6); fi
    INSTALL_DIR="$USER_HOME/sillytavern"
    CONFIG_FILE="$INSTALL_DIR/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    log_info "将使用默认安装路径: ${INSTALL_DIR}"

    local container_name="sillytavern"
    if [ -d "$INSTALL_DIR" ]; then
        fn_confirm_and_delete_dir "$INSTALL_DIR" "$container_name"
    fi

    fn_create_project_structure
    cd "$INSTALL_DIR"

    # 自动模式不进入维护者模式，所以 run_mode 传 "1" (代表普通用户)
    fn_create_compose_file "$COMPOSE_FILE" "$container_name" "$SILLY_TAVERN_IMAGE" "1"

    fn_print_step "[ ${mode_name} ] 初始化与配置"
    fn_generate_initial_config "$DOCKER_COMPOSE_CMD" "$COMPOSE_FILE" "$CONFIG_FILE"

    sed -i -E "s/^([[:space:]]*)listen: .*/\1listen: true/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)whitelistMode: .*/\1whitelistMode: false/" "$CONFIG_FILE"
    sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false/" "$CONFIG_FILE"
    log_success "默认配置已应用。"

    fn_print_step "[ ${mode_name} ] 启动并验证服务"
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate
    fn_verify_container_health "$container_name"
    fn_wait_for_service
    SERVER_IP=$(fn_get_public_ip)
    fn_display_final_info

    fn_post_deployment_menu "$container_name"
}

run_overseas_install() {
    run_automated_install "overseas"
}

run_mainland_install() {
    run_automated_install "mainland"
}

run_custom_install() {
    local CONTAINER_NAME="sillytavern"

    # 步骤 1: 环境检查
    fn_print_step "[ 完全自定义 ] 步骤 1/6: 环境检查与准备"
    fn_check_base_deps
    fn_check_dependencies
    fn_check_existing_container "$CONTAINER_NAME"

    # 步骤 2: Docker 优化
    fn_print_step "[ 完全自定义 ] 步骤 2/6: Docker 优化配置"
    DAEMON_JSON_PARTS=() # 重置配置数组
    fn_configure_docker_logging
    echo
    fn_configure_docker_mirrors
    fn_apply_docker_optimization

    # 步骤 3: 拉取镜像
    fn_print_step "[ 完全自定义 ] 步骤 3/6: 选择并拉取 SillyTavern 镜像"
    fn_pull_sillytavern_image

    # 步骤 4: 配置安装选项
    fn_print_step "[ 完全自定义 ] 步骤 4/6: 选择运行模式与路径"
    TARGET_USER="${SUDO_USER:-root}"
    if [ "$TARGET_USER" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        if [ -z "$USER_HOME" ]; then fn_print_error "无法找到用户 '$TARGET_USER' 的家目录。"; fi
    fi

    echo "选择运行模式："
    echo -e "  [1] ${CYAN}单用户模式${NC} (弹窗认证，适合个人使用)"
    echo -e "  [2] ${CYAN}多用户模式${NC} (独立登录页，适合多人或单人使用)"
    echo -e "  [3] ${RED}维护者模式${NC} (作者专用，普通用户请勿选择！)"
    read -rp "选择模式 [默认为 1]: " run_mode < /dev/tty
    run_mode=${run_mode:-1}

    case "$run_mode" in
        1)
            read -rp "自定义用户名: " single_user < /dev/tty
            read -rp "自定义密码: " single_pass < /dev/tty
            if [ -z "$single_user" ] || [ -z "$single_pass" ]; then fn_print_error "用户名和密码不能为空！"; fi
            ;;
        2|3) ;;
        *) fn_print_error "无效输入，脚本已终止." ;;
    esac

    local default_parent_path="$USER_HOME"
    read -rp "安装路径 (上级目录) [默认: $USER_HOME]: " custom_parent_path < /dev/tty
    local parent_path="${custom_parent_path:-$default_parent_path}"
    INSTALL_DIR="${parent_path}/sillytavern"
    log_info "安装路径最终设置为: ${INSTALL_DIR}"
    CONFIG_FILE="$INSTALL_DIR/config.yaml"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

    # 步骤 5: 创建项目文件
    fn_print_step "[ 完全自定义 ] 步骤 5/6: 创建项目文件"
    if [ -z "$INSTALL_DIR" ]; then fn_print_error "安装路径未设置，无法创建项目文件。"; fi
    if [ -d "$INSTALL_DIR" ]; then
        fn_confirm_and_delete_dir "$INSTALL_DIR" "$CONTAINER_NAME"
    fi

    if [[ "$run_mode" == "3" ]]; then
        fn_print_info "正在创建开发者模式项目目录结构..."
        mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/plugins" "$INSTALL_DIR/public/scripts/extensions/third-party"
        mkdir -p "$INSTALL_DIR/custom/images"
        touch "$INSTALL_DIR/custom/login.html"
        chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"
        log_success "开发者项目目录创建并授权成功！"
    else
        fn_create_project_structure
    fi

    cd "$INSTALL_DIR"
    fn_print_info "工作目录已切换至: $(pwd)"

    fn_create_compose_file "$COMPOSE_FILE" "$CONTAINER_NAME" "$SILLY_TAVERN_IMAGE" "$run_mode"

    # 步骤 6: 初始化与启动
    fn_print_step "[ 完全自定义 ] 步骤 6/6: 初始化与启动服务"
    if [ -z "$DOCKER_COMPOSE_CMD" ]; then fn_print_error "Docker Compose 命令未找到。"; fi
    if [ ! -f "$COMPOSE_FILE" ]; then fn_print_error "docker-compose.yml 文件不存在。"; fi

    fn_generate_initial_config "$DOCKER_COMPOSE_CMD" "$COMPOSE_FILE" "$CONFIG_FILE"
    
    fn_apply_config_changes
    log_success "自定义配置已应用。"

    if [[ "$run_mode" == "2" || "$run_mode" == "3" ]]; then
        fn_print_info "正在临时启动服务以设置管理员..."
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: true/" "$CONFIG_FILE"
        $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d
        fn_verify_container_health "$CONTAINER_NAME"
        fn_wait_for_service
        SERVER_IP=$(fn_get_public_ip)
        echo -e "${YELLOW}---【 重要：请按以下步骤设置管理员 】---${NC}"
        echo -e "访问: ${GREEN}http://${SERVER_IP}:8000${NC} 使用默认账号(user)密码(password)登录并设置管理员。"
        read -rp "按 Enter 继续..." < /dev/tty
        sed -i -E "s/^([[:space:]]*)basicAuthMode: .*/\1basicAuthMode: false/" "$CONFIG_FILE"
        log_success "已切换到多用户登录页模式。"
    fi

    fn_print_info "正在应用最终配置并重启服务..."
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate
    fn_verify_container_health "$CONTAINER_NAME"
    fn_wait_for_service
    SERVER_IP=$(fn_get_public_ip)
    fn_display_final_info

    fn_post_deployment_menu "$CONTAINER_NAME"
    
    log_success "完全自定义安装流程已完成。"
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
                    log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"
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
                    log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"
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
                    log_warn "您的系统 (${DETECTED_OS}) 不支持此功能。"
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
