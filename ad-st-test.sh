#!/data/data/com.termux/files/usr/bin/bash

# SillyTavern 助手 v2.0 (终极稳定版)
# 作者: Qingjue | 小红书号: 826702880
# v2.0: 进行了全面代码审查和重构，增加了全局依赖检查，优化了安装与更新流程。

# --- 脚本环境与色彩定义 ---
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# --- 核心配置 ---
ST_DIR="$HOME/SillyTavern"
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
REPO_BRANCH="release"
BACKUP_ROOT_DIR="$ST_DIR/_我的备份"
BACKUP_LIMIT=10
SCRIPT_SELF_PATH=$(readlink -f "$0")
SCRIPT_URL="https://gitee.com/canaan723/st-tools/raw/main/ad-st.sh"
CONFIG_FILE="$HOME/.st_assistant.conf"
UPDATE_FLAG_FILE="/data/data/com.termux/files/usr/tmp/.st_assistant_update_flag"
# [新增] 定义脚本运行所需的核心命令
REQUIRED_COMMANDS=("git" "nodejs" "npm" "curl" "zip" "gawk" "bc" "timeout")

# =========================================================================
#   辅助函数库
# =========================================================================

fn_print_header() { echo -e "\n${CYAN}═══ ${BOLD}$1 ${NC}═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ ${BOLD}$1${NC}"; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_error() { echo -e "${RED}✗ $1${NC}" >&2; }
# [重命名] 函数名更精确地描述行为
fn_terminate_with_prompt() { echo -e "\n${RED}✗ ${BOLD}$1${NC}\n${RED}流程已终止。${NC}" >&2; fn_press_any_key; exit 1; }
fn_press_any_key() { echo -e "\n${CYAN}请按任意键返回...${NC}"; read -n 1 -s; }
fn_check_command() { command -v "$1" >/dev/null 2>&1; }

# [新增] 全局依赖检查，确保脚本运行环境完整
fn_check_dependencies() {
    local missing_cmds=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! fn_check_command "$cmd"; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        clear
        fn_print_header "核心依赖缺失"
        fn_print_error "检测到以下必需的命令未安装: ${missing_cmds[*]}"
        fn_print_warning "这通常是因为您尚未完成首次部署流程。"
        echo -e "\n请在主菜单选择 ${YELLOW}[3] 首次部署 (全新安装)${NC} 来自动安装所有依赖。"
        fn_press_any_key
        # 允许用户返回主菜单选择部署，而不是直接退出
        return 1
    fi
    return 0
}

# 同步 PC 版的镜像测速逻辑
fn_find_fastest_mirror() {
    fn_print_warning "开始测试 Git 镜像连通性与速度..."
    local github_url="https://github.com/SillyTavern/SillyTavern.git"

    echo -e "  [1/?] 正在优先测试 GitHub 官方源..."
    if timeout 15s git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
        fn_print_success "GitHub 官方源直连可用，将优先使用！"
        echo "$github_url"; return 0
    else
        fn_print_error "GitHub 官方源连接超时，将测试其他镜像..."
    fi

    local other_mirrors=()
    for mirror in "${MIRROR_LIST[@]}"; do [[ "$mirror" != "$github_url" ]] && other_mirrors+=("$mirror"); done

    if [ ${#other_mirrors[@]} -eq 0 ]; then fn_print_error "没有其他可用的镜像进行测试。"; return 1; fi
    
    echo -e "${YELLOW}已启动并行测试，等待所有镜像响应...${NC}"
    local results_file; results_file=$(mktemp)
    local pids=()
    
    for mirror_url in "${other_mirrors[@]}"; do
        (
            local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
            local start_time; start_time=$(date +%s.%N)
            if timeout 15s git ls-remote "$mirror_url" HEAD >/dev/null 2>&1; then
                local end_time; end_time=$(date +%s.%N)
                local elapsed_time; elapsed_time=$(echo "$end_time - $start_time" | bc)
                echo "$elapsed_time $mirror_url" >> "$results_file"
                echo -e "  [${GREEN}✓${NC}] 测试成功: ${CYAN}${mirror_host}${NC} - 耗时 ${GREEN}${elapsed_time}s${NC}"
            else
                echo -e "  [${RED}✗${NC}] 测试失败: ${CYAN}${mirror_host}${NC} - ${RED}连接超时或无效${NC}"
            fi
        ) &
        pids+=($!)
    done

    wait "${pids[@]}"

    if [ ! -s "$results_file" ]; then
        fn_print_error "所有镜像都无法连接。"; rm -f "$results_file"; return 1
    fi
    
    local fastest_line; fastest_line=$(sort -n "$results_file" | head -n 1)
    fn_print_success "已选定最快镜像: $(echo "$fastest_line" | awk '{print $2}' | sed -e 's|https://||' -e 's|/.*$||') (耗时 $(echo "$fastest_line" | awk '{print $1}')s)"
    
    sort -n "$results_file" | awk '{print $2}'
    rm -f "$results_file"
}

# 带有多层重试逻辑的 NPM 安装函数
fn_run_npm_install_with_retry() {
    if [ ! -d "$ST_DIR" ]; then return 1; fi; cd "$ST_DIR" || return 1
    
    fn_print_warning "正在同步依赖包 (npm install)..."
    npm install --no-audit --no-fund --omit=dev && fn_print_success "依赖包同步完成。" && return 0

    fn_print_warning "依赖包同步失败，将自动清理缓存并重试..."
    npm cache clean --force >/dev/null 2>&1
    npm install --no-audit --no-fund --omit=dev && fn_print_success "依赖包重试同步成功。" && return 0

    fn_print_warning "国内镜像安装失败，将切换到NPM官方源进行最后尝试..."
    npm config delete registry
    local exit_code
    npm install --no-audit --no-fund --omit=dev
    exit_code=$?
    
    fn_print_warning "正在将 NPM 源恢复为国内镜像..."
    npm config set registry https://registry.npmmirror.com

    if [ $exit_code -eq 0 ]; then
        fn_print_success "使用官方源安装依赖成功！"; return 0
    else
        fn_print_error "所有安装尝试均失败。"; return 1
    fi
}

# =========================================================================
#   核心功能模块
# =========================================================================

main_start() {
    clear; fn_print_header "启动 SillyTavern"
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "SillyTavern 尚未安装，请先部署。"; fn_press_any_key; return
    fi
    cd "$ST_DIR" || fn_terminate_with_prompt "无法进入 SillyTavern 目录。"
    
    echo -e "正在配置NPM镜像并准备启动环境..."
    npm config set registry https://registry.npmmirror.com
    echo -e "${YELLOW}环境准备就绪，正在启动SillyTavern服务...${NC}"
    echo -e "${YELLOW}首次启动或更新后会自动安装依赖，耗时可能较长，请耐心等待...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"; fn_press_any_key
}

# [新增] 提炼出的核心安装流程，用于首次部署和更新冲突后的重装
fn_core_install_process() {
    fn_print_header "下载 ST 主程序"
    if [ -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "检测到完整的 SillyTavern 安装，跳过下载。"
    elif [ -d "$ST_DIR" ] && [ -n "$(ls -A "$ST_DIR")" ]; then
        fn_terminate_with_prompt "目录 $ST_DIR 已存在但安装不完整。请手动删除该目录后再试。"
    else
        mapfile -t sorted_mirrors < <(fn_find_fastest_mirror)
        if [ ${#sorted_mirrors[@]} -eq 0 ]; then
            fn_print_error "所有镜像均测试失败，无法下载。"; return 1
        fi

        local download_success=false
        for mirror_url in "${sorted_mirrors[@]}"; do
            local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
            fn_print_warning "正在尝试从镜像 [${mirror_host}] 下载 (${REPO_BRANCH} 分支)..."
            if git clone --depth 1 -b "$REPO_BRANCH" "$mirror_url" "$ST_DIR"; then
                fn_print_success "主程序下载完成。"; download_success=true; break
            else
                fn_print_error "使用镜像 [${mirror_host}] 下载失败！正在切换下一条线路..."; rm -rf "$ST_DIR"
            fi
        done
        if ! $download_success; then fn_print_error "所有线路均下载失败。"; return 1; fi
    fi

    fn_print_header "配置并安装依赖"
    if ! fn_run_npm_install_with_retry; then
        fn_print_error "依赖安装最终失败。"; return 1
    fi
    return 0
}

# [重构] 首次部署流程
main_install() {
    clear; fn_print_header "SillyTavern 首次部署向导"
    
    fn_print_header "1/4: 配置软件源"
    echo -e "${YELLOW}即将开始配置 Termux 软件源...${NC}"
    echo -e "  - 稍后会弹出一个蓝白色窗口，请根据提示操作。"
    echo -e "  - ${GREEN}推荐：${NC}依次选择 ${BOLD}第一项${NC} -> ${BOLD}第三项${NC} (国内最优)。"
    echo -e "\n${CYAN}请按任意键以继续...${NC}"; read -n 1 -s
    termux-change-repo

    fn_print_header "2/4: 安装核心依赖"
    echo -e "${YELLOW}正在更新软件包列表并安装核心依赖...${NC}"
    yes | pkg update && yes | pkg upgrade || fn_terminate_with_prompt "软件源更新失败！"
    yes | pkg install git nodejs-lts rsync zip termux-api coreutils gawk bc || fn_terminate_with_prompt "核心依赖安装失败！"
    fn_print_success "核心依赖安装完毕。"
    
    # [重构] 调用核心安装流程
    if ! fn_core_install_process; then
        fn_terminate_with_prompt "核心安装流程失败，部署中断。"
    fi
    
    fn_print_header "4/4: 设置快捷方式"
    fn_create_shortcut
    echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"; sleep 3; main_start
}

# [重构] 更新流程
main_update_st() {
    clear; fn_print_header "更新 SillyTavern 主程序"
    if [ ! -d "$ST_DIR/.git" ]; then
        fn_print_warning "未找到Git仓库，请先完整部署。"; fn_press_any_key; return
    fi
    cd "$ST_DIR" || fn_terminate_with_prompt "无法进入 SillyTavern 目录: $ST_DIR"

    mapfile -t sorted_mirrors < <(fn_find_fastest_mirror)
    if [ ${#sorted_mirrors[@]} -eq 0 ]; then fn_terminate_with_prompt "所有镜像均测试失败，无法更新。"; fi

    local update_success=false
    for mirror_url in "${sorted_mirrors[@]}"; do
        local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
        fn_print_warning "正在尝试使用镜像 [${mirror_host}] 更新..."
        git remote set-url origin "$mirror_url"
        
        local git_output; git_output=$(git pull origin "$REPO_BRANCH" 2>&1)
        if [ $? -eq 0 ]; then
            fn_print_success "代码更新成功。"
            if fn_run_npm_install_with_retry; then update_success=true; fi
            break
        else
            if echo "$git_output" | grep -qE "overwritten by merge|Please commit|unmerged files"; then
                clear; fn_print_header "检测到更新冲突！"
                fn_print_warning "原因: 你可能修改过酒馆的文件，导致无法自动合并。"
                echo "--- 冲突文件预览 ---"; echo "$git_output" | grep -E "^\s+" | head -n 5; echo "--------------------"
                
                echo -e "\n请选择操作方式：\n  [${GREEN}回车${NC}] ${BOLD}自动备份并重新安装 (推荐)${NC}\n  [1]    ${YELLOW}强制覆盖更新 (危险)${NC}\n  [0]    ${CYAN}放弃更新${NC}"
                read -p "请输入选项: " choice
                case "$choice" in
                    ""|'b'|'B')
                        fn_print_warning "正在将当前版本备份..."
                        local backup_dir="${ST_DIR}_backup_$(date +%Y%m%d%H%M%S)"
                        mv "$ST_DIR" "$backup_dir" || fn_terminate_with_prompt "备份失败！"
                        fn_print_success "备份完成！现在将开始重新下载全新版本..."
                        sleep 2
                        # [重构] 直接调用核心安装流程，而不是完整的 main_install
                        if fn_core_install_process; then fn_print_success "重新安装完成！"; else fn_print_error "重新安装失败。"; fi
                        fn_press_any_key; return
                        ;;
                    '1')
                        fn_print_warning "正在执行强制覆盖 (git reset --hard)..."
                        if git reset --hard "origin/$REPO_BRANCH" && git pull origin "$REPO_BRANCH"; then
                            fn_print_success "强制更新成功。"
                            if fn_run_npm_install_with_retry; then update_success=true; fi
                        else fn_print_error "强制更新失败！"; fi
                        break
                        ;;
                    *) fn_print_warning "已取消更新。"; fn_press_any_key; return ;;
                esac
            else
                fn_print_error "使用镜像 [${mirror_host}] 更新失败！错误: $(echo "$git_output" | tail -n 1)"
                fn_print_error "正在切换下一条线路..."; sleep 1
            fi
        fi
    done

    if $update_success; then fn_print_success "SillyTavern 更新完成！"; else fn_print_warning "更新未成功完成。"; fi
    fn_press_any_key
}

main_update_script() {
    clear; fn_print_header "更新助手脚本"
    echo -e "${YELLOW}正在从 Gitee 下载新版本...${NC}"
    local temp_file; temp_file=$(mktemp)
    if ! curl -L -o "$temp_file" "$SCRIPT_URL"; then
        rm -f "$temp_file"; fn_print_warning "下载失败，请检查网络。"
    elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
        rm -f "$temp_file"; fn_print_success "当前已是最新版本。"
    else
        sed -i 's/\r$//' "$temp_file"; chmod +x "$temp_file"; mv "$temp_file" "$SCRIPT_SELF_PATH"
        rm -f "$UPDATE_FLAG_FILE"; echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"; sleep 2
        exec "$SCRIPT_SELF_PATH" --updated
    fi
    fn_press_any_key
}

check_for_updates_on_start() {
    (
        local temp_file; temp_file=$(mktemp)
        if curl -L -s --connect-timeout 10 -o "$temp_file" "$SCRIPT_URL"; then
            if ! cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then touch "$UPDATE_FLAG_FILE"; else rm -f "$UPDATE_FLAG_FILE"; fi
        fi
        rm -f "$temp_file"
    ) &
}

fn_create_shortcut() {
    local BASHRC_FILE="$HOME/.bashrc"; local ALIAS_CMD="alias st='\"$SCRIPT_SELF_PATH\"'"; local ALIAS_COMMENT="# SillyTavern 助手快捷命令"
    if ! grep -qF "$ALIAS_CMD" "$BASHRC_FILE"; then
        chmod +x "$SCRIPT_SELF_PATH"; echo -e "\n$ALIAS_COMMENT\n$ALIAS_CMD" >> "$BASHRC_FILE"
        fn_print_success "已创建快捷命令 'st'。请重启 Termux 或执行 'source ~/.bashrc' 生效。"
    fi
}

# --- 数据管理部分 (保持稳定) ---
# ... (此部分代码与之前版本相同，逻辑稳定，故折叠以节省篇幅)
run_backup_interactive() {
    clear; fn_print_header "创建自定义备份"; if [ ! -f "$ST_DIR/start.sh" ]; then fn_print_warning "SillyTavern 尚未安装。"; fn_press_any_key; return; fi; cd "$ST_DIR" || fn_terminate_with_prompt "无法进入 SillyTavern 目录: $ST_DIR"; declare -A ALL_PATHS=(["./data"]="用户数据" ["./public/scripts/extensions/third-party"]="前端扩展" ["./plugins"]="后端扩展" ["./config.yaml"]="服务器配置"); local options=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml"); local default_selection=("./data" "./plugins" "./public/scripts/extensions/third-party"); local selection_to_load=(); if [ -f "$CONFIG_FILE" ]; then mapfile -t selection_to_load < "$CONFIG_FILE"; fi; if [ ${#selection_to_load[@]} -eq 0 ]; then selection_to_load=("${default_selection[@]}"); fi; declare -A selection_status; for key in "${options[@]}"; do selection_status["$key"]=false; done; for key in "${selection_to_load[@]}"; do if [[ -v selection_status["$key"] ]]; then selection_status["$key"]=true; fi; done; while true; do clear; fn_print_header "请选择要备份的内容"; echo "输入数字可切换勾选状态。"; for i in "${!options[@]}"; do local key="${options[$i]}"; local description="${ALL_PATHS[$key]}"; if ${selection_status[$key]}; then printf "  [%-2d] ${GREEN}[✓] %s${NC}\n" "$((i+1))" "$key"; else printf "  [%-2d] [ ] %s${NC}\n" "$((i+1))" "$key"; fi; printf "      ${CYAN}(%s)${NC}\n" "$description"; done; echo -e "      ${GREEN}[回车] 开始备份${NC}      ${RED}[0] 取消备份${NC}"; read -p "请操作: " user_choice; case "$user_choice" in "") break ;; 0) fn_print_warning "备份已取消。"; fn_press_any_key; return ;; *) if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "${#options[@]}" ]; then local selected_key="${options[$((user_choice-1))]}"; selection_status[$selected_key]=!${selection_status[$selected_key]}; else fn_print_warning "无效输入。"; sleep 1; fi ;; esac; done; local paths_to_backup=(); for key in "${options[@]}"; do if ${selection_status[$key]}; then if [ -e "$key" ]; then paths_to_backup+=("$key"); else fn_print_warning "路径 '$key' 不存在，已跳过。"; fi; fi; done; if [ ${#paths_to_backup[@]} -eq 0 ]; then fn_print_warning "未选择任何有效项目，备份已取消。"; fn_press_any_key; return; fi; mkdir -p "$BACKUP_ROOT_DIR"; local timestamp; timestamp=$(date +"%Y-%m-%d_%H-%M"); local backup_name="ST_备份_${timestamp}"; local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}.zip"; echo -e "\n${YELLOW}正在压缩文件...${NC}"; echo "包含项目:"; for item in "${paths_to_backup[@]}"; do echo "  - $item"; done; local exclude_params=(-x "*/.git/*" -x "*/_cache/*" -x "*.log" -x "*/backups/*"); if ! zip -rq "$backup_zip_path" "${paths_to_backup[@]}" "${exclude_params[@]}"; then fn_print_error "备份失败！"; fn_press_any_key; return; fi; printf "%s\n" "${paths_to_backup[@]}" > "$CONFIG_FILE"; fn_print_success "备份成功：${backup_name}.zip"; mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-); if [ "${#all_backups[@]}" -gt $BACKUP_LIMIT ]; then fn_print_warning "备份数量超过上限 (${#all_backups[@]}/${BACKUP_LIMIT})，正在清理旧备份..."; local backups_to_delete=("${all_backups[@]:$BACKUP_LIMIT}"); for old_backup in "${backups_to_delete[@]}"; do rm "$old_backup"; echo "  - 已删除: $(basename "$old_backup")"; done; fn_print_success "清理完成。"; fi; fn_press_any_key
}
main_migration_guide() { clear; fn_print_header "数据迁移 / 恢复指南"; echo -e "${YELLOW}请按以下步骤操作：${NC}\n  1. 找到备份压缩包 (位于: ${CYAN}${BACKUP_ROOT_DIR}/${NC})\n  2. 将压缩包复制到 SillyTavern 根目录 (位于: ${CYAN}${ST_DIR}/${NC})\n  3. 在根目录中，将压缩包 '解压到当前目录'。\n  4. 如提示文件已存在，请选择 ${YELLOW}'全部覆盖'${NC}。"; fn_press_any_key; }
run_delete_backup() { clear; fn_print_header "删除旧备份"; mkdir -p "$BACKUP_ROOT_DIR"; mapfile -t backup_files < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-); if [ ${#backup_files[@]} -eq 0 ]; then fn_print_warning "未找到任何备份文件。"; fn_press_any_key; return; fi; echo -e "检测到以下备份 (当前/上限: ${#backup_files[@]}/${BACKUP_LIMIT}):"; for i in "${!backup_files[@]}"; do local file="${backup_files[$i]}"; local size; size=$(du -h "$file" | cut -f1); printf "    [%-2d] %-40s (%s)\n" "$((i+1))" "$(basename "$file")" "$size"; done; read -p "输入要删除的备份编号 (其他键取消): " choice; if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then fn_print_warning "操作已取消。"; fn_press_any_key; return; fi; local chosen_backup="${backup_files[$((choice-1))]}"; read -p "确认删除 '$(basename "$chosen_backup")' 吗？(y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then rm "$chosen_backup"; fn_print_success "备份已删除。"; else fn_print_warning "操作已取消。"; fi; fn_press_any_key; }
main_data_management_menu() { while true; do clear; fn_print_header "SillyTavern 数据管理"; echo -e "      [1] ${GREEN}创建自定义备份${NC}\n      [2] ${CYAN}数据迁移/恢复指南${NC}\n      [3] ${RED}删除旧备份${NC}\n      [0] ${CYAN}返回主菜单${NC}"; read -p "    请输入选项: " choice; case $choice in 1) run_backup_interactive ;; 2) main_migration_guide ;; 3) run_delete_backup ;; 0) break ;; *) fn_print_warning "无效输入。"; sleep 1 ;; esac; done; }
main_open_docs() { clear; fn_print_header "查看帮助文档"; local docs_url="https://stdocs.723123.xyz"; echo -e "文档网址: ${CYAN}${docs_url}${NC}\n"; if fn_check_command "termux-open-url"; then termux-open-url "$docs_url"; fn_print_success "已尝试在浏览器中打开。"; else fn_print_warning "无法自动打开，请先安装 Termux:API。"; fi; fn_press_any_key; }

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

# [增强] 启动时进行全局依赖检查
fn_check_dependencies

if [[ "$1" != "--no-check" && "$1" != "--updated" ]]; then check_for_updates_on_start; fi
if [[ "$1" == "--updated" ]]; then clear; fn_print_success "助手已成功更新至最新版本！"; sleep 2; fi

while true; do
    clear
    echo -e "${CYAN}${BOLD}"; cat << "EOF"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v2.0      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    update_notice=""; if [ -f "$UPDATE_FLAG_FILE" ]; then update_notice=" ${YELLOW}[!] 有更新${NC}"; fi
    echo -e "${NC}\n    选择一个操作来开始：\n"
    echo -e "      [1] ${GREEN}${BOLD}启动 SillyTavern${NC}\n      [2] ${CYAN}${BOLD}数据管理${NC}\n      [3] ${YELLOW}${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [4] 更新 ST 主程序    [5] 更新助手脚本${update_notice}"
    echo -e "      [6] 打开 ST 文件夹     [7] 查看帮助文档\n"
    echo -e "      ${RED}[0] 退出助手${NC}\n"; read -p "    请输入选项数字: " choice
    case $choice in
        1) main_start ;; 2) main_data_management_menu ;; 3) main_install ;; 4) main_update_st ;;
        5) main_update_script ;; 6) if [ -d "$ST_DIR" ]; then termux-open "$ST_DIR"; else fn_print_warning "目录不存在！"; sleep 1.5; fi ;;
        7) main_open_docs ;; 0) echo -e "\n感谢使用，助手已退出。"; rm -f "$UPDATE_FLAG_FILE"; exit 0 ;;
        *) fn_print_warning "无效输入，请重新选择。"; sleep 1.5 ;;
    esac
done
