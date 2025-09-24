#!/data/data/com.termux/files/usr/bin/bash

# SillyTavern 助手 v2.2.1 (社区修正版)
# 作者: Qingjue | 小红书号: 826702880
# 终极备份重构与修复 (感谢用户持续的专业反馈):
# 1. 【新增】在S3/WebDAV菜单中增加了独立的“打包备份到云端”功能，为用户提供最稳定的备份选择。
# 2. 【修复】修正了S3配置流程，增加了“提供商(Provider)”输入项，从根源解决502服务端错误。
# 3. 【修复】严格检查rclone命令的退出码，彻底修复了备份失败后“谎报成功”的严重BUG。
# 4. 【修复】全面检查并修正了所有菜单中残留的“\n”显示问题。
# 5. 固化了v2.2.0版本中的所有功能和修复。

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
GIT_SYNC_CONFIG_FILE="$HOME/.st_sync.conf"
RCLONE_CONFIG_DIR="$HOME/.config/rclone"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
S3_SYNC_CONFIG_FILE="$HOME/.st_s3.conf"
WEBDAV_SYNC_CONFIG_FILE="$HOME/.st_webdav.conf"
UPDATE_FLAG_FILE="/data/data/com.termux/files/usr/tmp/.st_assistant_update_flag"
CACHED_MIRRORS=()

# 用于下载(pull/clone)的镜像列表
PULL_MIRROR_LIST=(
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
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
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

    fn_print_warning "开始测试 Git 镜像连通性与速度 (用于下载)..." >&2
    local github_url="https://github.com/SillyTavern/SillyTavern.git"
    local sorted_successful_mirrors=()
    
    if [[ " ${PULL_MIRROR_LIST[*]} " =~ " ${github_url} " ]]; then
        echo -e "  - 优先测试: GitHub 官方源..." >&2
        if timeout 10s git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
            fn_print_success "GitHub 官方源直连可用！将优先使用。" >&2
            sorted_successful_mirrors+=("$github_url")
            CACHED_MIRRORS=("${sorted_successful_mirrors[@]}")
            printf '%s\n' "${CACHED_MIRRORS[@]}"
            return 0
        else
            fn_print_error "GitHub 官方源连接超时，将测试其他镜像..." >&2
        fi
    fi

    local other_mirrors=()
    for mirror in "${PULL_MIRROR_LIST[@]}"; do
        [[ "$mirror" != "$github_url" ]] && other_mirrors+=("$mirror")
    done

    if [ ${#other_mirrors[@]} -eq 0 ]; then
        fn_print_error "没有其他可用的镜像进行测试。" >&2
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
        fn_print_error "所有线路均测试失败。" >&2
        return 1
    fi
}

fn_run_npm_install_with_retry() {
    if [ ! -d "$ST_DIR" ]; then return 1; fi; cd "$ST_DIR" || return 1
    fn_print_warning "正在同步依赖包 (npm install)..."
    if npm install --no-audit --no-fund --omit=dev; then fn_print_success "依赖包同步完成。"; return 0; fi
    fn_print_warning "依赖包同步失败，将自动清理缓存并重试..."; npm cache clean --force >/dev/null 2>&1
    if npm install --no-audit --no-fund --omit=dev; then fn_print_success "依赖包重试同步成功。"; return 0; fi
    fn_print_warning "国内镜像安装失败，将切换到NPM官方源进行最后尝试..."; npm config delete registry
    local exit_code; npm install --no-audit --no-fund --omit=dev; exit_code=$?
    fn_print_warning "正在将 NPM 源恢复为国内镜像..."; npm config set registry https://registry.npmmirror.com
    if [ $exit_code -eq 0 ]; then fn_print_success "使用官方源安装依赖成功！"; return 0; else fn_print_error "所有安装尝试均失败。"; return 1; fi
}

fn_update_source_with_retry() {
    fn_print_header "1/5: 配置软件源"; echo -e "${YELLOW}即将开始配置 Termux 软件源...${NC}"; echo -e "  - 稍后会弹出一个蓝白色窗口，请根据提示操作。"; echo -e "  - ${GREEN}推荐：${NC}依次选择 ${BOLD}第一项${NC} -> ${BOLD}第三项${NC} (国内最优)。"; echo -e "\n${CYAN}请按任意键以继续...${NC}"; read -n 1 -s
    for i in {1..3}; do
        termux-change-repo; fn_print_warning "正在更新软件包列表 (第 $i/3 次尝试)..."
        if pkg update -y; then fn_print_success "软件源配置并更新成功！"; return 0; fi
        if [ $i -lt 3 ]; then fn_print_error "当前选择的镜像源似乎有问题，正在尝试自动切换..."; sleep 2; fi
    done
    fn_print_error "已尝试 3 次，但均无法成功更新软件源。"; return 1
}

# =========================================================================
#   Git 同步功能模块
# =========================================================================

git_sync_check_deps() { if ! fn_check_command "git" || ! fn_check_command "rsync"; then fn_print_error "缺少核心工具 git 或 rsync。"; fn_print_warning "请先运行 [首次部署] 来安装所有必需的依赖项。"; return 1; fi; return 0; }
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
    source "$GIT_SYNC_CONFIG_FILE"; if [[ -z "$REPO_URL" || -z "$REPO_TOKEN" ]]; then fn_print_error "Git同步配置不完整或不存在。" >&2; return 1; fi
    fn_print_warning "正在自动测试支持数据上传的加速线路..."; local repo_path; repo_path=$(echo "$REPO_URL" | sed 's|https://github.com/||'); local github_public_url="https://github.com/SillyTavern/SillyTavern.git"; local successful_urls=()
    if [[ " ${PULL_MIRROR_LIST[*]} " =~ " ${github_public_url} " ]]; then
        local official_url="https://${REPO_TOKEN}@github.com/${repo_path}"; echo -e "  - 优先测试: 官方 GitHub ..." >&2
        if git_sync_test_one_mirror_push "$official_url"; then echo -e "    ${GREEN}[成功]${NC}" >&2; successful_urls+=("$official_url"); printf '%s\n' "${successful_urls[@]}"; return 0; else echo -e "    ${RED}[失败]${NC}" >&2; fi
    fi
    local other_mirrors=(); for mirror_url in "${PULL_MIRROR_LIST[@]}"; do [[ "$mirror_url" != "$github_public_url" ]] && other_mirrors+=("$mirror_url"); done
    if [ ${#other_mirrors[@]} -gt 0 ]; then
        echo -e "${YELLOW}已启动并行测试，将完整测试所有镜像...${NC}" >&2; local results_file; results_file=$(mktemp); local pids=()
        for mirror_url in "${other_mirrors[@]}"; do
            ( local authed_push_url=""; local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||'); if [[ "$mirror_url" == *"hub.gitmirror.com"* ]]; then authed_push_url="https://${REPO_TOKEN}@${mirror_host}/${repo_path}"; elif [[ "$mirror_url" == *"/gh/"* ]]; then authed_push_url="https://${REPO_TOKEN}@${mirror_host}/gh/${repo_path}"; elif [[ "$mirror_url" == *"/github.com/"* ]]; then authed_push_url="https://${REPO_TOKEN}@${mirror_host}/github.com/${repo_path}"; else exit 1; fi; if git_sync_test_one_mirror_push "$authed_push_url"; then echo "$authed_push_url" >> "$results_file"; echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${GREEN}[成功]${NC}" >&2; else echo -e "  - 测试: ${CYAN}${mirror_host}${NC} ${RED}[失败]${NC}" >&2; fi ) &
            pids+=($!)
        done
        wait "${pids[@]}"; if [ -s "$results_file" ]; then mapfile -t other_successful_urls < "$results_file"; successful_urls+=("${other_successful_urls[@]}"); fi; rm -f "$results_file"
    fi
    if [ ${#successful_urls[@]} -gt 0 ]; then fn_print_success "测试完成，找到 ${#successful_urls[@]} 条可用上传线路。" >&2; printf '%s\n' "${successful_urls[@]}"; else fn_print_error "所有上传线路均测试失败。" >&2; return 1; fi
}
git_sync_backup_to_cloud() {
    clear; fn_print_header "Git备份数据到云端 (上传)"; if ! git_sync_check_deps; then fn_press_any_key; return; fi; if [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then fn_print_error "请先在菜单 [1] 中配置Git同步服务。"; fn_press_any_key; return; fi
    mapfile -t push_urls < <(git_sync_find_pushable_mirror); if [ ${#push_urls[@]} -eq 0 ]; then fn_print_error "未能找到任何支持上传的线路。"; fn_press_any_key; return; fi
    local backup_success=false
    for push_url in "${push_urls[@]}"; do
        local chosen_host; chosen_host=$(echo "$push_url" | sed -e 's|https://.*@||' -e 's|/.*$||'); fn_print_warning "正在尝试使用线路 [${chosen_host}] 进行备份..."; local temp_dir; temp_dir=$(mktemp -d); cd "$HOME" || { fn_print_error "无法进入家目录！"; rm -rf "$temp_dir"; fn_press_any_key; return; }
        if ! git clone --depth 1 "$push_url" "$temp_dir"; then fn_print_error "克隆云端仓库失败！正在切换下一条线路..."; rm -rf "$temp_dir"; continue; fi
        fn_print_warning "正在同步本地数据到临时区..."; cd "$ST_DIR" || { fn_print_error "SillyTavern目录不存在！"; rm -rf "$temp_dir"; fn_press_any_key; return; }
        local paths_to_sync=("data" "public/scripts/extensions/third-party" "plugins" "config.yaml"); for item in "${paths_to_sync[@]}"; do if [ -e "$item" ]; then rsync -av --delete --exclude='*/backups/*' --exclude='*.log' --exclude='*/_cache/*' "./$item" "$temp_dir/"; fi; done
        cd "$temp_dir" || { fn_print_error "进入临时目录失败！"; rm -rf "$temp_dir"; fn_press_any_key; return; }; git add .; if git diff-index --quiet HEAD; then fn_print_success "数据与云端一致，无需上传。"; backup_success=true; rm -rf "$temp_dir"; break; fi
        fn_print_warning "正在提交数据变更..."; if ! git commit -m "Sync from Termux on $(date -u)"; then fn_print_error "Git 提交失败！无法创建数据快照。"; rm -rf "$temp_dir"; fn_press_any_key; return; fi
        fn_print_warning "正在上传到云端..."; if ! git push; then fn_print_error "上传失败！正在切换下一条线路..."; rm -rf "$temp_dir"; continue; fi
        fn_print_success "数据成功备份到云端！"; backup_success=true; rm -rf "$temp_dir"; break
    done
    if ! $backup_success; then fn_print_error "已尝试所有可用线路，但备份均失败。"; fi; fn_press_any_key
}
git_sync_restore_from_cloud() {
    clear; fn_print_header "Git从云端恢复数据 (下载)"; if ! git_sync_check_deps; then fn_press_any_key; return; fi; if [ ! -f "$GIT_SYNC_CONFIG_FILE" ]; then fn_print_error "请先在菜单 [1] 中配置Git同步服务。"; fn_press_any_key; return; fi
    fn_print_warning "此操作将用云端数据【覆盖】本地数据！"; read -p "是否在恢复前，先对当前本地数据进行一次备份？(强烈推荐) [Y/n]: " backup_confirm
    if [[ "${backup_confirm:-y}" =~ ^[Yy]$ ]]; then if ! fn_create_data_zip_backup; then fn_print_error "本地备份失败，恢复操作已中止。"; fn_press_any_key; return; fi; fi
    read -p "确认要从云端恢复数据吗？[y/N]: " restore_confirm; if [[ ! "$restore_confirm" =~ ^[yY]$ ]]; then fn_print_warning "操作已取消。"; fn_press_any_key; return; fi
    mapfile -t pull_urls < <(fn_find_fastest_mirror); if [ ${#pull_urls[@]} -eq 0 ]; then fn_print_error "未能找到任何支持下载的线路。"; fn_press_any_key; return; fi
    local restore_success=false
    for pull_url in "${pull_urls[@]}"; do
        local temp_dir; temp_dir=$(mktemp -d); local chosen_host; chosen_host=$(echo "$pull_url" | sed -e 's|https://||' -e 's|/.*$||'); fn_print_warning "正在尝试使用线路 [${chosen_host}] 进行恢复..."; cd "$HOME" || { fn_print_error "无法进入家目录！"; rm -rf "$temp_dir"; fn_press_any_key; return; }
        # shellcheck source=/dev/null
        source "$GIT_SYNC_CONFIG_FILE"; local repo_path; repo_path=$(echo "$REPO_URL" | sed 's|https://github.com/||'); local private_repo_url; private_repo_url=$(echo "$pull_url" | sed "s|/SillyTavern/SillyTavern.git|/${repo_path}|"); local pull_url_with_auth; pull_url_with_auth=$(echo "$private_repo_url" | sed "s|https://|https://${REPO_TOKEN}@|")
        if ! git clone --depth 1 "$pull_url_with_auth" "$temp_dir"; then fn_print_error "下载云端数据失败！正在切换下一条线路..."; rm -rf "$temp_dir"; continue; fi
        if [ ! -d "$temp_dir/data" ] || [ -z "$(ls -A "$temp_dir/data")" ]; then fn_print_error "下载的数据源无效或为空，恢复操作已中止！"; rm -rf "$temp_dir"; fn_press_any_key; return; fi
        fn_print_warning "正在将云端数据同步到本地..."; cd "$temp_dir" || { fn_print_error "进入临时目录失败！"; rm -rf "$temp_dir"; fn_press_any_key; return; }
        local paths_to_sync=("data" "public/scripts/extensions/third-party" "plugins" "config.yaml"); for item in "${paths_to_sync[@]}"; do if [ -e "$item" ]; then rsync -av --delete "./$item" "$ST_DIR/"; fi; done
        fn_print_success "数据已从云端成功恢复！"; restore_success=true; rm -rf "$temp_dir"; break
    done
    if ! $restore_success; then fn_print_error "已尝试所有可用线路，但恢复均失败。"; fi; fn_press_any_key
}
git_sync_clear_config() { if [ -f "$GIT_SYNC_CONFIG_FILE" ]; then read -p "确认要清除已保存的Git同步配置吗？(y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then rm -f "$GIT_SYNC_CONFIG_FILE"; fn_print_success "Git同步配置已清除。"; else fn_print_warning "操作已取消。"; fi; else fn_print_warning "未找到任何Git同步配置。"; fi; fn_press_any_key; }
menu_git_sync() {
    if ! git_sync_ensure_identity; then fn_print_error "Git身份配置失败，无法继续。"; fn_press_any_key; return; fi
    while true; do clear; fn_print_header "数据同步 (Git 方案)"; echo -e "      [1] ${CYAN}配置Git同步服务${NC}\n      [2] ${GREEN}备份到云端 (上传)${NC}\n      [3] ${YELLOW}从云端恢复 (下载)${NC}\n      [4] ${RED}清除Git同步配置${NC}\n      [0] ${CYAN}返回上一级${NC}\n"; read -p "    请输入选项: " choice; case $choice in 1) git_sync_configure ;; 2) git_sync_backup_to_cloud ;; 3) git_sync_restore_from_cloud ;; 4) git_sync_clear_config ;; 0) break ;; *) fn_print_error "无效输入。"; sleep 1 ;; esac; done
}

# =========================================================================
#   Rclone 通用函数
# =========================================================================

rclone_check_deps() {
    if ! fn_check_command "rclone"; then
        fn_print_error "缺少核心工具 rclone。"; read -p "是否立即安装？(y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then pkg install rclone -y || { fn_print_error "rclone 安装失败！"; return 1; }; else return 1; fi
    fi; return 0
}
rclone_ensure_password() {
    mkdir -p "$RCLONE_CONFIG_DIR"
    if [ ! -f "$RCLONE_CONFIG_FILE" ] || ! grep -q "pass =" "$RCLONE_CONFIG_FILE"; then
        fn_print_warning "首次使用Rclone，需要设置一个主密码。"; echo "这是一个一次性操作，用于保护您的密钥安全。"
        local pass1 pass2
        while true; do
            read -p "请输入您的Rclone主密码: " pass1
            read -p "请再次输入以确认: " pass2
            if [[ -z "$pass1" ]]; then fn_print_error "密码不能为空！"; continue; fi
            if [[ "$pass1" == "$pass2" ]]; then break; else fn_print_error "两次输入的密码不匹配，请重试。"; fi
        done
        local obscured_pass; obscured_pass=$(echo "$pass1" | rclone obscure -)
        (umask 077; echo -e "[DEFAULT]\nask_password = false\npass = $obscured_pass" > "$RCLONE_CONFIG_FILE")
        fn_print_success "主密码设置完成！"; sleep 1
    fi
}
rclone_incremental_backup_logic() {
    local config_file="$1"; local type_name="$2"; clear; fn_print_header "增量备份到云端 ($type_name)"
    if [ ! -f "$config_file" ]; then fn_print_error "请先在菜单 [1] 中配置$type_name同步服务。"; fn_press_any_key; return; fi
    # shellcheck source=/dev/null
    source "$config_file"; local timestamp; timestamp=$(date +"%Y-%m-%d_%H-%M-%S"); local backups_root="${RCLONE_REMOTE_NAME}:${RCLONE_BUCKET_NAME}/backups"; local new_backup_path="${backups_root}/${timestamp}"; fn_print_warning "将创建新的云端备份: ${timestamp}"
    local latest_backup; latest_backup=$(rclone lsf "$backups_root" --dirs-only 2>/dev/null | sort -r | head -n 1)
    if [[ -n "$latest_backup" ]]; then
        local latest_backup_path="${backups_root}/${latest_backup}"; fn_print_warning "发现最新备份: ${latest_backup%/}"
        fn_print_warning "正在尝试高效备份 (服务器端复制)..."
        if ! rclone copy "$latest_backup_path" "$new_backup_path" --progress; then
            fn_print_warning "服务器端复制失败 (可能当前服务不支持)，已自动降级为完整上传模式。"
        else
            fn_print_success "服务器端复制完成。"
        fi
    else fn_print_warning "未发现任何旧备份，将执行首次完整上传。"; fi
    local temp_filter_file; temp_filter_file=$(mktemp); cat > "$temp_filter_file" <<EOF
+ /data/**
+ /public/scripts/extensions/third-party/**
+ /plugins/**
+ /config.yaml
- /data/_cache/**
- *.log
- /data/backups/**
- *
EOF
    fn_print_warning "正在同步本地数据变更..."
    if rclone sync "$ST_DIR" "$new_backup_path" --filter-from "$temp_filter_file" --progress; then
        fn_print_success "数据成功备份到云端！"
        mapfile -t all_backups < <(rclone lsf "$backups_root" --dirs-only 2>/dev/null | sort)
        if [ "${#all_backups[@]}" -gt $BACKUP_LIMIT ]; then
            fn_print_warning "正在清理旧备份..."
            local backups_to_delete_count=$(( ${#all_backups[@]} - BACKUP_LIMIT )); fn_print_warning "备份数量超过上限(${BACKUP_LIMIT})，将删除 ${backups_to_delete_count} 个最旧的备份。"
            for ((i=0; i<backups_to_delete_count; i++)); do local old_backup_to_delete="${all_backups[$i]}"; echo "  - 删除: ${old_backup_to_delete}"; rclone purge "${backups_root}/${old_backup_to_delete}"; done
            fn_print_success "清理完成。"
        fi
    else fn_print_error "数据同步失败！正在自动清理本次不完整的备份..."; rclone purge "$new_backup_path"; fn_print_error "备份操作已中止。"; fi
    rm -f "$temp_filter_file"; fn_press_any_key
}
rclone_zip_backup_logic() {
    local config_file="$1"; local type_name="$2"; clear; fn_print_header "打包备份到云端 ($type_name)"
    if [ ! -f "$config_file" ]; then fn_print_error "请先在菜单 [1] 中配置$type_name同步服务。"; fn_press_any_key; return; fi
    local local_zip_path; local_zip_path=$(fn_create_data_zip_backup); if [ -z "$local_zip_path" ]; then fn_print_error "创建本地压缩包失败，无法上传。"; fn_press_any_key; return; fi
    # shellcheck source=/dev/null
    source "$config_file"; local zip_backup_root="${RCLONE_REMOTE_NAME}:${RCLONE_BUCKET_NAME}/zip_backups/"; fn_print_warning "正在上传压缩包到云端..."
    if rclone copyto "$local_zip_path" "${zip_backup_root}$(basename "$local_zip_path")" --progress; then
        fn_print_success "压缩包成功上传到云端！"; rm -f "$local_zip_path"
        mapfile -t all_zip_backups < <(rclone lsf "$zip_backup_root" 2>/dev/null | sort); if [ "${#all_zip_backups[@]}" -gt $BACKUP_LIMIT ]; then
            fn_print_warning "正在清理旧的打包备份..."; local zips_to_delete_count=$(( ${#all_zip_backups[@]} - BACKUP_LIMIT ))
            fn_print_warning "打包备份数量超过上限(${BACKUP_LIMIT})，将删除 ${zips_to_delete_count} 个最旧的备份。"
            for ((i=0; i<zips_to_delete_count; i++)); do local old_zip="${all_zip_backups[$i]}"; echo "  - 删除: ${old_zip}"; rclone deletefile "${zip_backup_root}${old_zip}"; done
            fn_print_success "清理完成。"
        fi
    else fn_print_error "压缩包上传失败！"; fi
    fn_press_any_key
}
rclone_restore_logic() {
    local config_file="$1"; local type_name="$2"; clear; fn_print_header "从云端恢复数据 ($type_name)"; if [ ! -f "$config_file" ]; then fn_print_error "请先在菜单 [1] 中配置$type_name同步服务。"; fn_press_any_key; return; fi
    # shellcheck source=/dev/null
    source "$config_file"; fn_print_warning "正在获取云端备份列表..."; mapfile -t backup_list < <(rclone lsf "${RCLONE_REMOTE_NAME}:${RCLONE_BUCKET_NAME}/backups" --dirs-only 2>/dev/null | sort -r)
    if [ ${#backup_list[@]} -eq 0 ]; then fn_print_error "未在云端找到任何备份。"; fn_press_any_key; return; fi
    echo "请选择要恢复的备份版本 (按时间倒序):"; for i in "${!backup_list[@]}"; do printf "  [%-2d] %s\n" "$((i + 1))" "${backup_list[$i]%/}"; done
    read -p "请输入选项 (其他键取消): " choice; if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_list[@]}" ]; then fn_print_warning "操作已取消。"; fn_press_any_key; return; fi
    local selected_backup="${backup_list[$((choice-1))]}"; fn_print_warning "此操作将使用备份 [${selected_backup%/}] 【覆盖】本地数据！"; read -p "确认要恢复吗？[y/N]: " confirm; if [[ ! "$confirm" =~ ^[yY]$ ]]; then fn_print_warning "操作已取消。"; fn_press_any_key; return; fi
    local remote_path="${RCLONE_REMOTE_NAME}:${RCLONE_BUCKET_NAME}/backups/${selected_backup}"; fn_print_warning "正在下载并覆盖本地数据..."
    if rclone sync "$remote_path" "$ST_DIR" --progress; then fn_print_success "数据已从云端成功恢复！"; else fn_print_error "恢复操作失败！"; fi
    fn_press_any_key
}

# =========================================================================
#   Rclone (S3) 同步功能模块
# =========================================================================

s3_configure() {
    clear; fn_print_header "配置 Rclone (S3) 同步服务"; rclone_ensure_password
    local remote_name="st-s3-sync"; local access_key secret_key endpoint bucket region provider
    while true; do read -p "请输入 Access Key ID: " access_key; [[ -n "$access_key" ]] && break || fn_print_error "Access Key ID 不能为空！"; done
    while true; do read -p "请输入 Secret Access Key: " secret_key; [[ -n "$secret_key" ]] && break || fn_print_error "Secret Access Key 不能为空！"; done
    while true; do read -p "请输入 Endpoint URL: " endpoint; [[ -n "$endpoint" ]] && break || fn_print_error "Endpoint 不能为空！"; done
    while true; do read -p "请输入 Bucket (存储桶) 名称: " bucket; [[ -n "$bucket" ]] && break || fn_print_error "Bucket 名称不能为空！"; done
    read -p "请输入 S3 提供商 (例如 AWS, Cloudflare, MinIO, Ceph, 其他请留空): " provider
    read -p "请输入 Region (地域，可留空): " region
    fn_print_warning "正在创建Rclone配置...";
    rclone config create "$remote_name" s3 provider="$provider" access_key_id="$access_key" secret_access_key="$secret_key" endpoint="$endpoint" ${region:+region="$region"}
    if [ $? -eq 0 ]; then echo "RCLONE_REMOTE_NAME=\"$remote_name\"" > "$S3_SYNC_CONFIG_FILE"; echo "RCLONE_BUCKET_NAME=\"$bucket\"" >> "$S3_SYNC_CONFIG_FILE"; fn_print_success "Rclone (S3) 同步服务配置已保存！"; else fn_print_error "Rclone配置创建失败！请检查输入信息。"; fi
    fn_press_any_key
}
s3_clear_config() {
    if [ -f "$S3_SYNC_CONFIG_FILE" ]; then read -p "确认要清除已保存的Rclone(S3)同步配置吗？(y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then # shellcheck source=/dev/null
            source "$S3_SYNC_CONFIG_FILE"; rclone config delete "$RCLONE_REMOTE_NAME"; rm -f "$S3_SYNC_CONFIG_FILE"; fn_print_success "Rclone(S3)同步配置已清除。"; else fn_print_warning "操作已取消。"; fi
    else fn_print_warning "未找到任何Rclone(S3)同步配置。"; fi; fn_press_any_key
}
menu_s3_sync() {
    if ! rclone_check_deps; then fn_press_any_key; return; fi
    while true; do clear; fn_print_header "数据同步 (Rclone/S3 方案)"
    echo -e "      [1] ${CYAN}配置S3同步服务${NC}"
    echo -e "      [2] ${GREEN}增量备份到云端 (推荐)${NC}"
    echo -e "      [3] ${GREEN}打包备份到云端 (最稳定)${NC}"
    echo -e "      [4] ${YELLOW}从云端恢复 (增量备份)${NC}"
    echo -e "      [5] ${RED}清除S3同步配置${NC}"
    echo -e "      [0] ${CYAN}返回上一级${NC}\n"
    read -p "    请输入选项: " choice
    case $choice in 1) s3_configure ;; 2) rclone_incremental_backup_logic "$S3_SYNC_CONFIG_FILE" "S3" ;; 3) rclone_zip_backup_logic "$S3_SYNC_CONFIG_FILE" "S3" ;; 4) rclone_restore_logic "$S3_SYNC_CONFIG_FILE" "S3" ;; 5) s3_clear_config ;; 0) break ;; *) fn_print_error "无效输入。"; sleep 1 ;; esac; done
}

# =========================================================================
#   Rclone (WebDAV) 同步功能模块
# =========================================================================

webdav_configure() {
    clear; fn_print_header "配置 WebDAV 同步服务"; rclone_ensure_password
    local remote_name="st-webdav-sync"; local url user pass bucket
    while true; do read -p "请输入 WebDAV URL: " url; [[ -n "$url" ]] && break || fn_print_error "URL 不能为空！"; done
    while true; do read -p "请输入 WebDAV 用户名: " user; [[ -n "$user" ]] && break || fn_print_error "用户名不能为空！"; done
    while true; do read -p "请输入 WebDAV 密码: " pass; [[ -n "$pass" ]] && break || fn_print_error "密码不能为空！"; done
    read -p "请输入一个用于存放备份的根目录名 (留空默认为 'SillyTavernBackups'): " bucket
    if [[ -z "$bucket" ]]; then bucket="SillyTavernBackups"; fi
    fn_print_warning "正在创建Rclone配置..."; local obscured_pass; obscured_pass=$(echo "$pass" | rclone obscure -)
    rclone config create "$remote_name" webdav url="$url" user="$user" pass="$obscured_pass"
    if [ $? -eq 0 ]; then echo "RCLONE_REMOTE_NAME=\"$remote_name\"" > "$WEBDAV_SYNC_CONFIG_FILE"; echo "RCLONE_BUCKET_NAME=\"$bucket\"" >> "$WEBDAV_SYNC_CONFIG_FILE"; fn_print_success "Rclone (WebDAV) 同步服务配置已保存！"; else fn_print_error "Rclone配置创建失败！请检查输入信息。"; fi
    fn_press_any_key
}
webdav_clear_config() {
    if [ -f "$WEBDAV_SYNC_CONFIG_FILE" ]; then read -p "确认要清除已保存的Rclone(WebDAV)同步配置吗？(y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then # shellcheck source=/dev/null
            source "$WEBDAV_SYNC_CONFIG_FILE"; rclone config delete "$RCLONE_REMOTE_NAME"; rm -f "$WEBDAV_SYNC_CONFIG_FILE"; fn_print_success "Rclone(WebDAV)同步配置已清除。"; else fn_print_warning "操作已取消。"; fi
    else fn_print_warning "未找到任何Rclone(WebDAV)同步配置。"; fi; fn_press_any_key
}
menu_webdav_sync() {
    if ! rclone_check_deps; then fn_press_any_key; return; fi
    while true; do clear; fn_print_header "数据同步 (WebDAV 方案)"
    echo -e "      [1] ${CYAN}配置WebDAV同步服务${NC}"
    echo -e "      [2] ${GREEN}增量备份到云端 (推荐)${NC}"
    echo -e "      [3] ${GREEN}打包备份到云端 (最稳定)${NC}"
    echo -e "      [4] ${YELLOW}从云端恢复 (增量备份)${NC}"
    echo -e "      [5] ${RED}清除WebDAV同步配置${NC}"
    echo -e "      [0] ${CYAN}返回上一级${NC}\n"
    read -p "    请输入选项: " choice
    case $choice in 1) webdav_configure ;; 2) rclone_incremental_backup_logic "$WEBDAV_SYNC_CONFIG_FILE" "WebDAV" ;; 3) rclone_zip_backup_logic "$WEBDAV_SYNC_CONFIG_FILE" "WebDAV" ;; 4) rclone_restore_logic "$WEBDAV_SYNC_CONFIG_FILE" "WebDAV" ;; 5) webdav_clear_config ;; 0) break ;; *) fn_print_error "无效输入。"; sleep 1 ;; esac; done
}

# =========================================================================
#   主同步菜单
# =========================================================================

main_sync_menu() {
    while true; do clear; fn_print_header "数据同步方案选择"
    echo -e "      [1] ${CYAN}Git 方案 (适合技术用户，提供版本历史)${NC}"
    echo -e "      [2] ${GREEN}Rclone/S3 方案 (适合云存储用户)${NC}"
    echo -e "      [3] ${YELLOW}WebDAV 方案 (适合网盘用户)${NC}"
    echo -e "      [0] ${CYAN}返回主菜单${NC}\n"
    read -p "    请输入选项: " choice
    case $choice in 1) menu_git_sync ;; 2) menu_s3_sync ;; 3) menu_webdav_sync ;; 0) break ;; *) fn_print_error "无效输入。"; sleep 1 ;; esac; done
}

# =========================================================================
#   核心功能模块
# =========================================================================

main_start() { clear; fn_print_header "启动 SillyTavern"; if [ ! -f "$ST_DIR/start.sh" ]; then fn_print_warning "SillyTavern 尚未安装，请先部署。"; fn_press_any_key; return; fi; cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"; echo -e "正在配置NPM镜像并准备启动环境..."; npm config set registry https://registry.npmmirror.com; echo -e "${YELLOW}环境准备就绪，正在启动SillyTavern服务...${NC}"; echo -e "${YELLOW}首次启动或更新后会自动安装依赖，耗时可能较长...${NC}"; bash start.sh; echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"; fn_press_any_key; }
fn_create_data_zip_backup() { fn_print_warning "正在创建核心数据备份 (.zip)..."; if [ ! -d "$ST_DIR" ]; then fn_print_error "SillyTavern 目录不存在，无法备份。"; return 1; fi; local paths_to_backup=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml"); mkdir -p "$BACKUP_ROOT_DIR"; local timestamp; timestamp=$(date +"%Y-%m-%d_%H-%M"); local backup_name="ST_核心数据_${timestamp}.zip"; local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}"; cd "$ST_DIR" || { fn_print_error "无法进入 SillyTavern 目录进行备份。"; return 1; }; local has_files=false; for item in "${paths_to_backup[@]}"; do if [ -e "$item" ]; then has_files=true; break; fi; done; if ! $has_files; then fn_print_error "未能收集到任何有效的数据文件进行备份。"; cd "$HOME"; return 1; fi; local exclude_params=(-x "*/_cache/*" -x "*.log" -x "*/backups/*"); if zip -rq "$backup_zip_path" "${paths_to_backup[@]}" "${exclude_params[@]}"; then fn_print_success "核心数据备份成功: ${backup_name}"; cd "$HOME"; echo "$backup_zip_path"; return 0; else fn_print_error "创建 .zip 备份失败！"; cd "$HOME"; return 1; fi; }
main_install() {
    local auto_start=true; if [[ "$1" == "no-start" ]]; then auto_start=false; fi; clear; fn_print_header "SillyTavern 部署向导"
    if [[ "$auto_start" == "true" ]]; then while true; do if ! fn_update_source_with_retry; then read -p $'\n'"${RED}软件源配置失败。是否重试？(直接回车=是, 输入n=否): ${NC}" retry_choice; if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then fn_print_error_exit "用户取消操作。"; fi; else break; fi; done; fn_print_header "2/5: 安装核心依赖"; echo -e "${YELLOW}正在安装核心依赖...${NC}"; yes | pkg upgrade -y; yes | pkg install git nodejs-lts rsync zip unzip termux-api coreutils gawk bc rclone || fn_print_error_exit "核心依赖安装失败！"; fn_print_success "核心依赖安装完毕。"; fi
    fn_print_header "3/5: 下载 ST 主程序"; if [ -f "$ST_DIR/start.sh" ]; then fn_print_warning "检测到完整的 SillyTavern 安装，跳过下载。"; elif [ -d "$ST_DIR" ] && [ -n "$(ls -A "$ST_DIR")" ]; then fn_print_error_exit "目录 $ST_DIR 已存在但安装不完整。请手动删除该目录后再试。"; else
        local download_success=false; mapfile -t sorted_mirrors < <(fn_find_fastest_mirror); if [ ${#sorted_mirrors[@]} -eq 0 ]; then fn_print_error_exit "所有 Git 镜像均测试失败，无法下载主程序。"; fi
        for mirror_url in "${sorted_mirrors[@]}"; do local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||'); fn_print_warning "正在尝试从镜像 [${mirror_host}] 下载 (${REPO_BRANCH} 分支)..."; if git clone --depth 1 -b "$REPO_BRANCH" "$mirror_url" "$ST_DIR"; then fn_print_success "主程序下载完成。"; download_success=true; break; else fn_print_error "使用镜像 [${mirror_host}] 下载失败！正在切换..."; rm -rf "$ST_DIR"; fi; done
        if ! $download_success; then fn_print_error_exit "已尝试所有可用线路，但下载均失败。"; fi
    fi
    fn_print_header "4/5: 配置并安装依赖"; if [ -d "$ST_DIR" ]; then if ! fn_run_npm_install_with_retry; then fn_print_error_exit "依赖安装最终失败，部署中断。"; fi; else fn_print_warning "SillyTavern 目录不存在，跳过此步。"; fi
    if $auto_start; then fn_print_header "5/5: 设置快捷方式与自启"; fn_create_shortcut; main_manage_autostart "set_default"; echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"; sleep 3; main_start; else fn_print_success "全新版本下载与配置完成。"; fi
}
main_update_st() {
    clear; fn_print_header "更新 SillyTavern 主程序"; if [ ! -d "$ST_DIR/.git" ]; then fn_print_warning "未找到Git仓库，请先完整部署。"; fn_press_any_key; return; fi; cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录: $ST_DIR"; local update_success=false; mapfile -t sorted_mirrors < <(fn_find_fastest_mirror); if [ ${#sorted_mirrors[@]} -eq 0 ]; then fn_print_error "所有 Git 镜像均测试失败，无法更新。"; fn_press_any_key; return; fi
    for mirror_url in "${sorted_mirrors[@]}"; do
        local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||'); fn_print_warning "正在尝试使用镜像 [${mirror_host}] 更新..."; git remote set-url origin "$mirror_url"; local git_output; git_output=$(git pull origin "$REPO_BRANCH" 2>&1)
        if [ $? -eq 0 ]; then fn_print_success "代码更新成功。"; if fn_run_npm_install_with_retry; then update_success=true; fi; break; else
            if echo "$git_output" | grep -qE "overwritten by merge|Please commit|unmerged files"; then
                clear; fn_print_header "检测到更新冲突！"; fn_print_warning "原因: 你可能修改过酒馆的文件，导致无法自动合并新版本。"; echo "--- 冲突文件预览 ---"; echo "$git_output" | grep -E "^\s+" | head -n 5; echo "--------------------"; echo -e "\n请选择操作方式："; echo -e "  [${GREEN}回车${NC}] ${BOLD}自动备份并重新安装 (推荐)${NC}"; echo -e "  [1]    ${YELLOW}强制覆盖更新 (危险)${NC}"; echo -e "  [0]    ${CYAN}放弃更新${NC}"; read -p "请输入选项: " choice
                case "$choice" in
                "" | 'b' | 'B') clear; fn_print_header "步骤 1/5: 创建核心数据备份"; local data_backup_zip_path; data_backup_zip_path=$(fn_create_data_zip_backup); if [ -z "$data_backup_zip_path" ]; then fn_print_error_exit "核心数据备份(.zip)创建失败。"; fi; fn_print_header "步骤 2/5: 完整备份当前目录"; local renamed_backup_dir="${ST_DIR}_backup_$(date +%Y%m%d%H%M%S)"; cd "$HOME"; mv "$ST_DIR" "$renamed_backup_dir" || fn_print_error_exit "备份失败！"; fn_print_success "旧目录已完整备份为: $(basename "$renamed_backup_dir")"; fn_print_header "步骤 3/5: 下载并安装新版"; main_install "no-start"; if [ ! -d "$ST_DIR" ]; then fn_print_error_exit "新版本安装失败。"; fi; fn_print_header "步骤 4/5: 自动恢复用户数据"; fn_print_warning "正在将备份数据解压至新目录..."; if ! unzip -o "$data_backup_zip_path" -d "$ST_DIR" >/dev/null 2>&1; then fn_print_error_exit "数据恢复失败！"; fi; fn_print_success "用户数据已成功恢复。"; fn_print_header "步骤 5/5: 更新完成"; fn_print_success "SillyTavern 已更新并恢复数据！"; echo -e "\n${CYAN}请按任意键，启动更新后的 SillyTavern...${NC}"; read -n 1 -s; main_start; return ;;
                '1') fn_print_warning "正在执行强制覆盖..."; if git reset --hard "origin/$REPO_BRANCH" && git pull origin "$REPO_BRANCH"; then fn_print_success "强制更新成功。"; if fn_run_npm_install_with_retry; then update_success=true; fi; else fn_print_error "强制更新失败！"; fi; break ;;
                *) fn_print_warning "已取消更新。"; fn_press_any_key; return ;;
                esac
            else fn_print_error "使用镜像 [${mirror_host}] 更新失败！错误: $(echo "$git_output" | tail -n 1)"; fn_print_error "正在切换下一条线路..."; sleep 1; fi
        fi
    done
    if ! $update_success; then fn_print_error "已尝试所有可用线路，但更新均失败。"; fi; fn_press_any_key
}
main_data_management_menu() { while true; do clear; fn_print_header "SillyTavern 本地数据管理"; echo -e "      [1] ${GREEN}创建自定义备份${NC}\n      [2] ${CYAN}数据迁移/恢复指南${NC}\n      [3] ${RED}删除旧备份${NC}\n      [0] ${CYAN}返回主菜单${NC}\n"; read -p "    请输入选项: " choice; case $choice in 1) run_backup_interactive ;; 2) main_migration_guide ;; 3) run_delete_backup ;; 0) break ;; *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;; esac; done; }
main_update_script() { clear; fn_print_header "更新助手脚本"; echo -e "${YELLOW}正在从 Gitee 下载新版本...${NC}"; local temp_file; temp_file=$(mktemp); if ! curl -L -o "$temp_file" "$SCRIPT_URL"; then rm -f "$temp_file"; fn_print_warning "下载失败。"; elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then rm -f "$temp_file"; fn_print_success "当前已是最新版本。"; else sed -i 's/\r$//' "$temp_file"; chmod +x "$temp_file"; mv "$temp_file" "$SCRIPT_SELF_PATH"; rm -f "$UPDATE_FLAG_FILE"; echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"; sleep 2; exec "$SCRIPT_SELF_PATH" --updated; fi; fn_press_any_key; }
check_for_updates_on_start() {
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
fn_create_shortcut() { local BASHRC_FILE="$HOME/.bashrc"; local ALIAS_CMD="alias st='\"$SCRIPT_SELF_PATH\"'"; local ALIAS_COMMENT="# SillyTavern 助手快捷命令"; if ! grep -qF "$ALIAS_CMD" "$BASHRC_FILE"; then chmod +x "$SCRIPT_SELF_PATH"; echo -e "\n$ALIAS_COMMENT\n$ALIAS_CMD" >>"$BASHRC_FILE"; fn_print_success "已创建快捷命令 'st'。请重启 Termux 或执行 'source ~/.bashrc' 生效。"; fi; }
main_manage_autostart() { local BASHRC_FILE="$HOME/.bashrc"; local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""; local is_set=false; grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true; if [[ "$1" == "set_default" ]]; then if ! $is_set; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"; fn_print_success "已设置 Termux 启动时自动运行本助手。"; fi; return; fi; clear; fn_print_header "管理助手自启"; if $is_set; then echo -e "当前状态: ${GREEN}已启用${NC}"; echo -e "${CYAN}提示: 关闭自启后，输入 'st' 命令即可手动启动助手。${NC}"; read -p "是否取消自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then sed -i "/# SillyTavern 助手/d" "$BASHRC_FILE"; sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"; fn_print_success "已取消自启。"; fi; else echo -e "当前状态: ${RED}未启用${NC}"; echo -e "${CYAN}提示: 在 Termux 中输入 'st' 命令可以手动启动助手。${NC}"; read -p "是否设置自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"; fn_print_success "已成功设置自启。"; fi; fi; fn_press_any_key; }
main_open_docs() { clear; fn_print_header "查看帮助文档"; local docs_url="https://blog.qjyg.de"; echo -e "文档网址: ${CYAN}${docs_url}${NC}\n"; if fn_check_command "termux-open-url"; then termux-open-url "$docs_url"; fn_print_success "已尝试在浏览器中打开。"; else fn_print_warning "命令 'termux-open-url' 不存在。\n请先安装【Termux:API】应用及 'pkg install termux-api'。"; fi; fn_press_any_key; }

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

if [[ "$1" != "--no-check" && "$1" != "--updated" ]]; then check_for_updates_on_start; fi
if [[ "$1" == "--updated" ]]; then clear; fn_print_success "助手已成功更新至最新版本！"; sleep 2; fi

while true; do
    clear; echo -e "${CYAN}${BOLD}"; cat << "EOF"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v2.2.1    ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    update_notice=""; if [ -f "$UPDATE_FLAG_FILE" ]; then update_notice=" ${YELLOW}[!] 有更新${NC}"; fi
    echo -e "${NC}\n    选择一个操作来开始：\n"
    echo -e "      [1] ${GREEN}${BOLD}启动 SillyTavern${NC}"
    echo -e "      [2] ${CYAN}${BOLD}数据同步 (云端备份/恢复)${NC}"
    echo -e "      [3] ${CYAN}${BOLD}本地数据管理${NC}"
    echo -e "      [4] ${YELLOW}${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [5] 更新 ST 主程序    [6] 更新助手脚本${update_notice}"
    echo -e "      [7] 管理助手自启      [8] 查看帮助文档\n"
    echo -e "      ${RED}[0] 退出助手${NC}\n"
    read -p "    请输入选项数字: " choice
    case $choice in 1) main_start ;; 2) main_sync_menu ;; 3) main_data_management_menu ;; 4) main_install ;; 5) main_update_st ;; 6) main_update_script ;; 7) main_manage_autostart ;; 8) main_open_docs ;; 0) echo -e "\n感谢使用，助手已退出。"; rm -f "$UPDATE_FLAG_FILE"; exit 0 ;; *) fn_print_warning "无效输入，请重新选择。"; sleep 1.5 ;; esac
done
