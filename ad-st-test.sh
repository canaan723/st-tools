#!/data/data/com.termux/files/usr/bin/bash
# 作者: 清绝 | 网址: blog.qjyg.de
# 清绝咕咕助手
#
# Copyright (c) 2025 清绝 (QingJue) <blog.qjyg.de>
# This script is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
# To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
#
# 郑重声明：
# 本脚本为免费开源项目，仅供个人学习和非商业用途使用。
# 未经作者授权，严禁将本脚本或其修改版本用于任何形式的商业盈利行为（包括但不限于倒卖、付费部署服务等）。
# 任何违反本协议的行为都将受到法律追究。

BOLD=$'\e[1m'
CYAN=$'\e[1;36m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
RED=$'\e[1;31m'
NC=$'\e[0m'

ST_DIR="$HOME/SillyTavern"
BACKUP_ROOT_DIR="$HOME/SillyTavern_Backups"
REPO_BRANCH="release"
BACKUP_LIMIT=10
SCRIPT_SELF_PATH=$(readlink -f "$0")
SCRIPT_URL="https://gitee.com/canaan723/st-tools/raw/main/ad-st.sh"
UPDATE_FLAG_FILE="/data/data/com.termux/files/usr/tmp/.st_assistant_update_flag"
CACHED_MIRRORS=()

CONFIG_DIR="$HOME/.config/ad-st"
CONFIG_FILE="$CONFIG_DIR/backup_prefs.conf"
GIT_SYNC_CONFIG_FILE="$CONFIG_DIR/git_sync.conf"
PROXY_CONFIG_FILE="$CONFIG_DIR/proxy.conf"
SYNC_RULES_CONFIG_FILE="$CONFIG_DIR/sync_rules.conf"
LAB_CONFIG_FILE="$CONFIG_DIR/lab.conf"
AGREEMENT_FILE="$CONFIG_DIR/.agreement_shown"

GCLI_DIR="$HOME/gcli2api"

readonly TOP_LEVEL_SYSTEM_FOLDERS=("data/_storage" "data/_cache" "data/_uploads" "data/_webpack")

MIRROR_LIST=(
    "https://github.com/SillyTavern/SillyTavern.git"
    "https://git.ark.xx.kg/gh/SillyTavern/SillyTavern.git"
    "https://git.723123.xyz/gh/SillyTavern/SillyTavern.git"
    "https://xget.xi-xu.me/gh/SillyTavern/SillyTavern.git"
    "https://gh-proxy.com/github.com/SillyTavern/SillyTavern.git"
    "https://gh.llkk.cc/https://github.com/SillyTavern/SillyTavern.git"
    "https://tvv.tw/https://github.com/SillyTavern/SillyTavern.git"
    "https://proxy.pipers.cn/https://github.com/SillyTavern/SillyTavern.git"
    "https://gh.catmak.name/https://github.com/SillyTavern/SillyTavern.git"
    "https://hub.gitmirror.com/https://github.com/SillyTavern/SillyTavern.git"
    "https://gh-proxy.net/https://github.com/SillyTavern/SillyTavern.git"
    "https://hubproxy-advj.onrender.com/https://github.com/SillyTavern/SillyTavern.git"
)

fn_show_main_header() {
    echo -e "    ${YELLOW}>>${GREEN} 清绝咕咕助手 v5.1test${NC}"
    echo -e "       ${BOLD}\033[0;37m作者: 清绝 | 网址: blog.qjyg.de${NC}"
    echo -e "    ${RED}本脚本为免费工具，严禁用于商业倒卖！${NC}"
}

fn_show_agreement_if_first_run() {
    if [ ! -f "$AGREEMENT_FILE" ]; then
        clear
        fn_print_header "使用前必看"
        local UNDERLINE=$'\e[4m'
        echo -e "\n 1. 我是咕咕助手的作者清绝，咕咕助手是 ${GREEN}完全免费${NC} 的，唯一发布地址 ${CYAN}${UNDERLINE}https://blog.qjyg.de${NC}"，内含宝宝级教程。
        echo -e " 2. 如果你是 ${YELLOW}花钱买的${NC}，那你绝对是 ${RED}被坑了${NC}，赶紧退款差评举报。"
        echo -e " 3. ${RED}${BOLD}严禁拿去倒卖！${NC}偷免费开源的东西赚钱，丢人现眼。"
        echo -e "\n${RED}${BOLD}【盗卖名单】${NC}"
        echo -e " -> 淘宝：${RED}${BOLD}灿灿AI科技${NC}"
        echo -e " （持续更新）"
        echo -e "\n${GREEN}发现盗卖的欢迎告诉我，感谢支持。${NC}"
        echo -e "─────────────────────────────────────────────────────────────"
        read -p "请输入 'yes' 表示你已阅读并同意以上条款: " confirm
        if [[ "$confirm" == "yes" ]]; then
            mkdir -p "$CONFIG_DIR"
            touch "$AGREEMENT_FILE"
            echo -e "\n${GREEN}感谢您的支持！正在进入助手...${NC}"
            sleep 2
        else
            echo -e "\n${RED}您未同意使用条款，脚本将自动退出。${NC}"
            exit 1
        fi
    fi
}

fn_print_header() {
    echo -e "\n${CYAN}═══ ${BOLD}$1 ${NC}═══${NC}"
}

fn_print_success() {
    echo -e "${GREEN}✓ ${BOLD}$1${NC}"
}

fn_print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}" >&2
}

fn_print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

fn_print_error_exit() {
    echo -e "\n${RED}✗ ${BOLD}$1${NC}\n${RED}流程已终止。${NC}" >&2
    fn_press_any_key
    exit 1
}

fn_press_any_key() {
    echo -e "\n${CYAN}请按任意键返回...${NC}"
    read -n 1 -s
}

fn_check_command() {
    command -v "$1" >/dev/null 2>&1
}

fn_get_st_config_value() {
    local key="$1"
    local config_path="$ST_DIR/config.yaml"
    [ ! -f "$config_path" ] && return 1
    # 1. 提取键后的内容 2. 去除行尾注释 3. 去除首尾空格 4. 去除首尾引号
    grep -m 1 "^${key}:" "$config_path" | sed -E "s/^${key}:[[:space:]]*//" | sed -E "s/[[:space:]]*#.*$//" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed -E 's/^["'\'']//; s/["'\'']$//' | tr -d '\r'
}

fn_get_st_nested_config_value() {
    local parent="$1"
    local key="$2"
    local config_path="$ST_DIR/config.yaml"
    [ ! -f "$config_path" ] && return 1
    awk -v p="$parent" -v k="$key" '
        $0 ~ "^"p":" {found=1; next}
        found && $0 ~ "^[[:space:]]+"k":" {
            sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "");
            sub(/[[:space:]]*#.*$/, "");
            gsub(/^["\x27]|["\x27]$/, "");
            print;
            exit;
        }
        found && $0 ~ "^[^[:space:]]" {exit}
    ' "$config_path" | tr -d '\r'
}

fn_update_st_config_value() {
    local key="$1"
    local value="$2"
    local config_path="$ST_DIR/config.yaml"
    [ ! -f "$config_path" ] && return 1
    # 转义 sed 替换字符串中的特殊字符 (& 和 分隔符 |)
    local escaped_value=$(echo "$value" | sed 's/[&|]/\\&/g')
    sed -i -E "s|^(${key}:[[:space:]]*)[^#\r\n]*(.*)$|\1${escaped_value}\2|" "$config_path"
}

fn_update_st_nested_config_value() {
    local parent="$1"
    local key="$2"
    local value="$3"
    local config_path="$ST_DIR/config.yaml"
    [ ! -f "$config_path" ] && return 1
    # 转义 sed 替换字符串中的特殊字符
    local escaped_value=$(echo "$value" | sed 's/[&|]/\\&/g')
    sed -i -E "/^${parent}:/,/^[^[:space:]]/ s|^([[:space:]]+${key}:[[:space:]]*)[^#\r\n]*(.*)$|\1${escaped_value}\2|" "$config_path"
}

fn_add_st_whitelist_entry() {
    local entry="$1"
    local config_path="$ST_DIR/config.yaml"
    [ ! -f "$config_path" ] && return 1
    # 如果已存在则跳过
    if grep -q -- "- $entry" "$config_path"; then return 0; fi
    
    # 1. 处理 whitelist: [] 格式
    if grep -q "^whitelist:[[:space:]]*\[\]" "$config_path"; then
        sed -i "s|^whitelist:[[:space:]]*\[\]|whitelist:\n  - $entry|" "$config_path"
    # 2. 处理 whitelist: 后面直接换行（可能带注释）的情况
    elif grep -qE "^whitelist:[[:space:]]*(#.*)?$" "$config_path"; then
        sed -i "/^whitelist:/a \  - $entry" "$config_path"
    # 3. 兜底处理：直接在 whitelist: 行后插入
    elif grep -q "^whitelist:" "$config_path"; then
        sed -i "/^whitelist:/a \  - $entry" "$config_path"
    fi
}

fn_get_user_folders() {
    local target_dir="$1"
    if [ ! -d "$target_dir" ]; then return; fi
    mapfile -t all_subdirs < <(find "$target_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
    local user_folders=()
    for dir in "${all_subdirs[@]}"; do
        local is_system_folder=false
        for sys_folder in "${TOP_LEVEL_SYSTEM_FOLDERS[@]}"; do
            if [[ "data/$dir" == "$sys_folder" ]]; then
                is_system_folder=true
                break
            fi
        done
        if [ "$is_system_folder" = false ]; then
            user_folders+=("$dir")
        fi
    done
    echo "${user_folders[@]}"
}

fn_find_fastest_mirror() {
    local mode="$1"
    if [ -z "$mode" ]; then mode="all"; fi

    if [[ "$mode" != "all" && ${#CACHED_MIRRORS[@]} -gt 0 ]]; then
        fn_print_success "已使用缓存的测速结果。" >&2
        printf '%s\n' "${CACHED_MIRRORS[@]}"
        return 0
    fi
    if [[ "$mode" == "all" ]]; then
        CACHED_MIRRORS=()
    fi

    fn_print_warning "开始测试 Git 镜像连通性与速度 (用于下载)..."
    local github_url="https://github.com/SillyTavern/SillyTavern.git"
    local sorted_successful_mirrors=()
    
    if [[ "$mode" == "official_only" || "$mode" == "all" ]]; then
        if [[ " ${MIRROR_LIST[*]} " =~ " ${github_url} " ]]; then
            echo -e "  - 优先测试: GitHub 官方源..." >&2
            if timeout 10s git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
                fn_print_success "GitHub 官方源直连可用！" >&2
                sorted_successful_mirrors+=("$github_url")
            else
                fn_print_error "GitHub 官方源连接超时。"
            fi
        fi
        if [[ "$mode" == "official_only" ]]; then
            if [ ${#sorted_successful_mirrors[@]} -gt 0 ]; then
                printf '%s\n' "${sorted_successful_mirrors[@]}"
                return 0
            else
                return 1
            fi
        fi
    fi

    if [[ "$mode" == "mirrors_only" || "$mode" == "all" ]]; then
        local other_mirrors=()
        for mirror in "${MIRROR_LIST[@]}"; do
            [[ "$mirror" != "$github_url" ]] && other_mirrors+=("$mirror")
        done

        if [ ${#other_mirrors[@]} -gt 0 ]; then
            echo -e "${YELLOW}已启动并行测试，将完整测试所有镜像线路...${NC}" >&2
            local results_file
            results_file=$(mktemp)
            local pids=()
            for mirror_url in "${other_mirrors[@]}"; do
                (
                    local mirror_host
                    mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
                    local start_time
                    start_time=$(date +%s.%N)
                    if timeout 10s git ls-remote "$mirror_url" HEAD >/dev/null 2>&1; then
                        local end_time
                        end_time=$(date +%s.%N)
                        local elapsed_time
                        elapsed_time=$(echo "$end_time - $start_time" | bc)
                        echo "$elapsed_time $mirror_url" >>"$results_file"
                        echo -e "  - 测试: ${CYAN}${mirror_host}${NC} - 耗时 ${GREEN}${elapsed_time}s${NC} ${GREEN}[成功]${NC}" >&2
                    else
                        echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${RED}[失败]${NC}" >&2
                    fi
                ) &
                pids+=($!)
            done
            wait "${pids[@]}"

            if [ -s "$results_file" ]; then
                mapfile -t other_successful_mirrors < <(sort -n "$results_file" | awk '{print $2}')
                sorted_successful_mirrors+=("${other_successful_mirrors[@]}")
            fi
            rm -f "$results_file"
        fi
    fi

    if [ ${#sorted_successful_mirrors[@]} -gt 0 ]; then
        fn_print_success "测试完成，找到 ${#sorted_successful_mirrors[@]} 个可用线路。" >&2
        CACHED_MIRRORS=("${sorted_successful_mirrors[@]}")
        printf '%s\n' "${CACHED_MIRRORS[@]}"
    else
        fn_print_error "所有线路均测试失败。"
        return 1
    fi
}

fn_run_npm_install() {
    if [ ! -d "$ST_DIR" ]; then return 1; fi
    cd "$ST_DIR" || return 1

    fn_print_warning "正在同步依赖包 (npm install)..."
    if npm install --no-audit --no-fund --omit=dev; then
        fn_print_success "依赖包同步完成。"
        return 0
    fi

    fn_print_warning "依赖包同步失败，将自动清理缓存并重试..."
    npm cache clean --force >/dev/null 2>&1
    if npm install --no-audit --no-fund --omit=dev; then
        fn_print_success "依赖包重试同步成功。"
        return 0
    fi

    fn_print_warning "国内镜像安装失败，将切换到NPM官方源进行最后尝试..."
    npm config delete registry
    local exit_code
    npm install --no-audit --no-fund --omit=dev
    exit_code=$?
    fn_print_warning "正在将 NPM 源恢复为国内镜像..."
    npm config set registry https://registry.npmmirror.com

    if [ $exit_code -eq 0 ]; then
        fn_print_success "使用官方源安装依赖成功！"
        return 0
    else
        fn_print_error "所有安装尝试均失败。"
        return 1
    fi
}

fn_update_termux_source() {
    fn_print_header "1/5: 配置软件源"
    echo -e "${YELLOW}即将开始配置 Termux 软件源...${NC}"
    echo -e "  - 安装开始时，屏幕会弹出蓝白色确认窗口。"
    echo -e "  - ${GREEN}国内网络${NC}: ${BOLD}依次触屏选择【第一项】和【第三项】并点击 OK${NC}。"
    echo -e "  - ${GREEN}国外网络${NC}: ${BOLD}选择两次【第一项】并点击 OK${NC}。"
    echo -e "  - 之后安装会自动进行，无需其他操作。"
    echo -e "\n${CYAN}请按任意键以继续...${NC}"
    read -n 1 -s

    for i in {1..3}; do
        termux-change-repo
        fn_print_warning "正在更新软件包列表 (第 $i/3 次尝试)..."
        if pkg update -y; then
            fn_print_success "软件源配置并更新成功！"
            return 0
        fi
        if [ $i -lt 3 ]; then
            fn_print_error "当前选择的镜像源似乎有问题，正在尝试自动切换..."
            sleep 2
        fi
    done

    fn_print_error "已尝试 3 次，但均无法成功更新软件源。"
    return 1
}

fn_git_check_deps() {
    if ! fn_check_command "git" || ! fn_check_command "rsync"; then
        fn_print_warning "Git或Rsync尚未安装，请先运行 [首次部署]。"
        fn_press_any_key
        return 1
    fi
    return 0
}

fn_git_ensure_identity() {
    if [ -z "$(git config --global --get user.name)" ] || [ -z "$(git config --global --get user.email)" ]; then
        clear
        fn_print_header "首次使用Git同步：配置身份"
        local user_name user_email
        while true; do
            read -p "请输入您的Git用户名 (例如 Your Name): " user_name
            [[ -n "$user_name" ]] && break || fn_print_error "用户名不能为空！"
        done
        while true; do
            read -p "请输入您的Git邮箱 (例如 you@example.com): " user_email
            [[ -n "$user_email" ]] && break || fn_print_error "邮箱不能为空！"
        done
        git config --global user.name "$user_name"
        git config --global user.email "$user_email"
        fn_print_success "Git身份信息已配置成功！"
        sleep 2
    fi
    return 0
}

fn_git_configure() {
    clear
    fn_print_header "配置 Git 同步服务"
    local repo_url repo_token
    while true; do
        read -p "请输入您的私有仓库HTTPS地址: " repo_url
        [[ -n "$repo_url" ]] && break || fn_print_error "仓库地址不能为空！"
    done
    while true; do
        read -p "请输入您的Personal Access Token: " repo_token
        [[ -n "$repo_token" ]] && break || fn_print_error "Token不能为空！"
    done
    echo "REPO_URL=\"$repo_url\"" > "$GIT_SYNC_CONFIG_FILE"
    echo "REPO_TOKEN=\"$repo_token\"" >> "$GIT_SYNC_CONFIG_FILE"
    chmod 600 "$GIT_SYNC_CONFIG_FILE"
    fn_print_success "Git同步服务配置已保存！"
    fn_press_any_key
}

fn_git_test_one_mirror_push() {
    local authed_url="$1"
    local test_tag="st-sync-test-$(date +%s%N)"
    local temp_repo_dir
    temp_repo_dir=$(mktemp -d)
    (
        cd "$temp_repo_dir" || return 1
        git init -q
        git config user.name "test"
        git config user.email "test@example.com"
        touch testfile.txt
        git add testfile.txt
        git commit -m "Sync test commit" -q
        git remote add origin "$authed_url"
        if timeout 15s git push origin "HEAD:refs/tags/$test_tag" >/dev/null 2>&1; then
            timeout 15s git push origin --delete "refs/tags/$test_tag" >/dev/null 2>&1
            return 0
        else
            return 1
        fi
    )
    local exit_code=$?
    rm -rf "$temp_repo_dir"
    return $exit_code
}

fn_git_construct_authed_url() {
    local public_mirror_url="$1"
    source "$GIT_SYNC_CONFIG_FILE"
    
    if [[ -z "$REPO_URL" || -z "$REPO_TOKEN" ]]; then
        return 1
    fi

    local repo_path
    repo_path=$(echo "$REPO_URL" | sed 's|https://github.com/||')
    local authed_private_url="https://${REPO_TOKEN}@github.com/${repo_path}"

    if [[ "$public_mirror_url" == "https://github.com/SillyTavern/SillyTavern.git" ]]; then
        echo "$authed_private_url"
        return 0
    fi
    
    if [[ "$public_mirror_url" =~ ^https://hub\.gitmirror\.com/ ]]; then
        echo "https://${REPO_TOKEN}@hub.gitmirror.com/${repo_path}"
        return 0
    fi

    if [[ "$public_mirror_url" =~ ^https://([^/]+)/gh/ ]]; then
        local proxy_domain="${BASH_REMATCH[1]}"
        echo "https://${REPO_TOKEN}@${proxy_domain}/gh/${repo_path}"
        return 0
    fi

    local proxy_prefix
    proxy_prefix=$(echo "$public_mirror_url" | sed -E 's|/(https?://)?github.com/.*||')
    if [[ -n "$proxy_prefix" && "$proxy_prefix" != "$public_mirror_url" ]]; then
        echo "${proxy_prefix}/${authed_private_url}"
        return 0
    fi

    return 1
}

fn_git_find_pushable_mirror() {
    local mode="$1"
    if [ -z "$mode" ]; then mode="all"; fi

    source "$GIT_SYNC_CONFIG_FILE"
    if [[ -z "$REPO_URL" || -z "$REPO_TOKEN" ]]; then
        fn_print_error "Git同步配置不完整或不存在。"
        return 1
    fi
    fn_print_warning "正在自动测试支持数据上传的加速线路..."
    local github_public_url="https://github.com/SillyTavern/SillyTavern.git"
    local successful_urls=()
    
    if [[ "$mode" == "official_only" || "$mode" == "all" ]]; then
        if [[ " ${MIRROR_LIST[*]} " =~ " ${github_public_url} " ]]; then
            local official_url
            official_url=$(fn_git_construct_authed_url "https://github.com/SillyTavern/SillyTavern.git")
            echo -e "  - 优先测试: 官方 GitHub ..." >&2
            if fn_git_test_one_mirror_push "$official_url"; then 
                echo -e "    ${GREEN}[成功]${NC}" >&2
                successful_urls+=("$official_url")
            else 
                echo -e "    ${RED}[失败]${NC}" >&2
            fi
        fi
        if [[ "$mode" == "official_only" ]]; then
            if [ ${#successful_urls[@]} -gt 0 ]; then
                printf '%s\n' "${successful_urls[@]}"
                return 0
            else
                return 1
            fi
        fi
    fi
    
    if [[ "$mode" == "mirrors_only" || "$mode" == "all" ]]; then
        local other_mirrors=()
        for mirror_url in "${MIRROR_LIST[@]}"; do
            [[ "$mirror_url" != "$github_public_url" ]] && other_mirrors+=("$mirror_url")
        done
        
        if [ ${#other_mirrors[@]} -gt 0 ]; then
            echo -e "${YELLOW}已启动并行测试，将完整测试所有镜像...${NC}" >&2
            local results_file
            results_file=$(mktemp)
            local pids=()
            for mirror_url in "${other_mirrors[@]}"; do
                ( 
                    local authed_push_url
                    authed_push_url=$(fn_git_construct_authed_url "$mirror_url") || exit 1
                    local mirror_host
                    mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
                    if fn_git_test_one_mirror_push "$authed_push_url"; then 
                        echo "$authed_push_url" >> "$results_file"
                        echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${GREEN}[成功]${NC}" >&2
                    else 
                        echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${RED}[失败]${NC}" >&2
                    fi 
                ) &
                pids+=($!)
            done
            wait "${pids[@]}"
            if [ -s "$results_file" ]; then
                mapfile -t other_successful_urls < "$results_file"
                successful_urls+=("${other_successful_urls[@]}")
            fi
            rm -f "$results_file"
        fi
    fi
    
    if [ ${#successful_urls[@]} -gt 0 ]; then 
        fn_print_success "测试完成，找到 ${#successful_urls[@]} 条可用上传线路。" >&2
        printf '%s\n' "${successful_urls[@]}"
    else 
        fn_print_error "所有上传线路均测试失败。"
        return 1
    fi
}

fn_git_backup_to_cloud() {
    clear
    fn_print_header "Git备份数据到云端 (上传)"
    if [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then
        fn_print_warning "请先在菜单 [1] 中配置Git同步服务。"
        fn_press_any_key
        return
    fi
    local SYNC_CONFIG_YAML="false"
    local USER_MAP=""
    if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then
        source "$SYNC_RULES_CONFIG_FILE"
    fi
    local push_urls=()
    mapfile -t push_urls < <(fn_git_find_pushable_mirror "official_only")

    if [ ${#push_urls[@]} -eq 0 ]; then
        mapfile -t push_urls < <(fn_git_find_pushable_mirror "mirrors_only")
        if [ ${#push_urls[@]} -eq 0 ]; then
            fn_print_error "所有上传线路均测试失败。"
            fn_press_any_key
            return
        fi
    fi

    local backup_success=false
    local attempts=0
    while ! $backup_success; do
        attempts=$((attempts + 1))
        for push_url in "${push_urls[@]}"; do
            local chosen_host
            chosen_host=$(echo "$push_url" | sed -e 's|https://.*@||' -e 's|/.*$||')
            fn_print_warning "正在尝试使用线路 [${chosen_host}] 进行备份..."
            local temp_dir
            temp_dir=$(mktemp -d)

            (
                cd "$HOME" || exit 1
                if ! git clone --depth 1 "$push_url" "$temp_dir"; then
                    fn_print_error "克隆云端仓库失败！"
                    exit 1
                fi
                fn_print_success "已成功从云端克隆仓库。"

                cd "$temp_dir" || exit 1
                fn_print_warning "正在同步本地数据到临时区..."
                local rsync_exclude_args=("--exclude=extensions/" "--exclude=backups/" "--exclude=*.log")

                if [ -n "$USER_MAP" ] && [[ "$USER_MAP" == *":"* ]]; then
                    local local_user="${USER_MAP%%:*}"
                    local remote_user="${USER_MAP##*:}"
                    fn_print_warning "应用用户映射规则: 本地'${local_user}' -> 云端'${remote_user}'"
                    if [ -d "$ST_DIR/data/$local_user" ]; then
                        mkdir -p "./data/$remote_user"
                        rsync -a --delete "${rsync_exclude_args[@]}" "$ST_DIR/data/$local_user/" "./data/$remote_user/"
                    else
                        fn_print_warning "本地用户文件夹 '$local_user' 不存在，跳过同步。"
                    fi
                else
                    fn_print_warning "应用镜像同步规则: 同步所有本地用户文件夹"
                    find . -mindepth 1 -not -path './.git*' -delete
                    local local_users
                    local_users=($(fn_get_user_folders "$ST_DIR/data"))
                    for l_user in "${local_users[@]}"; do
                        mkdir -p "./data/$l_user"
                        rsync -a --delete "${rsync_exclude_args[@]}" "$ST_DIR/data/$l_user/" "./data/$l_user/"
                    done
                fi

                if [ "$SYNC_CONFIG_YAML" == "true" ] && [ -f "$ST_DIR/config.yaml" ]; then
                    cp "$ST_DIR/config.yaml" .
                fi
                
                git add .
                if git diff-index --quiet HEAD; then
                    fn_print_success "数据与云端一致，无需上传。"
                    exit 100
                fi
                
                fn_print_warning "正在提交数据变更..."
                local commit_message="📱 Termux 推送: $(date +'%Y-%m-%d %H:%M:%S')"
                git commit -m "$commit_message" -q || { fn_print_error "Git 提交失败！"; exit 1; }
                
                fn_print_warning "正在上传到云端..."
                git push || { fn_print_error "上传失败！"; exit 1; }
                fn_print_success "数据成功备份到云端！"
                exit 0
            )
            
            local subshell_exit_code=$?
            rm -rf "$temp_dir"
            if [ $subshell_exit_code -eq 0 ] || [ $subshell_exit_code -eq 100 ]; then
                backup_success=true
                break
            else
                fn_print_error "使用线路 [${chosen_host}] 备份失败，正在切换..."
                continue
            fi
        done

        if ! $backup_success; then
            if [ $attempts -eq 1 ]; then
                fn_print_error "已尝试所有预选线路，但备份均失败。"
                fn_print_warning "将进行全量测速并重试所有可用线路..."
                mapfile -t push_urls < <(fn_git_find_pushable_mirror "all")
                if [ ${#push_urls[@]} -eq 0 ]; then
                    fn_print_error "全量测速后未找到任何可用上传线路。"
                    break
                fi
            else
                fn_print_error "已尝试所有可用线路，但备份均失败。"
                break
            fi
        fi
    done

    fn_press_any_key
}

fn_git_restore_from_cloud() {
    clear
    fn_print_header "Git从云端恢复数据 (下载)"
    if [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then
        fn_print_warning "请先在菜单 [1] 中配置Git同步服务。"
        fn_press_any_key
        return
    fi
    
    fn_print_warning "此操作将用云端数据【覆盖】本地数据！"
    read -p "是否在恢复前，先对当前数据进行一次本地备份？(强烈推荐) [Y/n]: " backup_confirm
    if [[ ! "$backup_confirm" =~ ^[nN]$ ]]; then 
        if ! fn_create_zip_backup "恢复前"; then
            fn_print_error "本地备份失败，恢复操作已中止。"
            fn_press_any_key
            return
        fi
    fi
    
    read -p "确认要从云端恢复数据吗？[Y/n]: " restore_confirm
    if [[ "$restore_confirm" =~ ^[nN]$ ]]; then
        fn_print_warning "操作已取消。"
        fn_press_any_key
        return
    fi
    
    local SYNC_CONFIG_YAML="false"
    local USER_MAP=""
    if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then
        source "$SYNC_RULES_CONFIG_FILE"
    fi

    local pull_urls=()
    mapfile -t pull_urls < <(fn_find_fastest_mirror "official_only")

    if [ ${#pull_urls[@]} -eq 0 ]; then
        mapfile -t pull_urls < <(fn_find_fastest_mirror "mirrors_only")
        if [ ${#pull_urls[@]} -eq 0 ]; then
            fn_print_error "所有下载线路均测试失败。"
            fn_press_any_key
            return
        fi
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    (
        cd "$HOME" || exit 1
        source "$GIT_SYNC_CONFIG_FILE"
        local repo_path
        repo_path=$(echo "$REPO_URL" | sed 's|https://github.com/||')
        
        local clone_success=false
        local attempts=0
        while ! $clone_success; do
            attempts=$((attempts + 1))
            for pull_url in "${pull_urls[@]}"; do
                local chosen_host
                chosen_host=$(echo "$pull_url" | sed -e 's|https://||' -e 's|/.*$||')
                fn_print_warning "正在尝试使用线路 [${chosen_host}] 进行恢复..."
                local private_repo_url
                private_repo_url=$(echo "$pull_url" | sed "s|/SillyTavern/SillyTavern.git|/${repo_path}|")
                local pull_url_with_auth
                pull_url_with_auth=$(echo "$private_repo_url" | sed "s|https://|https://${REPO_TOKEN}@|")
                
                if git clone --depth 1 "$pull_url_with_auth" "$temp_dir"; then
                    clone_success=true
                    break
                fi
                fn_print_error "下载云端数据失败！正在切换下一条线路..."
                rm -rf "$temp_dir"/* "$temp_dir"/.* 2>/dev/null
            done

            if ! $clone_success; then
                if [ $attempts -eq 1 ]; then
                    fn_print_error "已尝试所有预选线路，但下载均失败。"
                    fn_print_warning "将进行全量测速并重试所有可用线路..."
                    mapfile -t pull_urls < <(fn_find_fastest_mirror "all")
                    if [ ${#pull_urls[@]} -eq 0 ]; then
                        fn_print_error "全量测速后未找到任何可用下载线路。"
                        break
                    fi
                else
                    fn_print_error "已尝试所有可用线路，但恢复均失败。"
                    break
                fi
            fi
        done

        if ! $clone_success; then
            exit 1
        fi
        if [ -z "$(ls -A "$temp_dir")" ]; then
            fn_print_error "下载的数据源无效或为空，恢复操作已中止！"
            exit 1
        fi
        fn_print_success "已成功从云端下载数据。"

        fn_print_warning "正在将云端数据同步到本地..."
        local rsync_exclude_args=("--exclude=extensions/" "--exclude=backups/" "--exclude=*.log")

        if [ -n "$USER_MAP" ] && [[ "$USER_MAP" == *":"* ]]; then
            local local_user="${USER_MAP%%:*}"
            local remote_user="${USER_MAP##*:}"
            fn_print_warning "应用用户映射规则: 云端'${remote_user}' -> 本地'${local_user}'"
            if [ -d "$temp_dir/data/$remote_user" ]; then
                mkdir -p "$ST_DIR/data/$local_user"
                rsync -a --delete "${rsync_exclude_args[@]}" "$temp_dir/data/$remote_user/" "$ST_DIR/data/$local_user/"
            else
                fn_print_warning "云端映射文件夹 'data/${remote_user}' 不存在，跳过映射同步。"
            fi
        else
            fn_print_warning "应用镜像同步规则: 恢复所有云端用户文件夹"
            local remote_users_all
            remote_users_all=($(fn_get_user_folders "$temp_dir/data"))
            local final_remote_users=("${remote_users_all[@]}")
            
            local local_users
            local_users=($(fn_get_user_folders "$ST_DIR/data"))
            for l_user in "${local_users[@]}"; do
                if ! [[ " ${final_remote_users[*]} " =~ " ${l_user} " ]]; then
                    fn_print_warning "清理本地多余的用户: $l_user"
                    rm -rf "$ST_DIR/data/$l_user"
                fi
            done
            for r_user in "${final_remote_users[@]}"; do
                mkdir -p "$ST_DIR/data/$r_user"
                rsync -a --delete "${rsync_exclude_args[@]}" "$temp_dir/data/$r_user/" "$ST_DIR/data/$r_user/"
            done
        fi

        if [ "$SYNC_CONFIG_YAML" == "true" ] && [ -f "$temp_dir/config.yaml" ]; then
            fn_print_warning "正在同步: config.yaml"
            cp "$temp_dir/config.yaml" "$ST_DIR/config.yaml"
        fi
        
        fn_print_success "\n数据已从云端成功恢复！"
        exit 0
    )
    
    rm -rf "$temp_dir"
    fn_press_any_key
}

fn_git_clear_config() {
    if [ -f "$GIT_SYNC_CONFIG_FILE" ]; then
        read -p "确认要清除已保存的Git同步配置吗？(y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            rm -f "$GIT_SYNC_CONFIG_FILE"
            fn_print_success "Git同步配置已清除。"
        else
            fn_print_warning "操作已取消。"
        fi
    else
        fn_print_warning "未找到任何Git同步配置。"
    fi
    fn_press_any_key
}

fn_export_extension_links() {
    clear
    fn_print_header "导出扩展链接"
    local all_links=()
    local output_content=""
    get_repo_url() {
        if [ -d "$1/.git" ]; then
            (cd "$1" || return; git config --get remote.origin.url)
        fi
    }

    local global_ext_path="$ST_DIR/public/scripts/extensions/third-party"
    if [ -d "$global_ext_path" ]; then
        local global_links_found=false
        local temp_output="═══ 全局扩展 ═══\n"
        for dir in "$global_ext_path"/*/; do
            if [ -d "$dir" ]; then
                local url
                url=$(get_repo_url "$dir")
                if [ -n "$url" ]; then
                    temp_output+="$url\n"
                    all_links+=("$url")
                    global_links_found=true
                fi
            fi
        done
        if $global_links_found; then
            output_content+="$temp_output"
        fi
    fi

    local data_path="$ST_DIR/data"
    if [ -d "$data_path" ]; then
        for user_dir in "$data_path"/*/; do
            if [ -d "$user_dir" ]; then
                local user_ext_path="${user_dir}extensions"
                if [ -d "$user_ext_path" ]; then
                    local user_links_found=false
                    local user_name
                    user_name=$(basename "$user_dir")
                    local temp_output="\n═══ 用户 [${user_name}] 的扩展 ═══\n"
                    for ext_dir in "$user_ext_path"/*/; do
                        if [ -d "$ext_dir" ]; then
                            local url
                            url=$(get_repo_url "$ext_dir")
                            if [ -n "$url" ]; then
                                temp_output+="$url\n"
                                all_links+=("$url")
                                user_links_found=true
                            fi
                        fi
                    done
                    if $user_links_found; then
                        output_content+="$temp_output"
                    fi
                fi
            fi
        done
    fi

    if [ ${#all_links[@]} -eq 0 ]; then
        fn_print_warning "未找到任何已安装的Git扩展。"
    else
        echo -e "$output_content"
        read -p $'\n'"是否将以上链接保存到 '$HOME/ST_扩展链接_...txt'？ [y/N]: " save_choice
        if [[ "$save_choice" =~ ^[yY]$ ]]; then
            local file_path="$HOME/ST_扩展链接_$(date +'%Y-%m-%d').txt"
            echo -e "$output_content" > "$file_path"
            if [ $? -eq 0 ]; then
                fn_print_success "链接已成功保存到: $file_path"
            else
                fn_print_error "保存失败！"
            fi
        fi
    fi
    fn_press_any_key
}

fn_menu_git_config() {
    while true; do
        clear
        fn_print_header "管理 Git 同步配置"
        echo -e "      [1] ${CYAN}修改/设置同步信息${NC}"
        echo -e "      [2] ${RED}清除所有同步配置${NC}"
        echo -e "      [0] ${CYAN}返回上一级${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_git_configure; break ;;
            2) fn_git_clear_config ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_menu_advanced_sync() {
    fn_update_config_value() {
        local key="$1"
        local value="$2"
        local file="$3"
        touch "$file"
        sed -i "/^${key}=/d" "$file"
        if [ -n "$value" ]; then
            echo "${key}=\"${value}\"" >> "$file"
        fi
    }
    while true; do
        clear
        fn_print_header "高级同步设置"
        local SYNC_CONFIG_YAML="false"
        local USER_MAP=""
        if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then
            source "$SYNC_RULES_CONFIG_FILE"
        fi

        local sync_config_status="${RED}关闭${NC}"
        [[ "$SYNC_CONFIG_YAML" == "true" ]] && sync_config_status="${GREEN}开启${NC}"
        echo -e "  [1] 同步 config.yaml         : ${sync_config_status}"
        
        local user_map_status="${RED}未设置${NC}"
        if [ -n "$USER_MAP" ]; then
            local local_user="${USER_MAP%%:*}"
            local remote_user="${USER_MAP##*:}"
            user_map_status="${GREEN}本地 ${local_user} -> 云端 ${remote_user}${NC}"
        fi
        echo -e "  [2] 设置用户数据映射        : ${user_map_status}"
        
        echo -e "\n  [3] ${RED}重置所有高级设置${NC}"
        echo -e "  [0] ${CYAN}返回上一级${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) 
                local new_status="false"
                [[ "$SYNC_CONFIG_YAML" != "true" ]] && new_status="true"
                fn_update_config_value "SYNC_CONFIG_YAML" "$new_status" "$SYNC_RULES_CONFIG_FILE"
                fn_print_success "config.yaml 同步已变更为: ${new_status}"
                sleep 1
                ;;
            2) 
                read -p "请输入本地用户文件夹名 [直接回车默认为 default-user]: " local_u
                local_u=${local_u:-default-user}
                read -p "请输入要映射到的云端用户文件夹名 [直接回车默认为 default-user]: " remote_u
                remote_u=${remote_u:-default-user}
                fn_update_config_value "USER_MAP" "${local_u}:${remote_u}" "$SYNC_RULES_CONFIG_FILE"
                fn_print_success "用户映射已设置为: ${local_u} -> ${remote_u}"
                sleep 1.5
                ;;
            3) 
                if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then
                    rm -f "$SYNC_RULES_CONFIG_FILE"
                    fn_print_success "所有高级同步设置已重置。"
                else
                    fn_print_warning "没有需要重置的设置。"
                fi
                sleep 1.5
                ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_menu_git_sync() {
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "酒馆尚未安装，无法使用数据同步功能。\n请先返回主菜单选择 [首次部署]。"
        fn_press_any_key
        return
    fi
    if ! fn_git_check_deps; then return; fi
    if ! fn_git_ensure_identity; then return; fi

    while true; do 
        clear
        fn_print_header "数据同步 (Git 方案)"
        if [ -f "$GIT_SYNC_CONFIG_FILE" ]; then
            source "$GIT_SYNC_CONFIG_FILE"
            if [ -n "$REPO_URL" ]; then
                local current_repo_name
                current_repo_name=$(basename "$REPO_URL" .git)
                echo -e "      ${YELLOW}当前仓库: ${current_repo_name}${NC}\n"
            fi
        fi
        echo -e "      [1] ${CYAN}管理同步配置 (仓库地址/Token)${NC}"
        echo -e "      [2] ${GREEN}备份到云端 (上传)${NC}"
        echo -e "      [3] ${YELLOW}从云端恢复 (下载)${NC}"
        echo -e "      [4] ${CYAN}高级同步设置 (用户映射等)${NC}"
        echo -e "      [5] ${CYAN}导出扩展链接${NC}\n"
        echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_menu_git_config ;;
            2) fn_git_backup_to_cloud ;;
            3) fn_git_restore_from_cloud ;;
            4) fn_menu_advanced_sync ;;
            5) fn_export_extension_links ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_apply_proxy() {
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        local port
        port=$(cat "$PROXY_CONFIG_FILE")
        if [[ -n "$port" ]]; then
            export http_proxy="http://127.0.0.1:$port"
            export https_proxy="http://127.0.0.1:$port"
            export all_proxy="http://127.0.0.1:$port"
        fi
    else
        unset http_proxy https_proxy all_proxy
    fi
}

fn_set_proxy() {
    read -p "请输入代理端口号 [直接回车默认为 7890]: " port
    port=${port:-7890}
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -lt 65536 ]; then
        echo "$port" > "$PROXY_CONFIG_FILE"
        fn_apply_proxy
        fn_print_success "代理已设置为: 127.0.0.1:$port"
    else
        fn_print_error "无效的端口号！请输入1-65535之间的数字。"
    fi
    fn_press_any_key
}

fn_clear_proxy() {
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        rm -f "$PROXY_CONFIG_FILE"
        fn_apply_proxy
        fn_print_success "网络代理配置已清除。"
    else
        fn_print_warning "当前未配置任何代理。"
    fi
    fn_press_any_key
}

fn_menu_proxy() {
    while true; do
        clear
        fn_print_header "管理网络代理"
        local proxy_status="${RED}未配置${NC}"
        if [ -f "$PROXY_CONFIG_FILE" ]; then
            proxy_status="${GREEN}127.0.0.1:$(cat "$PROXY_CONFIG_FILE")${NC}"
        fi
        echo -e "      当前状态: ${proxy_status}\n"
        echo -e "      [1] ${CYAN}设置/修改代理${NC}"
        echo -e "      [2] ${RED}清除代理${NC}"
        echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_set_proxy ;;
            2) fn_clear_proxy ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_start_st() {
    clear
    fn_print_header "启动酒馆"
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "酒馆尚未安装，请先部署。"
        fn_press_any_key
        return
    fi

    if [ -f "$LAB_CONFIG_FILE" ] && grep -q "AUTO_START_GCLI=\"true\"" "$LAB_CONFIG_FILE"; then
        if [ -d "$GCLI_DIR" ]; then
            if ! pm2 list 2>/dev/null | grep -q "web.*online"; then
                if fn_gcli_start_service >/dev/null 2>&1; then
                    echo -e "[gcli2api] 服务已在后台启动..."
                else
                    echo -e "${YELLOW}[警告] gcli2api 启动失败，跳过...${NC}"
                fi
            fi
        fi
    fi

    if [ -f "$LAB_CONFIG_FILE" ] && grep -q "AUTO_START_ANTIGRAVITY=\"true\"" "$LAB_CONFIG_FILE"; then
        if [ -d "$ANTIGRAVITY_DIR" ]; then
            if ! pm2 list 2>/dev/null | grep -q "antigravity.*online"; then
                if fn_antigravity_start_service >/dev/null 2>&1; then
                    echo -e "[反重力2api] 服务已在后台启动..."
                else
                    echo -e "${YELLOW}[警告] 反重力2api 启动失败，跳过...${NC}"
                fi
            fi
        fi
    fi

    cd "$ST_DIR" || fn_print_error_exit "无法进入酒馆目录。"
    echo -e "正在配置NPM镜像并准备启动环境..."
    npm config set registry https://registry.npmmirror.com
    echo -e "${YELLOW}环境准备就绪，正在启动酒馆服务...${NC}"
    echo -e "${YELLOW}首次启动或更新后会自动安装依赖，耗时可能较长...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}酒馆已停止运行。${NC}"
    fn_press_any_key
}

fn_create_zip_backup() {
    local backup_type="$1"
    if [ ! -d "$ST_DIR" ]; then
        fn_print_error "酒馆目录不存在，无法创建本地备份。"
        return 1
    fi
    cd "$ST_DIR" || { fn_print_error "无法进入酒馆目录进行备份。"; return 1; }
    
    local default_paths=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    local paths_to_backup=()
    if [ -f "$CONFIG_FILE" ]; then
        mapfile -t paths_to_backup < "$CONFIG_FILE"
    fi
    if [ ${#paths_to_backup[@]} -eq 0 ]; then
        paths_to_backup=("${default_paths[@]}")
    fi

    mkdir -p "$BACKUP_ROOT_DIR"
    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -n | cut -d' ' -f2-)
    local current_backup_count=${#all_backups[@]}
    
    echo -e "${YELLOW}当前本地备份数: ${current_backup_count}/${BACKUP_LIMIT}${NC}"

    if [ "$current_backup_count" -ge "$BACKUP_LIMIT" ]; then
        local oldest_backup="${all_backups[0]}"
        fn_print_warning "警告：本地备份已达上限 (${BACKUP_LIMIT}/${BACKUP_LIMIT})。"
        echo -e "创建新备份将会自动删除最旧的一个备份文件:\n  - ${RED}将被删除: $(basename "$oldest_backup")${NC}"
        read -p "是否继续创建本地备份？[Y/n]: " confirm_overwrite
        if [[ "$confirm_overwrite" =~ ^[nN]$ ]]; then
            fn_print_warning "操作已取消。"
            return 1
        fi
    fi

    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_备份_${backup_type}_${timestamp}.zip"
    local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}"
    fn_print_warning "正在创建“${backup_type}”类型的本地备份..."

    local valid_paths=()
    for item in "${paths_to_backup[@]}"; do
        [ -e "$item" ] && valid_paths+=("$item")
    done
    if [ ${#valid_paths[@]} -eq 0 ]; then
        fn_print_error "未能收集到任何有效文件进行本地备份。"
        return 1
    fi

    local exclude_params=(-x "*/_cache/*" -x "*.log" -x "*/backups/*")
    if zip -rq "$backup_zip_path" "${valid_paths[@]}" "${exclude_params[@]}"; then
        if [ "$current_backup_count" -ge "$BACKUP_LIMIT" ]; then
            fn_print_warning "正在清理旧备份..."
            rm "$oldest_backup"
            echo "  - 已删除: $(basename "$oldest_backup")"
        fi
        mapfile -t new_all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip")
        fn_print_success "本地备份成功：${backup_name} (当前: ${#new_all_backups[@]}/${BACKUP_LIMIT})"
        echo -e "  ${CYAN}保存路径: ${backup_zip_path}${NC}"
        cd "$HOME"
        echo "$backup_zip_path"
        return 0
    else
        fn_print_error "创建本地 .zip 备份失败！"
        cd "$HOME"
        return 1
    fi
}

fn_install_st() {
    local auto_start=true
    if [[ "$1" == "no-start" ]]; then
        auto_start=false
    fi
    clear
    fn_print_header "酒馆部署向导"
    if [[ "$auto_start" == "true" ]]; then
        while true; do
            if ! fn_update_termux_source; then
                read -p $'\n'"${RED}软件源配置失败。是否重试？(直接回车=是, 输入n=否): ${NC}" retry_choice
                if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                    fn_print_error_exit "用户取消操作。"
                fi
            else
                break
            fi
        done
        fn_print_header "2/5: 安装核心依赖"
        echo -e "${YELLOW}正在安装核心依赖...${NC}"
        yes | pkg upgrade -y
        yes | pkg install git nodejs-lts rsync zip unzip termux-api coreutils gawk bc || fn_print_error_exit "核心依赖安装失败！"
        fn_print_success "核心依赖安装完毕。"
    fi
    fn_print_header "3/5: 下载酒馆主程序"
    if [ -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "检测到完整的酒馆安装，跳过下载。"
    elif [ -d "$ST_DIR" ] && [ -n "$(ls -A "$ST_DIR")" ]; then
        fn_print_error_exit "目录 $ST_DIR 已存在但安装不完整。请手动删除该目录后再试。"
    else
        local download_success=false
        local full_retest_attempted=false
        while ! $download_success; do
            local mirrors_to_try=()
            if [ "$full_retest_attempted" = false ]; then
                mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "official_only")
                if [ ${#mirrors_to_try[@]} -eq 0 ]; then
                    mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "mirrors_only")
                fi
            else
                mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "all")
            fi

            if [ ${#mirrors_to_try[@]} -eq 0 ]; then
                read -p $'\n'"${RED}所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice
                if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                    fn_print_error_exit "下载失败，用户取消操作。"
                fi
                full_retest_attempted=false
                continue
            fi

            for mirror_url in "${mirrors_to_try[@]}"; do
                local mirror_host
                mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
                fn_print_warning "正在尝试从镜像 [${mirror_host}] 下载 (${REPO_BRANCH} 分支)..."
                local git_output
                git_output=$(git clone --depth 1 -b "$REPO_BRANCH" "$mirror_url" "$ST_DIR" 2>&1)
                if [ $? -eq 0 ]; then
                    fn_print_success "主程序下载完成。"
                    download_success=true
                    break
                else
                    fn_print_error "使用镜像 [${mirror_host}] 下载失败！Git输出: $(echo "$git_output" | tail -n 2)"
                    rm -rf "$ST_DIR"
                fi
            done

            if ! $download_success; then
                if [ "$full_retest_attempted" = false ]; then
                    full_retest_attempted=true
                    fn_print_error "预选线路均下载失败。将进行全量测速并重试所有可用线路..."
                else
                    fn_print_error "已尝试所有可用线路，下载均失败。"
                fi
            fi
        done
    fi
    fn_print_header "4/5: 配置并安装依赖"
    if [ -d "$ST_DIR" ]; then
        if ! fn_run_npm_install; then
            fn_print_error_exit "依赖安装最终失败，部署中断。"
        fi
    else
        fn_print_warning "酒馆目录不存在，跳过此步。"
    fi
    if $auto_start; then
        fn_print_header "5/5: 设置快捷方式与自启"
        fn_create_shortcut
        fn_manage_autostart "set_default"
        echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"
        sleep 3
        fn_start_st
    else
        fn_print_success "全新版本下载与配置完成。"
    fi
}

fn_update_st() {
    clear
    fn_print_header "更新酒馆"
    if [ ! -d "$ST_DIR/.git" ]; then
        fn_print_warning "未找到Git仓库，请先完整部署。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入酒馆目录: $ST_DIR"

    local mirrors_to_try=()
    mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "official_only")
    if [ ${#mirrors_to_try[@]} -eq 0 ]; then
        mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "mirrors_only")
    fi
    if [ ${#mirrors_to_try[@]} -eq 0 ]; then
        fn_print_error "所有线路均测试失败，无法更新。"
        fn_press_any_key
        return
    fi

    local pull_succeeded=false
    for mirror_url in "${mirrors_to_try[@]}"; do
        local mirror_host
        mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
        fn_print_warning "正在尝试使用线路 [${mirror_host}] 更新..."
        git remote set-url origin "$mirror_url" >/dev/null 2>&1

        local git_output
        git_output=$(git pull origin "$REPO_BRANCH" --allow-unrelated-histories 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            if [[ "$git_output" == *"Already up to date."* ]]; then
                fn_print_success "代码已是最新，无需更新。"
            else
                fn_print_success "代码更新成功。"
            fi
            pull_succeeded=true
            break
        elif echo "$git_output" | grep -qE "overwritten by merge|Please commit|unmerged files|Pulling is not possible"; then
            clear
            fn_print_header "检测到更新冲突"
            fn_print_warning "原因: 您可能修改过酒馆的文件，导致无法自动合并新版本。"
            echo -e "\n--- 冲突文件预览 ---\n$(echo "$git_output" | grep -E '^\s+' | head -n 5)\n--------------------"
            echo -e "\n${CYAN}此操作将放弃您对代码文件的修改，但不会影响您的用户数据 (如聊天记录、角色卡等)。${NC}"
            read -p "是否要强制覆盖本地修改以完成更新？(直接回车=是, 输入n=否): " confirm_choice
            
            if [[ "$confirm_choice" =~ ^[nN]$ ]]; then
                fn_print_warning "已取消更新。"
                break
            fi

            fn_print_warning "正在执行强制覆盖 (git reset --hard)..."
            if git reset --hard "origin/$REPO_BRANCH" >/dev/null 2>&1; then
                fn_print_warning "正在重新拉取最新代码..."
                if git pull origin "$REPO_BRANCH" --allow-unrelated-histories >/dev/null 2>&1; then
                    fn_print_success "强制更新成功。"
                    pull_succeeded=true
                else
                    fn_print_error "强制覆盖后拉取代码失败，请重试。"
                fi
            else
                fn_print_error "强制覆盖失败！"
            fi
            break
        else
            fn_print_error "使用线路 [${mirror_host}] 更新失败，正在切换..."
        fi
    done

    if $pull_succeeded; then
        if fn_run_npm_install; then
            fn_print_success "酒馆更新完成！"
        else
            fn_print_error "代码已更新，但依赖安装失败。更新未全部完成。"
        fi
    else
        fn_print_error "更新失败或已取消。"
    fi
    fn_press_any_key
}

fn_rollback_st() {
    clear
    fn_print_header "回退酒馆版本"
    if [ ! -d "$ST_DIR/.git" ]; then
        fn_print_warning "未找到Git仓库，请先完整部署。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入酒馆目录: $ST_DIR"

    fn_print_warning "正在从远程仓库获取所有版本信息..."
    local mirrors_to_try=()
    mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "official_only")
    if [ ${#mirrors_to_try[@]} -eq 0 ]; then
        mapfile -t mirrors_to_try < <(fn_find_fastest_mirror "mirrors_only")
    fi
    if [ ${#mirrors_to_try[@]} -eq 0 ]; then
        fn_print_error "所有线路均测试失败，无法获取版本列表。"
        fn_press_any_key
        return
    fi

    local fetch_ok=false
    for mirror_url in "${mirrors_to_try[@]}"; do
        local mirror_host
        mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
        fn_print_warning "正在尝试使用线路 [${mirror_host}] 获取信息..."
        git remote set-url origin "$mirror_url" >/dev/null 2>&1
        if git fetch --all --tags >/dev/null 2>&1; then
            fetch_ok=true
            break
        fi
        fn_print_error "使用线路 [${mirror_host}] 获取失败，正在切换..."
    done

    if ! $fetch_ok; then
        fn_print_error "尝试了所有可用线路，但无法从远程仓库获取版本信息。"
        fn_press_any_key
        return
    fi

    fn_print_success "版本信息获取成功。"
    mapfile -t all_tags < <(git tag --sort=-v:refname | grep '^[0-9]')
    if [ ${#all_tags[@]} -eq 0 ]; then
        fn_print_error "未能找到任何有效的版本标签。"
        fn_press_any_key
        return
    fi

    local current_tags=("${all_tags[@]}")
    local page_size=15
    local page_num=0
    local selected_tag=""

    while true; do
        clear
        fn_print_header "选择要切换的版本"
        local total_pages=$(( (${#current_tags[@]} + page_size - 1) / page_size ))
        if [ $total_pages -eq 0 ]; then total_pages=1; fi
        echo "第 $((page_num + 1)) / $total_pages 页 (共 ${#current_tags[@]} 个版本)"
        echo "──────────────────────────────────"
        
        local start_index=$((page_num * page_size))
        
        local page_tags=("${current_tags[@]:$start_index:$page_size}")
        for i in "${!page_tags[@]}"; do
            printf "  [%2d] %s\n" "$((start_index + i + 1))" "${page_tags[$i]}"
        done

        echo "──────────────────────────────────"
        echo -e "操作提示:"
        echo -e "  - 直接输入 ${GREEN}序号${NC} (如 '1') 或 ${GREEN}版本全名${NC} (如 '1.10.0') 进行选择"
        echo -e "  - 输入 ${GREEN}a${NC} 翻到上一页，${GREEN}d${NC} 翻到下一页"
        echo -e "  - 输入 ${GREEN}f [关键词]${NC} 筛选版本 (如 'f 1.10')"
        echo -e "  - 输入 ${GREEN}c${NC} 清除筛选，${GREEN}q${NC} 退出"
        read -p "请输入操作: " user_input

        case "$user_input" in
            [qQ]) fn_print_warning "操作已取消。"; fn_press_any_key; return ;;
            [aA]) if [ $page_num -gt 0 ]; then page_num=$((page_num - 1)); fi ;;
            [dD]) if [ $(( (page_num + 1) * page_size )) -lt ${#current_tags[@]} ]; then page_num=$((page_num + 1)); fi ;;
            [cC]) current_tags=("${all_tags[@]}"); page_num=0 ;;
            f\ *)
                local keyword="${user_input#f }"
                mapfile -t filtered_tags < <(printf '%s\n' "${all_tags[@]}" | grep "$keyword")
                if [ ${#filtered_tags[@]} -gt 0 ]; then
                    current_tags=("${filtered_tags[@]}"); page_num=0
                else
                    fn_print_error "未找到包含 '$keyword' 的版本。"; sleep 1.5
                fi
                ;;
            *)
                if [[ "$user_input" =~ ^[0-9]+$ ]] && [ "$user_input" -ge 1 ] && [ "$user_input" -le ${#current_tags[@]} ]; then
                    selected_tag="${current_tags[$((user_input - 1))]}"
                    break
                elif echo "${all_tags[@]}" | tr ' ' '\n' | grep -q -w "$user_input"; then
                    selected_tag="$user_input"
                    break
                else
                    fn_print_error "无效输入。"; sleep 1
                fi
                ;;
        esac
    done

    if [ -n "$selected_tag" ]; then
        echo -e "\n${CYAN}此操作仅会改变酒馆的程序版本，不会影响您的用户数据 (如聊天记录、角色卡等)。${NC}"
        echo -en "确认要切换到版本 ${YELLOW}${selected_tag}${NC} 吗？(直接回车=是, 输入n=否): "
        read confirm
        if [[ "$confirm" =~ ^[nN]$ ]]; then
            fn_print_warning "操作已取消。"
            fn_press_any_key
            return
        fi

        fn_print_warning "正在尝试切换到版本 ${selected_tag}..."
        local checkout_output
        checkout_output=$(git checkout "tags/$selected_tag" 2>&1)
        local exit_code=$?
        local checkout_succeeded=false

        if [ $exit_code -eq 0 ]; then
            fn_print_success "版本已成功切换到 ${selected_tag}"
            checkout_succeeded=true
        elif echo "$checkout_output" | grep -qE "overwritten by checkout|Please commit"; then
            fn_print_header "检测到切换冲突"
            fn_print_warning "原因: 您有本地文件修改，与目标版本冲突。"
            echo -e "\n${CYAN}此操作将放弃您对代码文件的修改，但不会影响您的用户数据。${NC}"
            read -p "是否要强制覆盖本地修改以完成切换？(直接回车=是, 输入n=否): " force_confirm
            if [[ "$force_confirm" =~ ^[nN]$ ]]; then
                fn_print_warning "已取消版本切换。"
            else
                fn_print_warning "正在执行强制切换 (git checkout -f)..."
                if git checkout -f "tags/$selected_tag" >/dev/null 2>&1; then
                    fn_print_success "版本已成功强制切换到 ${selected_tag}"
                    checkout_succeeded=true
                else
                    fn_print_error "强制切换失败！"
                fi
            fi
        else
            fn_print_error "切换失败！Git输出: $(echo "$checkout_output" | tail -n 2)"
        fi

        if $checkout_succeeded; then
            if fn_run_npm_install; then
                fn_print_success "版本切换并同步依赖成功！"
            else
                fn_print_error "版本已切换，但依赖同步失败。请检查网络或手动运行 npm install。"
            fi
        fi
    fi
    fn_press_any_key
}

fn_menu_backup_interactive() {
    clear
    fn_print_header "创建新的本地备份"
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "酒馆尚未安装，无法备份。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入酒馆目录: $ST_DIR"

    declare -A ALL_PATHS=( ["./data"]="用户数据 (聊天/角色/设置)" ["./public/scripts/extensions/third-party"]="前端扩展" ["./plugins"]="后端扩展" ["./config.yaml"]="服务器配置 (网络/安全)" )
    local options=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    local default_selection=("${options[@]}")
    local selection_to_load=()
    if [ -f "$CONFIG_FILE" ]; then
        mapfile -t selection_to_load <"$CONFIG_FILE"
    fi
    if [ ${#selection_to_load[@]} -eq 0 ]; then
        selection_to_load=("${default_selection[@]}")
    fi

    declare -A selection_status
    for key in "${options[@]}"; do
        selection_status["$key"]=false
    done
    for key in "${selection_to_load[@]}"; do
        if [[ -v selection_status["$key"] ]]; then
            selection_status["$key"]=true
        fi
    done

    while true; do
        clear
        fn_print_header "请选择要备份的内容 (定义备份范围)"
        echo "此处的选择将作为所有本地备份(包括自动备份)的范围。"
        echo "输入数字可切换勾选状态。"
        for i in "${!options[@]}"; do
            local key="${options[$i]}"
            local description="${ALL_PATHS[$key]}"
            if ${selection_status[$key]}; then
                printf "  [%-2d] ${GREEN}[✓] %s${NC}\n" "$((i + 1))" "$key"
            else
                printf "  [%-2d] [ ] %s${NC}\n" "$((i + 1))" "$key"
            fi
            printf "      ${CYAN}(%s)${NC}\n" "$description"
        done
        echo -e "\n      ${GREEN}[回车] 保存设置并开始备份${NC}\n      ${RED}[0] 返回上一级${NC}"
        read -p "请操作 [输入数字, 回车 或 0]: " user_choice
        case "$user_choice" in
        "" | [sS]) break ;;
        0) echo "操作已取消。"; return ;;
        *) 
            if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "${#options[@]}" ]; then
                local selected_key="${options[$((user_choice - 1))]}"
                if ${selection_status[$selected_key]}; then
                    selection_status[$selected_key]=false
                else
                    selection_status[$selected_key]=true
                fi
            else
                fn_print_warning "无效输入。"
                sleep 1
            fi
            ;;
        esac
    done

    local paths_to_save=()
    for key in "${options[@]}"; do
        if ${selection_status[$key]}; then
            paths_to_save+=("$key")
        fi
    done
    if [ ${#paths_to_save[@]} -eq 0 ]; then
        fn_print_warning "您没有选择任何项目，本地备份已取消。"
        fn_press_any_key
        return
    fi
    
    printf "%s\n" "${paths_to_save[@]}" > "$CONFIG_FILE"
    fn_print_success "备份范围已保存！"
    sleep 1
    if fn_create_zip_backup "手动"; then
        :
    else
        fn_print_error "手动本地备份创建失败。"
    fi
    fn_press_any_key
}

fn_menu_manage_backups() {
    while true; do
        clear
        mkdir -p "$BACKUP_ROOT_DIR"
        mapfile -t backup_files < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
        local count=${#backup_files[@]}

        fn_print_header "本地备份管理 (当前: ${count}/${BACKUP_LIMIT})"
        if [ "$count" -eq 0 ]; then
            echo -e "      ${YELLOW}没有找到任何本地备份文件。${NC}"
        else
            echo " [序号] [类型]   [创建日期与时间]  [大小]  [文件名]"
            echo " ─────────────────────────────────────────────────────────────"
            for i in "${!backup_files[@]}"; do
                local file_path="${backup_files[$i]}"
                local filename
                filename=$(basename "$file_path")
                local type
                type=$(echo "$filename" | awk -F'[_.]' '{print $3}')
                local date
                date=$(echo "$filename" | awk -F'[_.]' '{print $4}')
                local time
                time=$(echo "$filename" | awk -F'[_.]' '{print $5}')
                local size
                size=$(du -h "$file_path" | awk '{print $1}')
                printf " [%2d]   %-7s  %s %s  %-6s  %s\n" "$((i+1))" "$type" "$date" "$time" "$size" "$filename"
            done
        fi
        
        echo -e "\n  ${RED}请输入要删除的备份序号 (多选请用空格隔开, 输入 'all' 全选)。${NC}"
        echo -e "  按 ${CYAN}[回车] 键直接返回${NC}，或输入 ${CYAN}[0] 返回${NC}。"
        read -p "  请操作: " selection
        if [[ -z "$selection" || "$selection" == "0" ]]; then
            break
        fi

        local files_to_delete=()
        if [[ "$selection" == "all" || "$selection" == "*" ]]; then
            files_to_delete=("${backup_files[@]}")
        else
            for index in $selection; do
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ]; then
                    files_to_delete+=("${backup_files[$((index-1))]}")
                else
                    fn_print_error "无效的序号: $index"
                    sleep 2
                    continue 2
                fi
            done
        fi

        if [ ${#files_to_delete[@]} -gt 0 ]; then
            clear
            fn_print_warning "警告：以下本地备份文件将被永久删除，此操作不可撤销！"
            for file in "${files_to_delete[@]}"; do
                echo -e "  - ${RED}$(basename "$file")${NC}"
            done
            read -p $'\n'"确认要删除这 ${#files_to_delete[@]} 个文件吗？[y/N]: " confirm_delete
            if [[ "$confirm_delete" =~ ^[yY]$ ]]; then
                for file in "${files_to_delete[@]}"; do
                    rm "$file"
                done
                fn_print_success "选定的本地备份文件已删除。"
                sleep 2
            else
                fn_print_warning "删除操作已取消。"
                sleep 2
            fi
        fi
    done
}

fn_menu_backup() {
    while true; do
        clear
        fn_print_header "本地备份管理"
        echo -e "      [1] ${CYAN}创建新的本地备份${NC}"
        echo -e "      [2] ${CYAN}管理已有的本地备份${NC}\n"
        echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_menu_backup_interactive ;;
            2) fn_menu_manage_backups ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_update_script() {
    clear
    fn_print_header "更新咕咕助手脚本"
    fn_print_warning "正在从 Gitee 下载新版本..."
    local temp_file
    temp_file=$(mktemp)
    if ! curl -L -o "$temp_file" "$SCRIPT_URL"; then
        rm -f "$temp_file"
        fn_print_warning "下载失败。"
    elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
        rm -f "$temp_file"
        fn_print_success "当前已是最新版本。"
    else
        sed -i 's/\r$//' "$temp_file"
        chmod +x "$temp_file"
        mv "$temp_file" "$SCRIPT_SELF_PATH"
        rm -f "$UPDATE_FLAG_FILE"
        echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"
        sleep 2
        exec "$SCRIPT_SELF_PATH" --updated
    fi
    fn_press_any_key
}

fn_check_for_updates() {
    (
        local temp_file
        temp_file=$(mktemp)
        if curl -L -s --connect-timeout 10 -o "$temp_file" "$SCRIPT_URL"; then
            if ! cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
                touch "$UPDATE_FLAG_FILE"
            else
                rm -f "$UPDATE_FLAG_FILE"
            fi
        fi
        rm -f "$temp_file"
    ) &
}

fn_create_shortcut() {
    local BASHRC_FILE="$HOME/.bashrc"
    local ALIAS_CMD="alias gugu='\"$SCRIPT_SELF_PATH\"'"
    local ALIAS_COMMENT="# 咕咕助手快捷命令"
    if ! grep -qF "$ALIAS_CMD" "$BASHRC_FILE"; then
        chmod +x "$SCRIPT_SELF_PATH"
        echo -e "\n$ALIAS_COMMENT\n$ALIAS_CMD" >>"$BASHRC_FILE"
        fn_print_success "已创建快捷命令 'gugu'。请重启 Termux 或执行 'source ~/.bashrc' 生效。"
    fi
}

fn_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"
    local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""
    local is_set=false
    grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true
    if [[ "$1" == "set_default" ]]; then
        if ! $is_set; then
            echo -e "\n# 咕咕助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"
            fn_print_success "已设置 Termux 启动时自动运行本助手。"
        fi
        return
    fi
    clear
    fn_print_header "管理助手自启"
    if $is_set; then
        echo -e "当前状态: ${GREEN}已启用${NC}\n${CYAN}提示: 关闭自启后，输入 'gugu' 命令即可手动启动助手。${NC}"
        read -p "是否取消自启？ [Y/n]: " confirm
        if [[ ! "$confirm" =~ ^[nN]$ ]]; then
            fn_create_shortcut
            sed -i "/# 咕咕助手/d" "$BASHRC_FILE"
            sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"
            fn_print_success "已取消自启。"
        fi
    else
        echo -e "当前状态: ${RED}未启用${NC}\n${CYAN}提示: 在 Termux 中输入 'gugu' 命令可以手动启动助手。${NC}"
        read -p "是否设置自启？ [Y/n]: " confirm
        if [[ ! "$confirm" =~ ^[nN]$ ]]; then
            fn_create_shortcut
            echo -e "\n# 咕咕助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"
            fn_print_success "已成功设置自启。"
        fi
    fi
    fn_press_any_key
}

fn_open_docs() {
    clear
    fn_print_header "查看帮助文档"
    local docs_url="https://blog.qjyg.de"
    echo -e "文档网址: ${CYAN}${docs_url}${NC}\n"
    if fn_check_command "termux-open-url"; then
        termux-open-url "$docs_url"
        fn_print_success "已尝试在浏览器中打开，若未自动跳转请手动复制上方网址。"
    else
        fn_print_warning "命令 'termux-open-url' 不存在。\n请先安装【Termux:API】应用及 'pkg install termux-api'。"
    fi
    fn_press_any_key
}

fn_migrate_configs() {
    local migration_needed=false
    local OLD_CONFIG_FILE="$HOME/.st_assistant.conf"
    local OLD_GIT_SYNC_CONFIG_FILE="$HOME/.st_sync.conf"
    mkdir -p "$CONFIG_DIR"
    if [ -f "$OLD_CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
        mv "$OLD_CONFIG_FILE" "$CONFIG_FILE"
        fn_print_warning "已将旧的备份配置文件迁移至新位置。"
        migration_needed=true
    fi
    if [ -f "$OLD_GIT_SYNC_CONFIG_FILE" ] && [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then
        mv "$OLD_GIT_SYNC_CONFIG_FILE" "$GIT_SYNC_CONFIG_FILE"
        fn_print_warning "已将旧的Git同步配置文件迁移至新位置。"
        migration_needed=true
    fi
    if $migration_needed; then
        fn_print_success "配置文件迁移完成！"
        sleep 2
    fi
}

fn_migrate_configs
fn_apply_proxy
fn_show_agreement_if_first_run

if [[ "$1" != "--no-check" && "$1" != "--updated" ]]; then
    fn_check_for_updates
fi

if [[ "$1" == "--updated" ]]; then
    clear
    fn_print_success "助手已成功更新至最新版本！"
    sleep 2
fi

git config --global --add safe.directory '*' 2>/dev/null || true

fn_gcli_patch_pydantic() {
    if [ ! -d "$GCLI_DIR/.venv" ]; then return 1; fi
    fn_print_warning "正在检查并应用 Pydantic 兼容性补丁..."
    "$GCLI_DIR/.venv/bin/python" -c "import pydantic; from pydantic import BaseModel;
if not hasattr(BaseModel, 'model_dump'):
    path = pydantic.main.__file__
    with open(path, 'a') as f:
        f.write('\nBaseModel.model_dump = BaseModel.dict\n')
" &>/dev/null
}

fn_set_lab_mirror_preference() {
    local key="$1"
    local title="$2"
    clear
    fn_print_header "设置 $title 安装线路"
    
    local current_pref="Auto"
    if [ -f "$LAB_CONFIG_FILE" ]; then
        local val
        val=$(grep "^${key}=" "$LAB_CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')
        if [ -n "$val" ]; then current_pref="$val"; fi
    fi
    
    local pref_text="自动"
    case "$current_pref" in
        "Auto") pref_text="自动 (优先海外，失败则切国内)" ;;
        "Official") pref_text="强制海外 (GitHub/官方源)" ;;
        "Mirror") pref_text="强制国内 (镜像加速)" ;;
    esac
    
    echo -e "当前设置: ${YELLOW}${pref_text}${NC}"
    echo -e "\n${GREEN}[1] 自动 (推荐)${NC}"
    echo -e "    优先尝试官方源，如果失败自动切换到国内镜像。"
    echo -e "${CYAN}[2] 强制海外${NC}"
    echo -e "    只使用官方源。适合网络环境极好(有梯子)的用户。"
    echo -e "${CYAN}[3] 强制国内${NC}"
    echo -e "    只使用国内镜像。适合无梯子用户。"
    
    read -p $'\n请选择 [1-3]: ' choice
    local new_pref=""
    case "$choice" in
        1) new_pref="Auto" ;;
        2) new_pref="Official" ;;
        3) new_pref="Mirror" ;;
        *) fn_print_warning "无效输入。"; sleep 1; return ;;
    esac
    
    mkdir -p "$CONFIG_DIR"
    touch "$LAB_CONFIG_FILE"
    sed -i "/^${key}=/d" "$LAB_CONFIG_FILE"
    echo "${key}=\"${new_pref}\"" >> "$LAB_CONFIG_FILE"
    fn_print_success "设置已保存！"
    sleep 1
}

fn_get_git_version() {
    local target_dir="$1"
    if [ ! -d "$target_dir/.git" ]; then
        echo "未知"
        return
    fi
    
    local date
    date=$(git -C "$target_dir" log -1 --format=%cd --date=format:'%Y-%m-%d' 2>/dev/null)
    local hash
    hash=$(git -C "$target_dir" rev-parse --short HEAD 2>/dev/null)
    
    if [[ -n "$date" && -n "$hash" ]]; then
        echo "$date ($hash)"
    else
        echo "未知"
    fi
}

fn_menu_version_management() {
    while true; do
        clear
        fn_print_header "酒馆版本管理"
        echo -e "      [1] ${GREEN}更新酒馆${NC}"
        echo -e "      [2] ${YELLOW}回退版本${NC}\n"
        echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_update_st; break ;;
            2) fn_rollback_st; break ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_install_gcli() {
    clear
    fn_print_header "安装 gcli2api"
    
    echo -e "${RED}${BOLD}【重要提示】${NC}"
    echo -e "此组件 (gcli2api) 由 ${CYAN}su-kaka${NC} 开发。"
    echo -e "项目地址: https://github.com/su-kaka/gcli2api"
    echo -e "本脚本仅作为聚合工具提供安装引导，不修改其原始代码。"
    echo -e "该组件遵循 ${YELLOW}CNC-1.0${NC} 协议，${RED}${BOLD}严禁商业用途${NC}。"
    echo -e "继续安装即代表您知晓并同意遵守该协议。"
    echo -e "────────────────────────────────────────"
    read -p "请输入 'yes' 确认并继续安装: " confirm
    if [[ "$confirm" != "yes" ]]; then
        fn_print_warning "用户取消安装。"
        fn_press_any_key
        return
    fi

    fn_print_warning "正在更新系统软件包以确保兼容性 (pkg upgrade)..."
    if ! pkg update -y || ! pkg upgrade -y; then
        fn_print_error "软件包更新失败！请检查网络连接或手动执行 'pkg upgrade'。"
        fn_press_any_key
        return
    fi

    fn_print_warning "正在检查环境依赖..."
    local packages_to_install=""
    if ! command -v uv &> /dev/null; then packages_to_install+=" uv"; fi
    if ! command -v python &> /dev/null; then packages_to_install+=" python"; fi
    if ! command -v node &> /dev/null; then packages_to_install+=" nodejs"; fi
    if ! command -v git &> /dev/null; then packages_to_install+=" git"; fi

    if [ -n "$packages_to_install" ]; then
        fn_print_warning "正在安装缺失的系统依赖: $packages_to_install"
        pkg install $packages_to_install -y || { fn_print_error "依赖安装失败！"; fn_press_any_key; return; }
    fi

    if ! command -v pm2 &> /dev/null; then
        fn_print_warning "正在安装 pm2..."
        npm install pm2 -g || { fn_print_error "pm2 安装失败！"; fn_press_any_key; return; }
    fi

    local mirror_pref="Auto"
    if [ -f "$LAB_CONFIG_FILE" ]; then
        local val
        val=$(grep "^GCLI_MIRROR_PREF=" "$LAB_CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')
        if [ -n "$val" ]; then mirror_pref="$val"; fi
    fi
    
    local official_git="https://github.com/su-kaka/gcli2api.git"
    local mirror_git="https://hub.gitmirror.com/https://github.com/su-kaka/gcli2api.git"
    
    local use_official_git=true
    if [[ "$mirror_pref" == "Mirror" ]]; then use_official_git=false; fi
    
    fn_print_warning "正在部署 gcli2api (模式: $mirror_pref)..."
    cd "$HOME" || return
    
    if [ -d "$GCLI_DIR" ]; then
        fn_print_warning "检测到旧目录，正在更新..."
        cd "$GCLI_DIR" || return
        
        local update_success=false
        if $use_official_git; then
            echo -e "${BOLD}尝试从官方源拉取...${NC}"
            git remote set-url origin "$official_git"
            if git fetch --all; then update_success=true; fi
        fi
        
        if ! $update_success && [[ "$mirror_pref" == "Auto" || "$mirror_pref" == "Mirror" ]]; then
            if $use_official_git; then fn_print_warning "官方源连接失败，自动切换到国内镜像..."; fi
            git remote set-url origin "$mirror_git"
            if git fetch --all; then update_success=true; fi
        fi
        
        if ! $update_success; then
            fn_print_error "Git 拉取更新失败！请检查网络连接。"
            fn_press_any_key
            return
        fi
        git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
    else
        local clone_success=false
        if $use_official_git; then
            echo -e "${BOLD}尝试从官方源克隆...${NC}"
            if git clone "$official_git" "$GCLI_DIR"; then clone_success=true; fi
        fi
        
        if ! $clone_success && [[ "$mirror_pref" == "Auto" || "$mirror_pref" == "Mirror" ]]; then
            if $use_official_git; then fn_print_warning "官方源连接失败，自动切换到国内镜像..."; fi
            rm -rf "$GCLI_DIR"
            if git clone "$mirror_git" "$GCLI_DIR"; then clone_success=true; fi
        fi
        
        if ! $clone_success; then
            fn_print_error "克隆仓库失败！请检查网络或代理设置。"
            fn_press_any_key
            return
        fi
        cd "$GCLI_DIR" || return
    fi

    fn_print_warning "正在初始化 Python 环境 (uv)..."
    uv venv --clear
    
    local install_success=false
    if [[ "$mirror_pref" == "Official" || "$mirror_pref" == "Auto" ]]; then
        fn_print_warning "尝试使用官方源安装依赖..."
        if uv pip install -r requirements-termux.txt --link-mode copy; then install_success=true; fi
    fi
    
    if ! $install_success && [[ "$mirror_pref" == "Auto" || "$mirror_pref" == "Mirror" ]]; then
        if [[ "$mirror_pref" == "Auto" ]]; then fn_print_warning "官方源安装失败，自动切换到国内镜像..."; else fn_print_warning "使用国内镜像安装依赖..."; fi
        if uv pip install -r requirements-termux.txt --link-mode copy --index-url https://pypi.tuna.tsinghua.edu.cn/simple; then install_success=true; fi
    fi
    
    if ! $install_success; then
        fn_print_error "Python 依赖安装失败！"
        fn_press_any_key
        return
    fi

    fn_gcli_patch_pydantic

    mkdir -p "$CONFIG_DIR"
    if ! grep -q "AUTO_START_GCLI" "$LAB_CONFIG_FILE" 2>/dev/null; then
        echo "AUTO_START_GCLI=\"true\"" >> "$LAB_CONFIG_FILE"
    fi

    fn_print_success "gcli2api 安装/更新完成！"

    if fn_gcli_start_service; then
        if fn_check_command "termux-open-url"; then
            fn_print_warning "正在尝试打开 Web 面板 (http://127.0.0.1:7861)..."
            termux-open-url "http://127.0.0.1:7861"
        fi
    else
        fn_print_error "服务启动失败，未能自动打开面板。"
    fi
    
    fn_press_any_key
}

fn_gcli_start_service() {
    if [ ! -d "$GCLI_DIR" ]; then
        fn_print_error "gcli2api 尚未安装。"
        return 1
    fi
    
    if pm2 list 2>/dev/null | grep -q "web"; then
        fn_print_warning "服务已经在运行中。"
        return 0
    fi

    fn_gcli_patch_pydantic

    fn_print_warning "正在启动 gcli2api 服务..."
    if pm2 start "$GCLI_DIR/.venv/bin/python" --name web --cwd "$GCLI_DIR" -- web.py; then
        fn_print_success "服务启动成功！"
        return 0
    else
        fn_print_error "服务启动失败。"
        return 1
    fi
}

fn_gcli_stop_service() {
    fn_print_warning "正在停止 gcli2api 服务..."
    pm2 stop web >/dev/null 2>&1
    pm2 delete web >/dev/null 2>&1
    fn_print_success "服务已停止。"
}

fn_gcli_uninstall() {
    clear
    fn_print_header "卸载 gcli2api"
    read -p "确认要卸载 gcli2api 吗？(这将删除程序目录和配置文件) [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        fn_gcli_stop_service
        rm -rf "$GCLI_DIR"
        cd "$HOME" || return
        if [ -f "$LAB_CONFIG_FILE" ]; then
             sed -i "/^AUTO_START_GCLI=/d" "$LAB_CONFIG_FILE"
        fi
        fn_print_success "gcli2api 已卸载。"
    else
        fn_print_warning "操作已取消。"
    fi
    fn_press_any_key
}

fn_gcli_show_logs() {
    clear
    fn_print_header "查看运行日志 (最后 50 行)"
    echo -e "────────────────────────────────────────"
    pm2 logs web --lines 50 --nostream
    echo -e "────────────────────────────────────────"
    fn_press_any_key
}

fn_get_gcli_status() {
    if pm2 list 2>/dev/null | grep -q "web.*online"; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

fn_menu_gcli_manage() {
    while true; do
        clear
        fn_print_header "gcli2api 管理"
        local status_text=$(fn_get_gcli_status)
        echo -e "      当前状态: ${status_text}"
        
        if [ -d "$GCLI_DIR" ]; then
            local version=$(fn_get_git_version "$GCLI_DIR")
            echo -e "      当前版本: ${YELLOW}${version}${NC}"
        fi
        echo ""

        local auto_start_status="${RED}关闭${NC}"
        if [ -f "$LAB_CONFIG_FILE" ] && grep -q "AUTO_START_GCLI=\"true\"" "$LAB_CONFIG_FILE"; then
            auto_start_status="${GREEN}开启${NC}"
        fi

        local is_running=false
        if echo "$status_text" | grep -q "运行中"; then
            is_running=true
        fi

        echo -e "      [1] ${CYAN}安装/更新${NC}"
        if $is_running; then
            echo -e "      [2] ${YELLOW}停止服务${NC}"
        else
            echo -e "      [2] ${GREEN}启动服务${NC}"
        fi
        echo -e "      [3] 跟随酒馆启动: [${auto_start_status}]"
        echo -e "      [4] ${RED}卸载 gcli2api${NC}"
        echo -e "      [5] 查看运行日志"
        echo -e "      [6] 打开 Web 面板"
        echo -e "\n      [7] ${YELLOW}切换安装线路${NC}"
        echo -e "      [0] ${CYAN}返回上一级${NC}\n"
        
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_install_gcli ;;
            2)
                if $is_running; then
                    fn_gcli_stop_service
                else
                    fn_gcli_start_service
                fi
                fn_press_any_key
                ;;
            3)
                mkdir -p "$CONFIG_DIR"
                touch "$LAB_CONFIG_FILE"
                if grep -q "AUTO_START_GCLI=\"true\"" "$LAB_CONFIG_FILE"; then
                    sed -i "/^AUTO_START_GCLI=/d" "$LAB_CONFIG_FILE"
                    echo "AUTO_START_GCLI=\"false\"" >> "$LAB_CONFIG_FILE"
                    fn_print_warning "已关闭跟随启动。"
                else
                    sed -i "/^AUTO_START_GCLI=/d" "$LAB_CONFIG_FILE"
                    echo "AUTO_START_GCLI=\"true\"" >> "$LAB_CONFIG_FILE"
                    fn_print_success "已开启跟随启动。"
                fi
                sleep 1
                ;;
            4) fn_gcli_uninstall ;;
            5) fn_gcli_show_logs ;;
            6)
                if fn_check_command "termux-open-url"; then
                    termux-open-url "http://127.0.0.1:7861"
                    fn_print_success "已尝试打开浏览器。"
                else
                    fn_print_error "未找到 termux-open-url 命令。"
                fi
                sleep 1
                ;;
            7) fn_set_lab_mirror_preference "GCLI_MIRROR_PREF" "gcli2api" ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_install_antigravity() {
    clear
    fn_print_header "安装/更新 反重力2api"
    
    echo -e "${RED}${BOLD}【重要提示】${NC}"
    echo -e "此组件 (Antigravity2api) 由 ${CYAN}zhongruan0522${NC} 开发。"
    echo -e "项目地址: https://github.com/zhongruan0522/Antigravity2api-node-js"
    echo -e "本脚本仅作为聚合工具提供安装引导，不修改其原始代码。"
    echo -e "该组件遵循 ${YELLOW}CC BY-NC-SA 4.0${NC} 协议，${RED}${BOLD}严禁商业用途${NC}。"
    echo -e "继续安装即代表您知晓并同意遵守该协议。"
    echo -e "────────────────────────────────────────"
    read -p "请输入 'yes' 确认并继续安装: " confirm
    if [[ "$confirm" != "yes" ]]; then
        fn_print_warning "用户取消安装。"
        fn_press_any_key
        return
    fi

    fn_print_warning "正在检查环境依赖..."
    local packages_to_install=""
    if ! command -v node &> /dev/null; then packages_to_install+=" nodejs"; fi
    if ! command -v git &> /dev/null; then packages_to_install+=" git"; fi

    if [ -n "$packages_to_install" ]; then
        fn_print_warning "正在安装缺失的系统依赖: $packages_to_install"
        pkg install $packages_to_install -y || { fn_print_error "依赖安装失败！"; fn_press_any_key; return; }
    fi

    if ! command -v pm2 &> /dev/null; then
        fn_print_warning "正在安装 pm2..."
        npm install pm2 -g || { fn_print_error "pm2 安装失败！"; fn_press_any_key; return; }
    fi

    local mirror_pref="Auto"
    if [ -f "$LAB_CONFIG_FILE" ]; then
        local val
        val=$(grep "^ANTIGRAVITY_MIRROR_PREF=" "$LAB_CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')
        if [ -n "$val" ]; then mirror_pref="$val"; fi
    fi
    
    local official_git="https://github.com/zhongruan0522/Antigravity2api-node-js.git"
    local mirror_git="https://hub.gitmirror.com/https://github.com/zhongruan0522/Antigravity2api-node-js.git"
    
    local use_official_git=true
    if [[ "$mirror_pref" == "Mirror" ]]; then use_official_git=false; fi
    
    fn_print_warning "正在部署 反重力2api (模式: $mirror_pref)..."
    cd "$HOME" || return
    
    if [ -d "$ANTIGRAVITY_DIR" ]; then
        fn_print_warning "检测到旧目录，正在更新..."
        cd "$ANTIGRAVITY_DIR" || return
        
        local update_success=false
        if $use_official_git; then
            echo -e "${BOLD}尝试从官方源拉取...${NC}"
            git remote set-url origin "$official_git"
            if git fetch --all; then update_success=true; fi
        fi
        
        if ! $update_success && [[ "$mirror_pref" == "Auto" || "$mirror_pref" == "Mirror" ]]; then
            if $use_official_git; then fn_print_warning "官方源连接失败，自动切换到国内镜像..."; fi
            git remote set-url origin "$mirror_git"
            if git fetch --all; then update_success=true; fi
        fi
        
        if ! $update_success; then
            fn_print_error "Git 拉取更新失败！请检查网络连接。"
            fn_press_any_key
            return
        fi
        git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
    else
        local clone_success=false
        if $use_official_git; then
            echo -e "${BOLD}尝试从官方源克隆...${NC}"
            if git clone "$official_git" "$ANTIGRAVITY_DIR"; then clone_success=true; fi
        fi
        
        if ! $clone_success && [[ "$mirror_pref" == "Auto" || "$mirror_pref" == "Mirror" ]]; then
            if $use_official_git; then fn_print_warning "官方源连接失败，自动切换到国内镜像..."; fi
            rm -rf "$ANTIGRAVITY_DIR"
            if git clone "$mirror_git" "$ANTIGRAVITY_DIR"; then clone_success=true; fi
        fi
        
        if ! $clone_success; then
            fn_print_error "克隆仓库失败！请检查网络或代理设置。"
            fn_press_any_key
            return
        fi
        cd "$ANTIGRAVITY_DIR" || return
    fi

    fn_print_warning "正在安装依赖 (npm install)..."
    local install_success=false
    
    if [[ "$mirror_pref" == "Official" || "$mirror_pref" == "Auto" ]]; then
        fn_print_warning "尝试使用官方源安装依赖..."
        npm config delete registry
        if npm install; then install_success=true; fi
    fi
    
    if ! $install_success && [[ "$mirror_pref" == "Auto" || "$mirror_pref" == "Mirror" ]]; then
        if [[ "$mirror_pref" == "Auto" ]]; then fn_print_warning "官方源安装失败，自动切换到国内镜像..."; else fn_print_warning "使用国内镜像安装依赖..."; fi
        npm config set registry https://registry.npmmirror.com
        if npm install; then install_success=true; fi
    fi
    
    if ! $install_success; then
        fn_print_error "依赖安装失败！"
        fn_press_any_key
        return
    fi

    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp ".env.example" ".env"
            fn_print_success "已创建默认配置文件 (.env)。"
            echo -e "${YELLOW}默认账号: admin${NC}"
            echo -e "${YELLOW}默认密码: your-strong-password${NC}"
            echo -e "${YELLOW}默认Key: sk-text${NC}"
        else
            fn_print_warning "未找到 .env.example 模板文件，请手动配置 .env。"
        fi
    fi

    mkdir -p "$CONFIG_DIR"
    if ! grep -q "AUTO_START_ANTIGRAVITY" "$LAB_CONFIG_FILE" 2>/dev/null; then
        echo "AUTO_START_ANTIGRAVITY=\"true\"" >> "$LAB_CONFIG_FILE"
    fi

    fn_print_success "反重力2api 安装/更新完成！"

    if fn_antigravity_start_service; then
        if fn_check_command "termux-open-url"; then
            fn_print_warning "正在尝试打开 Web 面板 (http://127.0.0.1:8045)..."
            termux-open-url "http://127.0.0.1:8045"
        fi
    else
        fn_print_error "服务启动失败，未能自动打开面板。"
    fi
    
    fn_press_any_key
}

fn_antigravity_start_service() {
    if [ ! -d "$ANTIGRAVITY_DIR" ]; then
        fn_print_error "反重力2api 尚未安装。"
        return 1
    fi
    
    if pm2 list 2>/dev/null | grep -q "antigravity"; then
        fn_print_warning "服务已经在运行中。"
        return 0
    fi

    fn_print_warning "正在启动 反重力2api 服务..."
    # 使用 pm2 启动 npm start
    if pm2 start npm --name "antigravity" --cwd "$ANTIGRAVITY_DIR" -- start; then
        fn_print_success "服务启动成功！"
        return 0
    else
        fn_print_error "服务启动失败。"
        return 1
    fi
}

fn_antigravity_stop_service() {
    fn_print_warning "正在停止 反重力2api 服务..."
    pm2 stop antigravity >/dev/null 2>&1
    pm2 delete antigravity >/dev/null 2>&1
    fn_print_success "服务已停止。"
}

fn_antigravity_uninstall() {
    clear
    fn_print_header "卸载 反重力2api"
    read -p "确认要卸载 反重力2api 吗？(这将删除程序目录和配置文件) [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        fn_antigravity_stop_service
        rm -rf "$ANTIGRAVITY_DIR"
        cd "$HOME" || return
        if [ -f "$LAB_CONFIG_FILE" ]; then
             sed -i "/^AUTO_START_ANTIGRAVITY=/d" "$LAB_CONFIG_FILE"
        fi
        fn_print_success "反重力2api 已卸载。"
    else
        fn_print_warning "操作已取消。"
    fi
    fn_press_any_key
}

fn_antigravity_show_logs() {
    clear
    fn_print_header "查看运行日志 (最后 50 行)"
    echo -e "────────────────────────────────────────"
    pm2 logs antigravity --lines 50 --nostream
    echo -e "────────────────────────────────────────"
    fn_press_any_key
}

fn_get_antigravity_status() {
    if pm2 list 2>/dev/null | grep -q "antigravity.*online"; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

fn_menu_antigravity_manage() {
    while true; do
        clear
        fn_print_header "反重力2api 管理"
        local status_text=$(fn_get_antigravity_status)
        echo -e "      当前状态: ${status_text}"
        
        if [ -d "$ANTIGRAVITY_DIR" ]; then
            local version=$(fn_get_git_version "$ANTIGRAVITY_DIR")
            echo -e "      当前版本: ${YELLOW}${version}${NC}"
        fi
        echo ""

        local auto_start_status="${RED}关闭${NC}"
        if [ -f "$LAB_CONFIG_FILE" ] && grep -q "AUTO_START_ANTIGRAVITY=\"true\"" "$LAB_CONFIG_FILE"; then
            auto_start_status="${GREEN}开启${NC}"
        fi

        local is_running=false
        if echo "$status_text" | grep -q "运行中"; then
            is_running=true
        fi

        echo -e "      [1] ${CYAN}安装/更新${NC}"
        if $is_running; then
            echo -e "      [2] ${YELLOW}停止服务${NC}"
        else
            echo -e "      [2] ${GREEN}启动服务${NC}"
        fi
        echo -e "      [3] 跟随酒馆启动: [${auto_start_status}]"
        echo -e "      [4] ${RED}卸载 反重力2api${NC}"
        echo -e "      [5] 查看运行日志"
        echo -e "      [6] 打开 Web 面板"
        echo -e "\n      [7] ${YELLOW}切换安装线路${NC}"
        echo -e "      [0] ${CYAN}返回上一级${NC}\n"
        
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_install_antigravity ;;
            2)
                if $is_running; then
                    fn_antigravity_stop_service
                else
                    fn_antigravity_start_service
                fi
                fn_press_any_key
                ;;
            3)
                mkdir -p "$CONFIG_DIR"
                touch "$LAB_CONFIG_FILE"
                if grep -q "AUTO_START_ANTIGRAVITY=\"true\"" "$LAB_CONFIG_FILE"; then
                    sed -i "/^AUTO_START_ANTIGRAVITY=/d" "$LAB_CONFIG_FILE"
                    echo "AUTO_START_ANTIGRAVITY=\"false\"" >> "$LAB_CONFIG_FILE"
                    fn_print_warning "已关闭跟随启动。"
                else
                    sed -i "/^AUTO_START_ANTIGRAVITY=/d" "$LAB_CONFIG_FILE"
                    echo "AUTO_START_ANTIGRAVITY=\"true\"" >> "$LAB_CONFIG_FILE"
                    fn_print_success "已开启跟随启动。"
                fi
                sleep 1
                ;;
            4) fn_antigravity_uninstall ;;
            5) fn_antigravity_show_logs ;;
            6)
                if fn_check_command "termux-open-url"; then
                    termux-open-url "http://127.0.0.1:8045"
                    fn_print_success "已尝试打开浏览器。"
                else
                    fn_print_error "未找到 termux-open-url 命令。"
                fi
                sleep 1
                ;;
            7) fn_set_lab_mirror_preference "ANTIGRAVITY_MIRROR_PREF" "反重力2api" ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_menu_st_config() {
    while true; do
        clear
        fn_print_header "酒馆配置管理"
        if [ ! -f "$ST_DIR/config.yaml" ]; then
            fn_print_warning "未找到 config.yaml，请先部署酒馆。"
            fn_press_any_key; return
        fi

        local curr_port=$(fn_get_st_config_value "port")
        local curr_auth=$(fn_get_st_config_value "basicAuthMode")
        local curr_user=$(fn_get_st_config_value "enableUserAccounts")
        local curr_listen=$(fn_get_st_config_value "listen")

        local mode_text="未知"
        if [[ "$curr_auth" == "false" && "$curr_user" == "false" ]]; then
            mode_text="默认 (无账密)"
        elif [[ "$curr_auth" == "true" && "$curr_user" == "false" ]]; then
            mode_text="单用户 (基础账密)"
        elif [[ "$curr_auth" == "false" && "$curr_user" == "true" ]]; then
            mode_text="多用户 (独立账户)"
        fi

        echo -e "      当前端口: ${GREEN}${curr_port}${NC}"
        echo -e "      当前模式: ${GREEN}${mode_text}${NC}"
        if [[ "$curr_auth" == "true" && "$curr_user" == "false" ]]; then
            local u=$(fn_get_st_nested_config_value "basicAuthUser" "username")
            local p=$(fn_get_st_nested_config_value "basicAuthUser" "password")
            echo -e "      当前账密: ${BOLD}${u} / ${p}${NC}"
        fi
        echo -en "      局域网访问: "
        if [[ "$curr_listen" == "true" ]]; then echo -e "${GREEN}已开启${NC}"; else echo -e "${RED}已关闭${NC}"; fi

        echo -e "\n      [1] ${CYAN}修改端口号${NC}"
        echo -e "      [2] ${CYAN}切换为：默认无账密模式${NC}"
        
        if [[ "$curr_auth" == "true" && "$curr_user" == "false" ]]; then
            echo -e "      [3] ${CYAN}修改单用户账密${NC}"
        else
            echo -e "      [3] ${CYAN}切换为：单用户账密模式${NC}"
        fi
        
        echo -e "      [4] ${CYAN}切换为：多用户账密模式${NC}"
        
        if [[ "$curr_listen" == "true" ]]; then
            echo -e "      [5] ${RED}关闭局域网访问${NC}"
        else
            echo -e "      [5] ${YELLOW}允许局域网访问 (需开启账密)${NC}"
        fi
        
        echo -e "\n      [0] ${CYAN}返回上一级${NC}"

        read -p "    请输入选项: " choice
        case "$choice" in
            1)
                read -p "请输入新的端口号 (1024-65535): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                    fn_update_st_config_value "port" "$new_port"
                    fn_print_success "端口已修改为 $new_port"
                    fn_print_warning "设置将在重启酒馆后生效。"
                else
                    fn_print_error "无效的端口号。"
                fi
                fn_press_any_key
                ;;
            2)
                fn_update_st_config_value "basicAuthMode" "false"
                fn_update_st_config_value "enableUserAccounts" "false"
                fn_update_st_config_value "listen" "false"
                fn_print_success "已切换为默认无账密模式 (局域网访问已同步关闭)。"
                fn_print_warning "设置将在重启酒馆后生效。"
                fn_press_any_key
                ;;
            3)
                read -p "请输入用户名: " u
                read -p "请输入密码: " p
                if [[ -z "$u" || -z "$p" ]]; then
                    fn_print_error "用户名和密码不能为空！"
                else
                    fn_update_st_config_value "basicAuthMode" "true"
                    fn_update_st_config_value "enableUserAccounts" "false"
                    fn_update_st_nested_config_value "basicAuthUser" "username" "\"$u\""
                    fn_update_st_nested_config_value "basicAuthUser" "password" "\"$p\""
                    fn_print_success "单用户账密配置已更新。"
                    fn_print_warning "设置将在重启酒馆后生效。"
                fi
                fn_press_any_key
                ;;
            4)
                fn_update_st_config_value "basicAuthMode" "false"
                fn_update_st_config_value "enableUserAccounts" "true"
                fn_update_st_config_value "enableDiscreetLogin" "true"
                fn_print_success "已切换为多用户账密模式。"
                echo -e "\n${YELLOW}【重要提示】${NC}"
                echo -e "请在启动酒馆后，进入 [用户设置] -> [管理员面板] 设置管理员密码，否则多用户模式可能无法正常工作。"
                fn_print_warning "设置将在重启酒馆后生效。"
                fn_press_any_key
                ;;
            5)
                if [[ "$curr_listen" == "true" ]]; then
                    fn_update_st_config_value "listen" "false"
                    fn_print_success "局域网访问已关闭。"
                    fn_print_warning "设置将在重启酒馆后生效。"
                else
                    if [[ "$curr_auth" == "false" && "$curr_user" == "false" ]]; then
                        fn_print_warning "局域网访问必须开启账密模式！"
                        read -p "是否自动开启单用户账密模式？[Y/n]: " confirm
                        if [[ ! "$confirm" =~ ^[nN]$ ]]; then
                            read -p "请设置用户名: " u
                            read -p "请设置密码: " p
                            if [[ -z "$u" || -z "$p" ]]; then
                                fn_print_error "用户名和密码不能为空，操作已取消。"
                                fn_press_any_key; continue
                            fi
                            fn_update_st_config_value "basicAuthMode" "true"
                            fn_update_st_nested_config_value "basicAuthUser" "username" "\"$u\""
                            fn_update_st_nested_config_value "basicAuthUser" "password" "\"$p\""
                        else
                            fn_print_error "操作已取消。"
                            sleep 1; continue
                        fi
                    fi
                    fn_update_st_config_value "listen" "true"
                    
                    # 精准 IP 检测逻辑：仅保留 WiFi(wlan)、热点(ap)、USB共享(rndis) 和 有线(eth)
                    local ip_info=""
                    local valid_interfaces="wlan|ap|rndis|eth|p2p|br"
                    
                    if fn_check_command "ip"; then
                        # 提取 接口名:IP 格式，过滤 127.* 和 169.254.* (APIPA)
                        ip_info=$(ip addr show | grep -E "^[0-9]+: ($valid_interfaces)" -A2 | awk '/^[0-9]+: / {iface=$2; sub(/:$/, "", iface)} /inet / {print iface ":" $2}' | grep -vE ":127\.|:169\.254\." | cut -d/ -f1)
                    elif fn_check_command "ifconfig"; then
                        # 提取 接口名:IP 格式，过滤 127.* 和 169.254.* (APIPA)
                        ip_info=$(ifconfig 2>/dev/null | grep -E "^($valid_interfaces)" -A1 | awk '/^[a-z0-9]/ {iface=$1; sub(/:$/, "", iface)} /inet / {print iface ":" $2}' | grep -vE ":127\.|:169\.254\." | sed 's/addr://')
                    fi

                    if [[ -n "$ip_info" ]]; then
                        fn_print_header "检测到以下局域网地址："
                        for entry in $ip_info; do
                            local iface=$(echo "$entry" | cut -d: -f1)
                            local ip=$(echo "$entry" | cut -d: -f2)
                            local type_label="[未知]"
                            
                            case "$iface" in
                                wlan*) type_label="[WiFi]" ;;
                                ap*)   type_label="[本机热点]" ;;
                                rndis*) type_label="[USB 共享]" ;;
                                eth*)   type_label="[有线网络]" ;;
                            esac

                            # 提取前三段构造 /24 网段
                            local subnet=$(echo "$ip" | cut -d. -f1-3).0/24
                            fn_add_st_whitelist_entry "$subnet"
                            
                            echo -e "  ${GREEN}✓${NC} ${BOLD}${type_label}${NC} 地址: ${CYAN}http://${ip}:${curr_port}${NC}"
                        done
                        echo -e "\n${YELLOW}选择建议：${NC}"
                        echo -e "  - ${BOLD}[WiFi]${NC}: 适用于其他设备通过 ${BOLD}路由器${NC} 或 ${BOLD}他人热点${NC} 与本机处于同一局域网时访问。"
                        echo -e "  - ${BOLD}[本机热点]${NC}: 适用于其他设备直接连接了 ${BOLD}这台手机开启的移动热点${NC} 时访问。"
                        echo -e "  - ${BOLD}[USB 共享]${NC}: 适用于通过 ${BOLD}USB 数据线${NC} 连接并开启网络共享的电脑访问。"
                        echo -e "  - ${YELLOW}提示: ${NC}若有多个地址，请优先尝试 ${GREEN}192.168${NC} 开头的地址。"
                        
                        fn_print_success "\n局域网访问功能已配置完成。"
                        fn_print_warning "设置将在重启酒馆后生效。"
                    else
                        fn_print_error "未能检测到有效的局域网 IP 地址。"
                    fi
                fi
                fn_press_any_key
                ;;
            0) return ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

fn_menu_lab() {
    while true; do
        clear
        fn_print_header "额外功能 (实验室)"
        echo -e "      [1] ${CYAN}gcli2api${NC}"
        echo -e "      [2] ${CYAN}反重力2api${NC}"
        echo -e "      [3] ${CYAN}酒馆配置管理${NC}"
        echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) fn_menu_gcli_manage ;;
            2) fn_menu_antigravity_manage ;;
            3) fn_menu_st_config ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

while true; do
    clear
    fn_show_main_header
    
    update_notice=""
    if [ -f "$UPDATE_FLAG_FILE" ]; then
        update_notice=" ${YELLOW}[!] 有更新${NC}"
    fi

    echo -e "\n    选择一个操作来开始：\n"
    echo -e "      [1] ${GREEN}${BOLD}启动酒馆${NC}"
    echo -e "      [2] ${CYAN}${BOLD}数据同步 (Git 云端)${NC}"
    echo -e "      [3] ${CYAN}${BOLD}本地备份管理${NC}"
    echo -e "      [4] ${YELLOW}${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [5] 酒馆版本管理      [6] 更新咕咕助手${update_notice}"
    echo -e "      [7] 管理助手自启      [8] 查看帮助文档"
    echo -e "      [9] 配置网络代理      [11] ${CYAN}酒馆配置管理${NC}"
    echo -e "      [10] 额外功能 (实验室)\n"
    echo -e "      ${RED}[0] 退出咕咕助手${NC}\n"
    read -p "    请输入选项数字: " choice

    case $choice in
        1) fn_start_st ;;
        2) fn_menu_git_sync ;;
        3) fn_menu_backup ;;
        4) fn_install_st ;;
        5) fn_menu_version_management ;;
        6) fn_update_script ;;
        7) fn_manage_autostart ;;
        8) fn_open_docs ;;
        9) fn_menu_proxy ;;
        10) fn_menu_lab ;;
        11) fn_menu_st_config ;;
        0) echo -e "\n感谢使用，咕咕助手已退出。"; rm -f "$UPDATE_FLAG_FILE"; exit 0 ;;
        *) fn_print_warning "无效输入，请重新选择。"; sleep 1.5 ;;
    esac
done
