#!/data/data/com.termux/files/usr/bin/bash
# =========================================================================
#
#                       SillyTavern 助手 v1.6
#
#   作者: Qingjue
#   小红书号: 826702880
#
#   v1.6 更新日志:
#   - 新增: 备份管理功能，自动清理旧备份并限制最多10个。
#   - 新增: 手动删除备份文件的功能。
#   - 新增: 耗时操作的动态加载动画，提升用户体验。
#   - 优化: 恢复/删除列表会显示文件大小并按时间排序。
#   - 优化: 整体UI美化，重制标题框，移除易误导的提示。
#
# =========================================================================

# --- 色彩定义 ---
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# --- 核心配置 ---
ST_DIR="$HOME/SillyTavern"
REPO_URL="https://git.723123.xyz/gh/SillyTavern/SillyTavern.git"
REPO_BRANCH="release"
BACKUP_ROOT_DIR="$ST_DIR/_我的备份"
BACKUP_LIMIT=10
SCRIPT_SELF_PATH=$(readlink -f "$0")
SCRIPT_URL="https://gitee.com/canaan723/st-assistant/raw/master/ad-st.sh"

# =========================================================================
#   辅助函数库
# =========================================================================

fn_print_header() { echo -e "\n${CYAN}═══ ${BOLD}$1 ${NC}═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ ${BOLD}$1${NC}"; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_error_exit() {
    echo -e "\n${RED}✗ ${BOLD}$1${NC}\n${RED}流程已终止。${NC}"
    exit 1
}
fn_press_any_key() {
    echo -e "\n${CYAN}请按任意键返回...${NC}"
    read -n 1 -s
}
fn_check_command() { command -v "$1" >/dev/null 2>&1; }

# 动态加载动画
_spinner() {
    local chars="/-\|"
    while :; do
        for (( i=0; i<${#chars}; i++ )); do
            sleep 0.1
            echo -en "${GREEN}${chars:$i:1}\r${NC}"
        done
    done
}
fn_spinner_start() {
    echo -n "$1 "
    _spinner &
    SPINNER_PID=$!
    # 隐藏光标
    tput civis
}
fn_spinner_stop() {
    kill $SPINNER_PID
    wait $SPINNER_PID 2>/dev/null
    # 显示光标
    tput cnorm
    if [ "$1" -eq 0 ]; then
        echo -e "\r${GREEN}✓ 操作完成${NC}  "
    else
        echo -e "\r${RED}✗ 操作失败${NC}  "
    fi
}

# =========================================================================
#   核心功能模块
# =========================================================================

# --- 模块：启动 SillyTavern ---
main_start() {
    clear
    fn_print_header "启动 SillyTavern"
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "SillyTavern 尚未安装，请先部署。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"
    
    echo -e "正在配置NPM镜像并准备启动环境..."
    npm config set registry https://registry.npmmirror.com &>/dev/null
    echo -e "${YELLOW}环境准备就绪，正在启动SillyTavern服务...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

# --- 模块：备份、恢复、删除 ---
fn_list_backups() {
    # $1: 全局数组名，用于返回文件列表
    # $2: 模式 (restore/delete)
    local -n files_ref=$1
    local mode=$2
    
    fn_print_header "从备份${mode}"
    mkdir -p "$BACKUP_ROOT_DIR"
    
    # 使用 find 和 sort 来可靠地处理文件名和排序
    mapfile -t files_ref < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)

    if [ ${#files_ref[@]} -eq 0 ]; then
        fn_print_warning "未找到任何备份文件。"
        return 1
    fi

    echo -e "检测到以下备份 (从新到旧):"
    for i in "${!files_ref[@]}"; do
        local file_path="${files_ref[$i]}"
        local filename
        filename=$(basename "$file_path")
        local filesize
        filesize=$(du -h "$file_path" | awk '{print $1}')
        printf "  [%2d] %s (%s)\n" "$((i+1))" "$filename" "$filesize"
    done
    return 0
}

run_backup() {
    clear
    fn_print_header "执行数据备份"
    if [ ! -d "$ST_DIR" ]; then
        fn_print_warning "SillyTavern 尚未安装，无法备份。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || return

    local paths_to_backup=("./data" "./plugins" "./public/scripts/extensions/third-party")
    mkdir -p "$BACKUP_ROOT_DIR"
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_备份_${timestamp}"
    local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}.zip"
    
    echo -e "\n${YELLOW}即将开始备份...${NC}"
    
    fn_spinner_start "正在压缩文件..."
    zip -rq "$backup_zip_path" "${paths_to_backup[@]}" -x "*_cache/*" "*.git*" "*.log" &>/dev/null
    local zip_status=$?
    fn_spinner_stop $zip_status
    
    if [ $zip_status -ne 0 ]; then
        fn_print_warning "备份失败！"
        fn_press_any_key
        return
    fi

    fn_print_success "备份成功：${backup_name}.zip"

    # 自动清理旧备份
    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    if [ "${#all_backups[@]}" -gt $BACKUP_LIMIT ]; then
        echo -e "${YELLOW}备份数量超过 ${BACKUP_LIMIT} 个，正在清理旧备份...${NC}"
        local backups_to_delete=("${all_backups[@]:$BACKUP_LIMIT}")
        for old_backup in "${backups_to_delete[@]}"; do
            rm "$old_backup"
            echo -e "  - 已删除: $(basename "$old_backup")"
        done
        fn_print_success "清理完成。"
    fi
    fn_press_any_key
}

run_restore() {
    clear
    local backup_files
    fn_list_backups backup_files "恢复" || { fn_press_any_key; return; }
    
    read -p "输入编号恢复 (其他键取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        echo -e "操作已取消。"
        fn_press_any_key
        return
    fi
    
    local chosen_backup="${backup_files[$((choice-1))]}"
    echo
    echo -e "${RED}${BOLD}!!! 严重警告 !!!${NC}"
    echo -e "${YELLOW}此操作将【覆盖】当前数据，且【不可逆】！${NC}"
    read -p "输入 'yes' 确认恢复: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已取消。"
        fn_press_any_key
        return
    fi
    
    local temp_restore_dir="$TMPDIR/st_restore_$$"
    mkdir -p "$temp_restore_dir"
    
    fn_spinner_start "正在解压并同步文件..."
    unzip -qo "$chosen_backup" -d "$temp_restore_dir" && rsync -a --delete "$temp_restore_dir/" "$ST_DIR/" &>/dev/null
    local restore_status=$?
    fn_spinner_stop $restore_status
    rm -rf "$temp_restore_dir"

    if [ $restore_status -eq 0 ]; then
        fn_print_success "数据恢复成功！"
    fi
    fn_press_any_key
}

run_delete_backup() {
    clear
    local backup_files
    fn_list_backups backup_files "删除" || { fn_press_any_key; return; }

    read -p "输入要删除的备份编号 (其他键取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        echo -e "操作已取消。"
        fn_press_any_key
        return
    fi

    local chosen_backup="${backup_files[$((choice-1))]}"
    echo
    read -p "确认删除 '$(basename "$chosen_backup")' 吗？(y/n): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        rm "$chosen_backup"
        fn_print_success "备份已删除。"
    else
        echo "操作已取消。"
    fi
    fn_press_any_key
}

main_backup_restore_menu() {
    while true; do
        clear
        fn_print_header "SillyTavern 数据管理"
        echo -e "      [1] ${GREEN}创建新备份${NC} (最多保留10个)"
        echo -e "      [2] ${YELLOW}从备份恢复数据${NC}"
        echo -e "      [3] ${RED}删除旧备份${NC}"
        echo -e "      [0] ${CYAN}返回主菜单${NC}"
        read -p "    请输入选项: " choice

        case $choice in
            1) run_backup ;;
            2) run_restore ;;
            3) run_delete_backup ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# --- 模块：首次部署 ---
main_install() {
    clear
    fn_print_header "SillyTavern 首次部署向导"

    fn_print_header "1/5: 配置软件源"
    fn_print_warning "接下来会弹出一个界面，按两次回车或OK确认即可。"
    read -n 1 -s -r -p "  准备好后，请按任意键继续..."
    echo
    
    termux-change-repo
    fn_spinner_start "正在更新软件包列表..."
    yes | pkg update &>/dev/null && yes | pkg upgrade &>/dev/null
    fn_spinner_stop $?

    fn_print_header "2/5: 安装核心依赖"
    local packages="git nodejs-lts rsync zip termux-api"
    yes | pkg install ${packages} &>/dev/null
    fn_print_success "核心依赖安装完毕。"

    fn_print_header "3/5: 下载 ST 主程序"
    if [ -d "$ST_DIR" ]; then
        fn_print_warning "目录已存在，跳过下载。"
    else
        fn_spinner_start "正在从镜像下载主程序 (${REPO_BRANCH} 分支)..."
        git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$ST_DIR" &>/dev/null
        fn_spinner_stop $?
    fi
    
    fn_print_header "4/5: 配置 NPM 环境"
    if [ -d "$ST_DIR" ]; then
        cd "$ST_DIR" || fn_print_error_exit "无法进入 '$ST_DIR'。"
        fn_spinner_start "正在配置NPM国内镜像..."
        npm config set registry https://registry.npmmirror.com &>/dev/null
        fn_spinner_stop $?
    else
        fn_print_warning "SillyTavern 目录不存在，跳过此步。"
    fi
    
    fn_print_header "5/5: 设置自动运行"
    main_manage_autostart "set_default"
    
    echo -e "\n${GREEN}${BOLD}==================================="
    echo -e "  恭喜！SillyTavern 已部署完成。"
    echo -e "  即将为您进行首次启动..."
    echo -e "===================================${NC}"
    sleep 3
    main_start
}

# --- 模块：更新 SillyTavern ---
main_update_st() {
    clear
    fn_print_header "更新 SillyTavern 主程序"
    if [ ! -d "$ST_DIR/.git" ]; then
        fn_print_warning "未找到Git仓库，请先完整部署。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || return
    
    fn_spinner_start "正在拉取最新代码..."
    git pull origin "$REPO_BRANCH" &>/dev/null
    local pull_status=$?
    fn_spinner_stop $pull_status

    if [ $pull_status -eq 0 ]; then
        fn_spinner_start "正在同步依赖包..."
        npm install --no-audit --no-fund --omit=dev &>/dev/null
        fn_spinner_stop $?
    else
        fn_print_warning "代码更新失败，可能存在冲突。"
    fi
    fn_press_any_key
}

# --- 模块：助手自我更新 ---
main_update_script() {
    clear
    fn_print_header "更新助手脚本"
    fn_spinner_start "正在从 Gitee 检查新版本..."
    
    local temp_file="${SCRIPT_SELF_PATH}.tmp"
    curl -s -L -o "$temp_file" "$SCRIPT_URL"
    local curl_status=$?
    fn_spinner_stop $curl_status

    if [ $curl_status -ne 0 ] || [ ! -s "$temp_file" ]; then
        fn_print_warning "下载失败，请检查网络。"
        rm -f "$temp_file"
    elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
        fn_print_success "当前已是最新版本。"
        rm -f "$temp_file"
    else
        mv "$temp_file" "$SCRIPT_SELF_PATH"
        chmod +x "$SCRIPT_SELF_PATH"
        echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"
        sleep 2
        exec "$SCRIPT_SELF_PATH" --updated
    fi
    fn_press_any_key
}

# --- 其它模块 (自启, 文档) ---
main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"
    local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""
    grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true || is_set=false
    
    if [[ "$1" == "set_default" ]]; then
        if ! $is_set; then
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已设置 Termux 启动时自动运行本助手。"
        fi
        return
    fi

    clear
    fn_print_header "管理助手自启"
    if $is_set; then
        echo -e "当前状态: ${GREEN}已启用${NC}"
        read -p "是否取消自启？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            sed -i "/# SillyTavern 助手/d" "$BASHRC_FILE"
            sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"
            fn_print_success "已取消自启。"
        fi
    else
        echo -e "当前状态: ${RED}未启用${NC}"
        read -p "是否设置自启？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已成功设置自启。"
        fi
    fi
    fn_press_any_key
}
main_open_docs() {
    clear
    fn_print_header "打开在线帮助文档"
    if fn_check_command "termux-open-url"; then
        termux-open-url "https://stdocs.723123.xyz"
        fn_print_success "已调用浏览器打开文档。"
    else
        fn_print_warning "命令 'termux-open-url' 不存在。"
        echo -e "请先安装【Termux:API】应用及 'pkg install termux-api'。"
    fi
    fn_press_any_key
}

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

if [[ "$1" == "--updated" ]]; then
    clear
    fn_print_success "助手已成功更新至最新版本！"
    sleep 2
fi

while true; do
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
    ╔═════════════════════════════════╗
    ║        SillyTavern 助手         ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "    选择一个操作来开始："
    echo
    echo -e "      ${GREEN}[1]${NC} ${BOLD}启动 SillyTavern${NC}"
    echo -e "      ${CYAN}[2]${NC} ${BOLD}数据管理 (备份/恢复)${NC}"
    echo -e "      ${YELLOW}[3]${NC} ${BOLD}首次部署 (全新安装)${NC}"
    echo
    echo -e "      [4] 更新 ST 主程序    [5] 更新助手脚本"
    echo -e "      [6] 管理助手自启      [7] 查看在线文档"
    echo
    echo -e "      ${RED}[0] 退出助手${NC}"
    echo
    read -p "    请输入选项数字: " choice

    case $choice in
        1) main_start ;;
        2) main_backup_restore_menu ;;
        3) main_install ;;
        4) main_update_st ;;
        5) main_update_script ;;
        6) main_manage_autostart ;;
        7) main_open_docs ;;
        0) echo -e "\n感谢使用，助手已退出。"; exit 0 ;;
        *) echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 1.5 ;;
    esac
done
