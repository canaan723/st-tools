#!/data/data/com.termux/files/usr/bin/bash

# SillyTavern 助手 v2.2.3
# 作者: Qingjue | 小红书号: 826702880

# =========================================================================
#   脚本环境与色彩定义
# =========================================================================
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# =========================================================================
#   核心配置
# =========================================================================
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
)

# =========================================================================
#   辅助函数库
# =========================================================================

fn_print_header() { echo -e "\n${CYAN}═══ ${BOLD}$1 ${NC}═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ ${BOLD}$1${NC}"; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}" >&2; }
fn_print_error() { echo -e "${RED}✗ $1${NC}" >&2; }
fn_print_error_exit() { echo -e "\n${RED}✗ ${BOLD}$1${NC}\n${RED}流程已终止。${NC}" >&2; fn_press_any_key; exit 1; }
fn_press_any_key() { echo -e "\n${CYAN}请按任意键返回...${NC}"; read -n 1 -s; }
fn_check_command() { command -v "$1" >/dev/null 2>&1; }

fn_find_fastest_mirror() {
    if [ ${#CACHED_MIRRORS[@]} -gt 0 ]; then
        fn_print_success "已使用缓存的测速结果。" >&2
        printf '%s\n' "${CACHED_MIRRORS[@]}"
        return 0
    fi

    fn_print_warning "开始测试 Git 镜像连通性与速度 (用于下载)..."
    local github_url="https://github.com/SillyTavern/SillyTavern.git"
    local sorted_successful_mirrors=()
    
    if [[ " ${MIRROR_LIST[*]} " =~ " ${github_url} " ]]; then
        echo -e "  - 优先测试: GitHub 官方源..." >&2
        if timeout 10s git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
            fn_print_success "GitHub 官方源直连可用！将优先使用。" >&2
            sorted_successful_mirrors+=("$github_url")
            CACHED_MIRRORS=("${sorted_successful_mirrors[@]}")
            printf '%s\n' "${CACHED_MIRRORS[@]}"
            return 0
        else
            fn_print_error "GitHub 官方源连接超时，将测试其他镜像..."
        fi
    fi

    local other_mirrors=()
    for mirror in "${MIRROR_LIST[@]}"; do
        [[ "$mirror" != "$github_url" ]] && other_mirrors+=("$mirror")
    done

    if [ ${#other_mirrors[@]} -eq 0 ]; then
        fn_print_error "没有其他可用的镜像进行测试。"
        return 1
    fi

    echo -e "${YELLOW}已启动并行测试，将完整测试所有线路...${NC}" >&2
    local results_file; results_file=$(mktemp); local pids=()
    for mirror_url in "${other_mirrors[@]}"; do
        (
            local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
            local start_time; start_time=$(date +%s.%N)
            if timeout 10s git ls-remote "$mirror_url" HEAD >/dev/null 2>&1; then
                local end_time; end_time=$(date +%s.%N)
                local elapsed_time; elapsed_time=$(echo "$end_time - $start_time" | bc)
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

    if [ ${#sorted_successful_mirrors[@]} -gt 0 ]; then
        fn_print_success "测试完成，找到 ${#sorted_successful_mirrors[@]} 个可用线路。" >&2
        CACHED_MIRRORS=("${sorted_successful_mirrors[@]}")
        printf '%s\n' "${CACHED_MIRRORS[@]}"
    else
        fn_print_error "所有线路均测试失败。"
        return 1
    fi
}

fn_run_npm_install_with_retry() {
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

fn_update_source_with_retry() {
    fn_print_header "1/5: 配置软件源"
    echo -e "${YELLOW}即将开始配置 Termux 软件源...${NC}"
    echo -e "  - 稍后会弹出一个蓝白色窗口，请根据提示操作。"
    echo -e "  - ${GREEN}推荐：${NC}依次选择 ${BOLD}第一项${NC} -> ${BOLD}第三项${NC} (国内最优)。"
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

# =========================================================================
#   Git 同步功能模块
# =========================================================================

git_sync_check_deps() { if ! fn_check_command "git" || ! fn_check_command "rsync"; then fn_print_warning "Git或Rsync尚未安装，请先运行 [首次部署]。"; fn_press_any_key; return 1; fi; return 0; }
git_sync_ensure_identity() {
    if [ -z "$(git config --global --get user.name)" ] || [ -z "$(git config --global --get user.email)" ]; then
        clear; fn_print_header "首次使用Git同步：配置身份"
        local user_name user_email
        while true; do read -p "请输入您的Git用户名 (例如 Your Name): " user_name; [[ -n "$user_name" ]] && break || fn_print_error "用户名不能为空！"; done
        while true; do read -p "请输入您的Git邮箱 (例如 you@example.com): " user_email; [[ -n "$user_email" ]] && break || fn_print_error "邮箱不能为空！"; done
        git config --global user.name "$user_name"; git config --global user.email "$user_email"; fn_print_success "Git身份信息已配置成功！"; sleep 2
    fi; return 0
}
git_sync_configure() {
    clear; fn_print_header "配置 Git 同步服务"; local repo_url repo_token
    while true; do read -p "请输入您的私有仓库HTTPS地址: " repo_url; [[ -n "$repo_url" ]] && break || fn_print_error "仓库地址不能为空！"; done
    while true; do read -p "请输入您的Personal Access Token: " repo_token; [[ -n "$repo_token" ]] && break || fn_print_error "Token不能为空！"; done
    echo "REPO_URL=\"$repo_url\"" > "$GIT_SYNC_CONFIG_FILE"; echo "REPO_TOKEN=\"$repo_token\"" >> "$GIT_SYNC_CONFIG_FILE"; chmod 600 "$GIT_SYNC_CONFIG_FILE"; fn_print_success "Git同步服务配置已保存！"; fn_press_any_key
}
git_sync_test_one_mirror_push() {
    local authed_url="$1"; local test_tag="st-sync-test-$(date +%s%N)"; local temp_repo_dir; temp_repo_dir=$(mktemp -d)
    ( cd "$temp_repo_dir" || return 1; git init -q; git config user.name "test"; git config user.email "test@example.com"; touch testfile.txt; git add testfile.txt; git commit -m "Sync test commit" -q; git remote add origin "$authed_url"; if timeout 15s git push origin "HEAD:refs/tags/$test_tag" >/dev/null 2>&1; then timeout 15s git push origin --delete "refs/tags/$test_tag" >/dev/null 2>&1; return 0; else return 1; fi )
    local exit_code=$?; rm -rf "$temp_repo_dir"; return $exit_code
}
git_sync_find_pushable_mirror() {
    # shellcheck source=/dev/null
    source "$GIT_SYNC_CONFIG_FILE"; if [[ -z "$REPO_URL" || -z "$REPO_TOKEN" ]]; then fn_print_error "Git同步配置不完整或不存在。"; return 1; fi
    fn_print_warning "正在自动测试支持数据上传的加速线路..."; local repo_path; repo_path=$(echo "$REPO_URL" | sed 's|https://github.com/||'); local github_public_url="https://github.com/SillyTavern/SillyTavern.git"; local successful_urls=()
    if [[ " ${MIRROR_LIST[*]} " =~ " ${github_public_url} " ]]; then
        local official_url="https://${REPO_TOKEN}@github.com/${repo_path}"; echo -e "  - 优先测试: 官方 GitHub ..." >&2
        if git_sync_test_one_mirror_push "$official_url"; then echo -e "    ${GREEN}[成功]${NC}" >&2; successful_urls+=("$official_url"); printf '%s\n' "${successful_urls[@]}"; return 0; else echo -e "    ${RED}[失败]${NC}" >&2; fi
    fi
    local other_mirrors=(); for mirror_url in "${MIRROR_LIST[@]}"; do [[ "$mirror_url" != "$github_public_url" ]] && other_mirrors+=("$mirror_url"); done
    if [ ${#other_mirrors[@]} -gt 0 ]; then
        echo -e "${YELLOW}已启动并行测试，将完整测试所有镜像...${NC}" >&2; local results_file; results_file=$(mktemp); local pids=()
        for mirror_url in "${other_mirrors[@]}"; do
            ( local authed_push_url=""; local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||'); if [[ "$mirror_url" == *"hub.gitmirror.com"* ]]; then authed_push_url="https://${REPO_TOKEN}@${mirror_host}/${repo_path}"; elif [[ "$mirror_url" == *"/gh/"* ]]; then authed_push_url="https://${REPO_TOKEN}@${mirror_host}/gh/${repo_path}"; elif [[ "$mirror_url" == *"/github.com/"* ]]; then authed_push_url="https://ghproxy.com/${REPO_URL}"; else exit 1; fi; if git_sync_test_one_mirror_push "$authed_push_url"; then echo "$authed_push_url" >> "$results_file"; echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${GREEN}[成功]${NC}" >&2; else echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${RED}[失败]${NC}" >&2; fi ) &
            pids+=($!)
        done
        wait "${pids[@]}"; if [ -s "$results_file" ]; then mapfile -t other_successful_urls < "$results_file"; successful_urls+=("${other_successful_urls[@]}"); fi; rm -f "$results_file"
    fi
    if [ ${#successful_urls[@]} -gt 0 ]; then fn_print_success "测试完成，找到 ${#successful_urls[@]} 条可用上传线路。" >&2; printf '%s\n' "${successful_urls[@]}"; else fn_print_error "所有上传线路均测试失败。"; return 1; fi
}

git_sync_backup_to_cloud() {
    clear; fn_print_header "Git备份数据到云端 (上传)"; if [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then fn_print_warning "请先在菜单 [1] 中配置Git同步服务。"; fn_press_any_key; return; fi
    mapfile -t push_urls < <(git_sync_find_pushable_mirror); if [ ${#push_urls[@]} -eq 0 ]; then fn_print_error "未能找到任何支持上传的线路。"; fn_press_any_key; return; fi
    
    local SYNC_CONFIG_YAML="false"; local USER_MAP=""
    if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then # shellcheck source=/dev/null
        source "$SYNC_RULES_CONFIG_FILE"; fi

    local backup_success=false
    for push_url in "${push_urls[@]}"; do
        local chosen_host; chosen_host=$(echo "$push_url" | sed -e 's|https://.*@||' -e 's|/.*$||'); fn_print_warning "正在尝试使用线路 [${chosen_host}] 进行备份..."
        local temp_dir; temp_dir=$(mktemp -d)
        local preserved_config_path=""

        (
            cd "$HOME" || exit 1
            if ! git clone --depth 1 "$push_url" "$temp_dir"; then fn_print_error "克隆云端仓库失败！"; exit 1; fi
            fn_print_success "已成功从云端克隆仓库。"

            cd "$temp_dir" || exit 1
            
            if [ "$SYNC_CONFIG_YAML" != "true" ] && [ -f "config.yaml" ]; then
                fn_print_warning "检测到云端存在 config.yaml，已设置为本地忽略模式，将为您保留云端版本。"
                preserved_config_path=$(mktemp)
                mv "config.yaml" "$preserved_config_path"
            fi

            find . -mindepth 1 -not -path './.git*' -delete

            fn_print_warning "正在同步本地数据到临时区..."
            
            if [ "$SYNC_CONFIG_YAML" == "true" ] && [ -f "$ST_DIR/config.yaml" ]; then
                cp "$ST_DIR/config.yaml" .
            fi

            if [ -d "$ST_DIR/data" ]; then
                local exclude_opts=("--exclude=extensions/" "--exclude=_cache/" "--exclude=backups/" "--exclude=*.log")
                
                if [ -n "$USER_MAP" ] && [[ "$USER_MAP" == *":"* ]]; then
                    local local_user="${USER_MAP%%:*}"; local remote_user="${USER_MAP##*:}"
                    fn_print_warning "应用用户映射规则: 本地'${local_user}' -> 云端'${remote_user}'"
                    
                    rsync -a "${exclude_opts[@]}" --exclude="$local_user/" "$ST_DIR/data/" "./data/"
                    
                    if [ -d "$ST_DIR/data/$local_user" ]; then
                        mkdir -p "./data/$remote_user"
                        rsync -a "${exclude_opts[@]}" "$ST_DIR/data/$local_user/" "./data/$remote_user/"
                    fi
                else
                    rsync -a "${exclude_opts[@]}" "$ST_DIR/data/" "./data/"
                fi
            fi

            if [ -n "$preserved_config_path" ] && [ -f "$preserved_config_path" ]; then
                mv "$preserved_config_path" "config.yaml"
            fi
            
            git add .
            if git diff-index --quiet HEAD; then fn_print_success "数据与云端一致，无需上传。"; exit 100; fi
            
            fn_print_warning "正在提交数据变更..."
            local commit_message="来自Termux的同步: $(date +'%Y年%m月%d日 %H:%M:%S')"
            git commit -m "$commit_message" -q || { fn_print_error "Git 提交失败！"; exit 1; }
            
            fn_print_warning "正在上传到云端..."; 
            git push || { fn_print_error "上传失败！"; exit 1; }

            fn_print_success "数据成功备份到云端！"
            exit 0
        )
        
        local subshell_exit_code=$?
        rm -rf "$temp_dir"
        [ -n "$preserved_config_path" ] && rm -f "$preserved_config_path"

        if [ $subshell_exit_code -eq 0 ] || [ $subshell_exit_code -eq 100 ]; then
            backup_success=true
            break
        else
            fn_print_error "使用线路 [${chosen_host}] 备份失败，正在切换..."
            continue
        fi
    done

    if ! $backup_success; then fn_print_error "已尝试所有可用线路，但备份均失败。"; fi
    fn_press_any_key
}

git_sync_restore_from_cloud() {
    clear; fn_print_header "Git从云端恢复数据 (下载)"; if [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then fn_print_warning "请先在菜单 [1] 中配置Git同步服务。"; fn_press_any_key; return; fi
    
    # 【改造】调用新的核心备份函数
    fn_print_warning "此操作将用云端数据【覆盖】本地数据！"
    read -p "是否在恢复前，先对当前数据进行一次本地备份？(强烈推荐) [Y/n]: " backup_confirm
    if [[ ! "$backup_confirm" =~ ^[nN]$ ]]; then 
        if ! fn_core_create_zip_backup "恢复前"; then fn_print_error "本地备份失败，恢复操作已中止。"; fn_press_any_key; return; fi
    fi
    
    read -p "确认要从云端恢复数据吗？[Y/n]: " restore_confirm
    if [[ "$restore_confirm" =~ ^[nN]$ ]]; then fn_print_warning "操作已取消。"; fn_press_any_key; return; fi
    
    local SYNC_CONFIG_YAML="false"; local USER_MAP=""; local EXCLUDE_USERS=""
    if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then # shellcheck source=/dev/null
        source "$SYNC_RULES_CONFIG_FILE"; fi

    mapfile -t pull_urls < <(fn_find_fastest_mirror); if [ ${#pull_urls[@]} -eq 0 ]; then fn_print_error "未能找到任何支持下载的线路。"; fn_press_any_key; return; fi
    
    local temp_dir; temp_dir=$(mktemp -d)

    (
        cd "$HOME" || exit 1
        # shellcheck source=/dev/null
        source "$GIT_SYNC_CONFIG_FILE"
        local repo_path; repo_path=$(echo "$REPO_URL" | sed 's|https://github.com/||')
        
        local clone_success=false
        for pull_url in "${pull_urls[@]}"; do
            local chosen_host; chosen_host=$(echo "$pull_url" | sed -e 's|https://||' -e 's|/.*$||')
            fn_print_warning "正在尝试使用线路 [${chosen_host}] 进行恢复..."
            local private_repo_url; private_repo_url=$(echo "$pull_url" | sed "s|/SillyTavern/SillyTavern.git|/${repo_path}|")
            local pull_url_with_auth; pull_url_with_auth=$(echo "$private_repo_url" | sed "s|https://|https://${REPO_TOKEN}@|")
            
            if git clone --depth 1 "$pull_url_with_auth" "$temp_dir"; then
                clone_success=true
                break
            fi
            fn_print_error "下载云端数据失败！正在切换下一条线路..."
            rm -rf "$temp_dir"/* "$temp_dir"/.* 2>/dev/null
        done

        if ! $clone_success; then fn_print_error "已尝试所有线路，但恢复均失败。"; exit 1; fi
        if [ -z "$(ls -A "$temp_dir")" ]; then fn_print_error "下载的数据源无效或为空，恢复操作已中止！"; exit 1; fi
        fn_print_success "已成功从云端下载数据。"

        fn_print_warning "正在将云端数据同步到本地..."
        
        if [ "$SYNC_CONFIG_YAML" == "true" ] && [ -f "$temp_dir/config.yaml" ]; then
            fn_print_warning "\n--- 正在同步: config.yaml ---"
            cp "$temp_dir/config.yaml" "$ST_DIR/config.yaml"
        fi

        if [ -d "$temp_dir/data" ]; then
            fn_print_warning "\n--- 正在同步: data (将保留本地 extensions 文件夹) ---"
            
            local base_exclude_opts=("--exclude=extensions/")

            if [ -n "$USER_MAP" ] && [[ "$USER_MAP" == *":"* ]]; then
                local local_user="${USER_MAP%%:*}"; local remote_user="${USER_MAP##*:}"
                fn_print_warning "应用用户映射规则: 云端'${remote_user}' -> 本地'${local_user}'"
                
                local exclude_args=("${base_exclude_opts[@]}")
                exclude_args+=("--exclude=${remote_user}/")
                if [ -n "$EXCLUDE_USERS" ]; then
                    fn_print_warning "应用排除规则: ${EXCLUDE_USERS}"
                    for user in $EXCLUDE_USERS; do exclude_args+=("--exclude=${user}/"); done
                fi
                
                fn_print_warning "  - 同步基础 data (应用排除规则)..."
                rsync -av --delete "${exclude_args[@]}" "$temp_dir/data/" "$ST_DIR/data/"

                if [ -d "$temp_dir/data/$remote_user" ]; then
                    fn_print_warning "\n  - 同步映射文件夹 ${remote_user} -> ${local_user}..."
                    mkdir -p "$ST_DIR/data/$local_user"
                    rsync -av --delete "${base_exclude_opts[@]}" "$temp_dir/data/$remote_user/" "$ST_DIR/data/$local_user/"
                else
                    fn_print_warning "云端映射文件夹 'data/${remote_user}' 不存在，跳过映射同步。"
                fi
            else
                fn_print_warning "未配置用户映射，将完整恢复 data 目录 (保留本地 extensions)。"
                rsync -av --delete "${base_exclude_opts[@]}" "$temp_dir/data/" "$ST_DIR/data/"
            fi
        fi
        
        fn_print_success "\n数据已从云端成功恢复！"
        exit 0
    )
    
    local subshell_exit_code=$?
    rm -rf "$temp_dir"
    
    if [ $subshell_exit_code -ne 0 ]; then
        : 
    fi
    fn_press_any_key
}

git_sync_clear_config() { if [ -f "$GIT_SYNC_CONFIG_FILE" ]; then read -p "确认要清除已保存的Git同步配置吗？(y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then rm -f "$GIT_SYNC_CONFIG_FILE"; fn_print_success "Git同步配置已清除。"; else fn_print_warning "操作已取消。"; fi; else fn_print_warning "未找到任何Git同步配置。"; fi; fn_press_any_key; }

fn_export_extension_links() {
    clear; fn_print_header "导出扩展链接"
    local all_links=()
    local output_content=""

    get_repo_url() {
        local path="$1"
        if [ -d "$path/.git" ]; then
            (
                cd "$path" || return
                git config --get remote.origin.url
            )
        fi
    }

    local global_ext_path="$ST_DIR/public/scripts/extensions/third-party"
    if [ -d "$global_ext_path" ]; then
        local global_links_found=false
        local temp_output="═══ 全局扩展 ═══\n"
        for dir in "$global_ext_path"/*/; do
            if [ -d "$dir" ]; then
                local url; url=$(get_repo_url "$dir")
                if [ -n "$url" ]; then
                    temp_output+="$url\n"
                    all_links+=("$url")
                    global_links_found=true
                fi
            fi
        done
        if $global_links_found; then output_content+="$temp_output"; fi
    fi

    local data_path="$ST_DIR/data"
    if [ -d "$data_path" ]; then
        for user_dir in "$data_path"/*/; do
            if [ -d "$user_dir" ]; then
                local user_ext_path="${user_dir}extensions"
                if [ -d "$user_ext_path" ]; then
                    local user_links_found=false
                    local user_name; user_name=$(basename "$user_dir")
                    local temp_output="\n═══ 用户 [${user_name}] 的扩展 ═══\n"
                    for ext_dir in "$user_ext_path"/*/; do
                        if [ -d "$ext_dir" ]; then
                            local url; url=$(get_repo_url "$ext_dir")
                            if [ -n "$url" ]; then
                                temp_output+="$url\n"
                                all_links+=("$url")
                                user_links_found=true
                            fi
                        fi
                    done
                    if $user_links_found; then output_content+="$temp_output"; fi
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
            if [ $? -eq 0 ]; then fn_print_success "链接已成功保存到: $file_path"; else fn_print_error "保存失败！"; fi
        fi
    fi
    fn_press_any_key
}

menu_git_config_management() {
    while true; do
        clear; fn_print_header "管理 Git 同步配置"
        echo -e "      [1] ${CYAN}修改/设置同步信息${NC}"
        echo -e "      [2] ${RED}清除所有同步配置${NC}"
        echo -e "      [0] ${CYAN}返回上一级${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) git_sync_configure; break ;;
            2) git_sync_clear_config ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

menu_advanced_sync_settings() {
    fn_update_config_value() {
        local key="$1"; local value="$2"; local file="$3"; touch "$file"
        if grep -q "^${key}=" "$file"; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
        else
            echo "${key}=\"${value}\"" >> "$file"
        fi
    }

    while true; do
        clear; fn_print_header "高级同步设置"
        local SYNC_CONFIG_YAML="false"; local USER_MAP=""; local EXCLUDE_USERS=""
        if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then # shellcheck source=/dev/null
            source "$SYNC_RULES_CONFIG_FILE"; fi

        local sync_config_status="${RED}关闭${NC}"; [[ "$SYNC_CONFIG_YAML" == "true" ]] && sync_config_status="${GREEN}开启${NC}"
        echo -e "  [1] 同步 config.yaml         : ${sync_config_status}"

        local user_map_status="${RED}未设置${NC}"
        if [ -n "$USER_MAP" ]; then
            local local_user="${USER_MAP%%:*}"; local remote_user="${USER_MAP##*:}"
            user_map_status="${GREEN}本地 ${local_user} -> 云端 ${remote_user}${NC}"
        fi
        echo -e "  [2] 设置用户数据映射        : ${user_map_status}"

        local exclude_users_status="${RED}未设置${NC}"; [ -n "$EXCLUDE_USERS" ] && exclude_users_status="${YELLOW}${EXCLUDE_USERS}${NC}"
        echo -e "  [3] 下载时排除的云端用户    : ${exclude_users_status}"
        
        echo -e "\n  [4] ${RED}重置所有高级设置${NC}"
        echo -e "  [0] ${CYAN}返回上一级${NC}\n"
        read -p "    请输入选项: " choice

        case $choice in
            1)
                local new_status="false"; [[ "$SYNC_CONFIG_YAML" != "true" ]] && new_status="true"
                fn_update_config_value "SYNC_CONFIG_YAML" "$new_status" "$SYNC_RULES_CONFIG_FILE"
                fn_print_success "config.yaml 同步已变更为: ${new_status}"; sleep 1
                ;;
            2)
                read -p "请输入本地用户文件夹名 [直接回车默认为 default-user]: " local_u; local_u=${local_u:-default-user}
                read -p "请输入要映射到的云端用户文件夹名 [直接回车默认为 default-user]: " remote_u; remote_u=${remote_u:-default-user}
                fn_update_config_value "USER_MAP" "${local_u}:${remote_u}" "$SYNC_RULES_CONFIG_FILE"
                fn_print_success "用户映射已设置为: ${local_u} -> ${remote_u}"; sleep 1.5
                ;;
            3)
                read -p "请输入下载时要排除的云端用户名 (用空格隔开，例如 b c): " excluded
                fn_update_config_value "EXCLUDE_USERS" "$excluded" "$SYNC_RULES_CONFIG_FILE"
                if [ -n "$excluded" ]; then fn_print_success "已设置排除用户列表。"; else fn_print_warning "输入为空，已清除排除列表。"; fi
                sleep 1.5
                ;;
            4)
                if [ -f "$SYNC_RULES_CONFIG_FILE" ]; then rm -f "$SYNC_RULES_CONFIG_FILE"; fn_print_success "所有高级同步设置已重置。"; else fn_print_warning "没有需要重置的设置。"; fi
                sleep 1.5
                ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

menu_git_sync() {
    if [ ! -f "$ST_DIR/start.sh" ]; then fn_print_warning "SillyTavern 尚未安装，无法使用数据同步功能。\n请先返回主菜单选择 [首次部署]。"; fn_press_any_key; return; fi
    if ! git_sync_check_deps; then return; fi
    if ! git_sync_ensure_identity; then return; fi

    while true; do 
        clear; fn_print_header "数据同步 (Git 方案)"
        if [ -f "$GIT_SYNC_CONFIG_FILE" ]; then # shellcheck source=/dev/null
            source "$GIT_SYNC_CONFIG_FILE"
            if [ -n "$REPO_URL" ]; then
                local current_repo_name; current_repo_name=$(basename "$REPO_URL" .git)
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
            1) menu_git_config_management ;; 
            2) git_sync_backup_to_cloud ;; 
            3) git_sync_restore_from_cloud ;; 
            4) menu_advanced_sync_settings ;;
            5) fn_export_extension_links ;;
            0) break ;; 
            *) fn_print_error "无效输入。"; sleep 1 ;; 
        esac
    done
}

# =========================================================================
#   网络代理功能模块
# =========================================================================
fn_apply_proxy() {
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        local port; port=$(cat "$PROXY_CONFIG_FILE")
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
    read -p "请输入代理端口号 [直接回车默认为 7890]: " port; port=${port:-7890}
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -lt 65536 ]; then
        echo "$port" > "$PROXY_CONFIG_FILE"; fn_apply_proxy; fn_print_success "代理已设置为: 127.0.0.1:$port"
    else
        fn_print_error "无效的端口号！请输入1-65535之间的数字。"
    fi
    fn_press_any_key
}

fn_clear_proxy() {
    if [ -f "$PROXY_CONFIG_FILE" ]; then rm -f "$PROXY_CONFIG_FILE"; fn_apply_proxy; fn_print_success "网络代理配置已清除。"; else fn_print_warning "当前未配置任何代理。"; fi
    fn_press_any_key
}

main_manage_proxy() {
    while true; do
        clear; fn_print_header "管理网络代理"
        local proxy_status="${RED}未配置${NC}"
        if [ -f "$PROXY_CONFIG_FILE" ]; then proxy_status="${GREEN}127.0.0.1:$(cat "$PROXY_CONFIG_FILE")${NC}"; fi
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

# =========================================================================
#   核心功能模块
# =========================================================================

main_start() {
    clear; fn_print_header "启动 SillyTavern"
    if [ ! -f "$ST_DIR/start.sh" ]; then fn_print_warning "SillyTavern 尚未安装，请先部署。"; fn_press_any_key; return; fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"
    echo -e "正在配置NPM镜像并准备启动环境..."; npm config set registry https://registry.npmmirror.com
    echo -e "${YELLOW}环境准备就绪，正在启动SillyTavern服务...${NC}"; echo -e "${YELLOW}首次启动或更新后会自动安装依赖，耗时可能较长...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"; fn_press_any_key
}

# 【新增】核心本地备份创建函数
fn_core_create_zip_backup() {
    local backup_type="$1" # "手动", "恢复前", "更新前"
    
    if [ ! -d "$ST_DIR" ]; then fn_print_error "SillyTavern 目录不存在，无法创建本地备份。"; return 1; fi
    cd "$ST_DIR" || { fn_print_error "无法进入 SillyTavern 目录进行备份。"; return 1; }
    
    # 确定备份范围
    local default_paths=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    local paths_to_backup=()
    if [ -f "$CONFIG_FILE" ]; then
        mapfile -t paths_to_backup < "$CONFIG_FILE"
    fi
    # 如果配置文件为空或不存在，使用默认值
    if [ ${#paths_to_backup[@]} -eq 0 ]; then
        paths_to_backup=("${default_paths[@]}")
    fi

    # 检查备份上限
    mkdir -p "$BACKUP_ROOT_DIR"
    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -n | cut -d' ' -f2-)
    local current_backup_count=${#all_backups[@]}
    
    echo -e "${YELLOW}当前本地备份数: ${current_backup_count}/${BACKUP_LIMIT}${NC}"

    if [ "$current_backup_count" -ge "$BACKUP_LIMIT" ]; then
        local oldest_backup="${all_backups[0]}"
        fn_print_warning "警告：本地备份已达上限 (${BACKUP_LIMIT}/${BACKUP_LIMIT})。"
        echo -e "创建新备份将会自动删除最旧的一个备份文件:"
        echo -e "  - ${RED}将被删除: $(basename "$oldest_backup")${NC}"
        read -p "是否继续创建本地备份？[Y/n]: " confirm_overwrite
        if [[ "$confirm_overwrite" =~ ^[nN]$ ]]; then
            fn_print_warning "操作已取消。"
            return 1
        fi
    fi

    local timestamp; timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_备份_${backup_type}_${timestamp}.zip"
    local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}"
    
    fn_print_warning "正在创建“${backup_type}”类型的本地备份..."

    local valid_paths=()
    for item in "${paths_to_backup[@]}"; do
        [ -e "$item" ] && valid_paths+=("$item")
    done
    if [ ${#valid_paths[@]} -eq 0 ]; then fn_print_error "未能收集到任何有效文件进行本地备份。"; return 1; fi

    local exclude_params=(-x "*/_cache/*" -x "*.log" -x "*/backups/*")
    if zip -rq "$backup_zip_path" "${valid_paths[@]}" "${exclude_params[@]}"; then
        # 成功后清理旧备份
        if [ "$current_backup_count" -ge "$BACKUP_LIMIT" ]; then
            fn_print_warning "正在清理旧备份..."
            rm "$oldest_backup"
            echo "  - 已删除: $(basename "$oldest_backup")"
        fi
        mapfile -t new_all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip")
        fn_print_success "本地备份成功：${backup_name} (当前: ${#new_all_backups[@]}/${BACKUP_LIMIT})"
        echo -e "  ${CYAN}保存路径: ${backup_zip_path}${NC}"
        cd "$HOME"
        return 0
    else
        fn_print_error "创建本地 .zip 备份失败！"
        cd "$HOME"
        return 1
    fi
}

main_install() {
    local auto_start=true; if [[ "$1" == "no-start" ]]; then auto_start=false; fi
    clear; fn_print_header "SillyTavern 部署向导"
    if [[ "$auto_start" == "true" ]]; then
        while true; do if ! fn_update_source_with_retry; then read -p $'\n'"${RED}软件源配置失败。是否重试？(直接回车=是, 输入n=否): ${NC}" retry_choice; if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then fn_print_error_exit "用户取消操作。"; fi; else break; fi; done
        fn_print_header "2/5: 安装核心依赖"; echo -e "${YELLOW}正在安装核心依赖...${NC}"
        yes | pkg upgrade -y; yes | pkg install git nodejs-lts rsync zip unzip termux-api coreutils gawk bc || fn_print_error_exit "核心依赖安装失败！"
        fn_print_success "核心依赖安装完毕。"
    fi
    fn_print_header "3/5: 下载 ST 主程序"
    if [ -f "$ST_DIR/start.sh" ]; then fn_print_warning "检测到完整的 SillyTavern 安装，跳过下载。"; elif [ -d "$ST_DIR" ] && [ -n "$(ls -A "$ST_DIR")" ]; then fn_print_error_exit "目录 $ST_DIR 已存在但安装不完整。请手动删除该目录后再试。"; else
        local download_success=false
        while ! $download_success; do
            mapfile -t sorted_mirrors < <(fn_find_fastest_mirror)
            if [ ${#sorted_mirrors[@]} -eq 0 ]; then read -p $'\n'"${RED}所有 Git 镜像均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice; if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then fn_print_error_exit "下载失败，用户取消操作。"; fi; CACHED_MIRRORS=(); continue; fi
            for mirror_url in "${sorted_mirrors[@]}"; do
                local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
                fn_print_warning "正在尝试从镜像 [${mirror_host}] 下载 (${REPO_BRANCH} 分支)..."
                if git clone --depth 1 -b "$REPO_BRANCH" "$mirror_url" "$ST_DIR"; then fn_print_success "主程序下载完成。"; download_success=true; break; else fn_print_error "使用镜像 [${mirror_host}] 下载失败！正在切换..."; rm -rf "$ST_DIR"; fi
            done
            if ! $download_success; then read -p $'\n'"${RED}所有线路均下载失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice; if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then fn_print_error_exit "下载失败，用户取消操作。"; fi; CACHED_MIRRORS=(); fi
        done
    fi
    fn_print_header "4/5: 配置并安装依赖"
    if [ -d "$ST_DIR" ]; then if ! fn_run_npm_install_with_retry; then fn_print_error_exit "依赖安装最终失败，部署中断。"; fi; else fn_print_warning "SillyTavern 目录不存在，跳过此步。"; fi
    if $auto_start; then
        fn_print_header "5/5: 设置快捷方式与自启"; fn_create_shortcut; main_manage_autostart "set_default"; echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"; sleep 3; main_start
    else
        fn_print_success "全新版本下载与配置完成。"
    fi
}

main_update_st() {
    clear; fn_print_header "更新 SillyTavern 主程序"; if [ ! -d "$ST_DIR/.git" ]; then fn_print_warning "未找到Git仓库，请先完整部署。"; fn_press_any_key; return; fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录: $ST_DIR"
    local update_success=false
    while ! $update_success; do
        mapfile -t sorted_mirrors < <(fn_find_fastest_mirror)
        if [ ${#sorted_mirrors[@]} -eq 0 ]; then read -p $'\n'"${RED}所有 Git 镜像均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice; if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then fn_print_warning "更新失败，用户取消操作。"; fn_press_any_key; return; fi; CACHED_MIRRORS=(); continue; fi
        local pull_attempted_in_loop=false
        for mirror_url in "${sorted_mirrors[@]}"; do
            local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||'); fn_print_warning "正在尝试使用镜像 [${mirror_host}] 更新..."; git remote set-url origin "$mirror_url"
            local git_output; git_output=$(git pull origin "$REPO_BRANCH" 2>&1)
            if [ $? -eq 0 ]; then fn_print_success "代码更新成功。"; if fn_run_npm_install_with_retry; then update_success=true; fi; break; else
                if echo "$git_output" | grep -qE "overwritten by merge|Please commit|unmerged files"; then
                    clear; fn_print_header "检测到更新冲突！"; fn_print_warning "原因: 你可能修改过酒馆的文件，导致无法自动合并新版本。"; echo "--- 冲突文件预览 ---"; echo "$git_output" | grep -E "^\s+" | head -n 5; echo "--------------------"
                    echo -e "\n请选择操作方式："; echo -e "  [${GREEN}回车${NC}] ${BOLD}自动备份并重新安装 (推荐)${NC}"; echo -e "  [1]    ${YELLOW}强制覆盖更新 (危险)${NC}"; echo -e "  [0]    ${CYAN}放弃更新${NC}"; read -p "请输入选项: " choice
                    case "$choice" in
                    "" | 'b' | 'B')
                        clear; fn_print_header "步骤 1/5: 创建本地备份"
                        # 【改造】调用新的核心备份函数
                        if ! fn_core_create_zip_backup "更新前"; then fn_print_error_exit "本地备份创建失败，更新流程终止。"; fi
                        
                        fn_print_header "步骤 2/5: 完整备份当前目录"; local renamed_backup_dir="${ST_DIR}_backup_$(date +%Y%m%d%H%M%S)"; cd "$HOME"; mv "$ST_DIR" "$renamed_backup_dir" || fn_print_error_exit "备份失败！请检查权限或手动重命名后重试。"; fn_print_success "旧目录已完整备份为: $(basename "$renamed_backup_dir")"
                        fn_print_header "步骤 3/5: 下载并安装新版 SillyTavern"; main_install "no-start"; if [ ! -d "$ST_DIR" ]; then fn_print_error_exit "新版本安装失败，流程终止。"; fi
                        fn_print_header "步骤 4/5: 自动恢复用户数据"; fn_print_warning "正在将备份数据解压至新目录..."; if ! unzip -o "$BACKUP_ROOT_DIR"/ST_备份_更新前_*.zip -d "$ST_DIR" >/dev/null 2>&1; then fn_print_error_exit "数据恢复失败！请检查zip文件是否有效。"; fi; fn_print_success "用户数据已成功恢复到新版本中。"
                        fn_print_header "步骤 5/5: 更新完成，请确认"; fn_print_success "SillyTavern 已更新并恢复数据！"; fn_print_warning "请注意:"; echo -e "  - 您的聊天记录、角色卡、插件和设置已恢复。"; echo -e "  - 如果您曾手动修改过酒馆核心文件(如 server.js)，这些修改需要您重新操作。"; echo -e "  - 您的完整旧版本已备份在: ${CYAN}$(basename "$renamed_backup_dir")${NC}"; echo -e "  - 本次恢复所用的核心本地备份位于: ${CYAN}$(basename "$BACKUP_ROOT_DIR")/ST_备份_更新前_...zip${NC}"
                        echo -e "\n${CYAN}请按任意键，启动更新后的 SillyTavern...${NC}"; read -n 1 -s; main_start; return
                        ;;
                    '1')
                        fn_print_warning "正在执行强制覆盖 (git reset --hard)..."; if git reset --hard "origin/$REPO_BRANCH" && git pull origin "$REPO_BRANCH"; then fn_print_success "强制更新成功。"; if fn_run_npm_install_with_retry; then update_success=true; fi; else fn_print_error "强制更新失败！"; fi; pull_attempted_in_loop=true; break
                        ;;
                    *) fn_print_warning "已取消更新。"; fn_press_any_key; return ;;
                    esac
                else fn_print_error "使用镜像 [${mirror_host}] 更新失败！错误: $(echo "$git_output" | tail -n 1)"; fn_print_error "正在切换下一条线路..."; sleep 1; fi
            fi
        done
        if $pull_attempted_in_loop; then break; fi
        if ! $update_success; then read -p $'\n'"${RED}所有线路均更新失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice; if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then fn_print_warning "更新失败，用户取消操作。"; break; fi; CACHED_MIRRORS=(); fi
    done
    if $update_success; then fn_print_success "SillyTavern 更新完成！"; fi; fn_press_any_key
}

# 【改造】创建本地备份的交互界面
run_backup_interactive() {
    clear; fn_print_header "创建新的本地备份"
    if [ ! -f "$ST_DIR/start.sh" ]; then fn_print_warning "SillyTavern 尚未安装，无法备份。"; fn_press_any_key; return; fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录: $ST_DIR"

    declare -A ALL_PATHS=(
        ["./data"]="用户数据 (聊天/角色/设置)"
        ["./public/scripts/extensions/third-party"]="前端扩展"
        ["./plugins"]="后端扩展"
        ["./config.yaml"]="服务器配置 (网络/安全)"
    )
    local options=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    # 【改造】默认全选
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
        echo -e "\n      ${GREEN}[回车] 保存设置并开始备份${NC}"
        echo -e "      ${RED}[0] 返回上一级${NC}"
        read -p "请操作 [输入数字, 回车 或 0]: " user_choice
        case "$user_choice" in
        "" | [sS])
            break
            ;;
        0)
            echo "操作已取消。"
            return
            ;;
        *)
            if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "${#options[@]}" ]; then
                local selected_key="${options[$((user_choice - 1))]}"
                if ${selection_status[$selected_key]}; then
                    selection_status[$selected_key]=false
                else
                    selection_status[$selected_key]=true
                fi
            else
                fn_print_warning "无效输入。"; sleep 1
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
    
    # 保存用户的选择到配置文件
    printf "%s\n" "${paths_to_save[@]}" > "$CONFIG_FILE"
    fn_print_success "备份范围已保存！"
    sleep 1

    # 【改造】调用核心函数
    if fn_core_create_zip_backup "手动"; then
        : # Success message is already inside the core function
    else
        fn_print_error "手动本地备份创建失败。"
    fi
    fn_press_any_key
}

# 【新增】本地备份管理界面
main_manage_backups() {
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
                local filename; filename=$(basename "$file_path")
                
                # 解析文件名
                local type; type=$(echo "$filename" | awk -F'[_.]' '{print $3}')
                local date; date=$(echo "$filename" | awk -F'[_.]' '{print $4}')
                local time; time=$(echo "$filename" | awk -F'[_.]' '{print $5}')
                
                # 获取文件大小
                local size; size=$(du -h "$file_path" | awk '{print $1}')
                
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
                    continue 2 # Continue the outer while loop
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

# 【新增】本地备份主菜单
main_backup_menu() {
    while true; do
        clear
        fn_print_header "本地备份管理"
        echo -e "      [1] ${CYAN}创建新的本地备份${NC}"
        echo -e "      [2] ${CYAN}管理已有的本地备份${NC}\n"
        echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
        read -p "    请输入选项: " choice
        case $choice in
            1) run_backup_interactive ;;
            2) main_manage_backups ;;
            0) break ;;
            *) fn_print_error "无效输入。"; sleep 1 ;;
        esac
    done
}

main_update_script() {
    clear; fn_print_header "更新助手脚本"; fn_print_warning "正在从 Gitee 下载新版本..."; local temp_file; temp_file=$(mktemp)
    if ! curl -L -o "$temp_file" "$SCRIPT_URL"; then rm -f "$temp_file"; fn_print_warning "下载失败。"; elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then rm -f "$temp_file"; fn_print_success "当前已是最新版本。"; else
        sed -i 's/\r$//' "$temp_file"; chmod +x "$temp_file"; mv "$temp_file" "$SCRIPT_SELF_PATH"; rm -f "$UPDATE_FLAG_FILE"; echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"; sleep 2; exec "$SCRIPT_SELF_PATH" --updated
    fi; fn_press_any_key
}

check_for_updates_on_start() { ( local temp_file; temp_file=$(mktemp); if curl -L -s --connect-timeout 10 -o "$temp_file" "$SCRIPT_URL"; then if ! cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then touch "$UPDATE_FLAG_FILE"; else rm -f "$UPDATE_FLAG_FILE"; fi; fi; rm -f "$temp_file"; ) & }
fn_create_shortcut() { local BASHRC_FILE="$HOME/.bashrc"; local ALIAS_CMD="alias st='\"$SCRIPT_SELF_PATH\"'"; local ALIAS_COMMENT="# SillyTavern 助手快捷命令"; if ! grep -qF "$ALIAS_CMD" "$BASHRC_FILE"; then chmod +x "$SCRIPT_SELF_PATH"; echo -e "\n$ALIAS_COMMENT\n$ALIAS_CMD" >>"$BASHRC_FILE"; fn_print_success "已创建快捷命令 'st'。请重启 Termux 或执行 'source ~/.bashrc' 生效。"; fi; }
main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"; local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""; local is_set=false; grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true
    if [[ "$1" == "set_default" ]]; then if ! $is_set; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"; fn_print_success "已设置 Termux 启动时自动运行本助手。"; fi; return; fi
    clear; fn_print_header "管理助手自启"; if $is_set; then echo -e "当前状态: ${GREEN}已启用${NC}"; echo -e "${CYAN}提示: 关闭自启后，输入 'st' 命令即可手动启动助手。${NC}"; read -p "是否取消自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then sed -i "/# SillyTavern 助手/d" "$BASHRC_FILE"; sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"; fn_print_success "已取消自启。"; fi; else echo -e "当前状态: ${RED}未启用${NC}"; echo -e "${CYAN}提示: 在 Termux 中输入 'st' 命令可以手动启动助手。${NC}"; read -p "是否设置自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"; fn_print_success "已成功设置自启。"; fi; fi; fn_press_any_key
}
main_open_docs() { clear; fn_print_header "查看帮助文档"; local docs_url="https://blog.qjyg.de"; echo -e "文档网址: ${CYAN}${docs_url}${NC}\n"; if fn_check_command "termux-open-url"; then termux-open-url "$docs_url"; fn_print_success "已尝试在浏览器中打开，若未自动跳转请手动复制上方网址。"; else fn_print_warning "命令 'termux-open-url' 不存在。\n请先安装【Termux:API】应用及 'pkg install termux-api'。"; fi; fn_press_any_key; }
fn_migrate_configs() { local migration_needed=false; local OLD_CONFIG_FILE="$HOME/.st_assistant.conf"; local OLD_GIT_SYNC_CONFIG_FILE="$HOME/.st_sync.conf"; mkdir -p "$CONFIG_DIR"; if [ -f "$OLD_CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then mv "$OLD_CONFIG_FILE" "$CONFIG_FILE"; fn_print_warning "已将旧的备份配置文件迁移至新位置。"; migration_needed=true; fi; if [ -f "$OLD_GIT_SYNC_CONFIG_FILE" ] && [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then mv "$OLD_GIT_SYNC_CONFIG_FILE" "$GIT_SYNC_CONFIG_FILE"; fn_print_warning "已将旧的Git同步配置文件迁移至新位置。"; migration_needed=true; fi; if $migration_needed; then fn_print_success "配置文件迁移完成！"; sleep 2; fi; }

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

fn_migrate_configs; fn_apply_proxy
if [[ "$1" != "--no-check" && "$1" != "--updated" ]]; then check_for_updates_on_start; fi
if [[ "$1" == "--updated" ]]; then clear; fn_print_success "助手已成功更新至最新版本！"; sleep 2; fi

while true; do
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
    ╔═════════════════════════════════╗
    ║       SillyTavern 助手 v2.2.3     ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    update_notice=""; if [ -f "$UPDATE_FLAG_FILE" ]; then update_notice=" ${YELLOW}[!] 有更新${NC}"; fi

    # 【改造】主菜单
    echo -e "${NC}\n    选择一个操作来开始：\n"
    echo -e "      [1] ${GREEN}${BOLD}启动 SillyTavern${NC}"
    echo -e "      [2] ${CYAN}${BOLD}数据同步 (Git 云端)${NC}"
    echo -e "      [3] ${CYAN}${BOLD}本地备份管理${NC}"
    echo -e "      [4] ${YELLOW}${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [5] 更新 ST 主程序    [6] 更新助手脚本${update_notice}"
    echo -e "      [7] 管理助手自启      [8] 查看帮助文档"
    echo -e "      [9] 配置网络代理\n"
    echo -e "      ${RED}[0] 退出助手${NC}\n"
    read -p "    请输入选项数字: " choice

    case $choice in
    1) main_start ;;
    2) menu_git_sync ;;
    3) main_backup_menu ;; # 【改造】调用新的子菜单
    4) main_install ;;
    5) main_update_st ;;
    6) main_update_script ;;
    7) main_manage_autostart ;;
    8) main_open_docs ;;
    9) main_manage_proxy ;;
    0) echo -e "\n感谢使用，助手已退出。"; rm -f "$UPDATE_FLAG_FILE"; exit 0 ;;
    *) fn_print_warning "无效输入，请重新选择。"; sleep 1.5 ;;
    esac
done
