#!/data/data/com.termux/files/usr/bin/bash
# =========================================================================
#
#                       SillyTavern 助手 v1.5
#
#   作者: Qingjue
#   小红书号: 826702880
#
#   v1.5 更新日志:
#   - 修复: 重新校准顶部标题框，解决UI显示错位问题。
#   - 优化: 镜像源配置前的确认提示改为“按任意键”，避免操作混淆。
#
# =========================================================================

# --- 色彩定义 ---
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # 重置颜色

# --- 核心配置 ---
ST_DIR="$HOME/SillyTavern"
REPO_URL="https://git.723123.xyz/gh/SillyTavern/SillyTavern.git"
REPO_BRANCH="release"
BACKUP_ROOT_DIR="$ST_DIR/_我的备份"
SCRIPT_SELF_PATH=$(readlink -f "$0")
# 脚本URL，用于自我更新
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
fn_check_command() {
    command -v "$1" >/dev/null 2>&1
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
    
    npm config set registry https://registry.npmmirror.com
    echo -e "即将启动 SillyTavern..."
    echo -e "在 Termux 中按 ${BOLD}Ctrl + C${NC} 可随时停止。"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

# --- 模块：备份与恢复 ---
run_backup() {
    fn_print_header "执行数据备份"
    if [ ! -d "$ST_DIR" ]; then
        fn_print_warning "SillyTavern 尚未安装，无法备份。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || return

    local paths_to_backup=("./data" "./plugins" "./public/scripts/extensions/third-party")
    mkdir -p "$BACKUP_ROOT_DIR"
    local timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_备份_${timestamp}"
    local backup_dir="${BACKUP_ROOT_DIR}/${backup_name}"
    
    echo -e "将备份以下内容到 '$BACKUP_ROOT_DIR'："
    for path in "${paths_to_backup[@]}"; do echo -e "  - $path"; done
    echo
    read -p "开始备份吗？ (输入 'y' 继续): " confirm
    [[ ! "$confirm" =~ ^[yY](es)?$ ]] && echo "操作已取消。" && return

    echo -e "1/3: 复制文件..."
    mkdir -p "$backup_dir"
    rsync -aR --exclude='_cache' --exclude='.git' --exclude='*.log' "${paths_to_backup[@]}" "${backup_dir}/" || { echo -e "${RED}复制失败！${NC}"; return; }
    fn_print_success "复制成功。"

    echo -e "2/3: 压缩文件..."
    (cd "$backup_dir" && zip -rq "../${backup_name}.zip" .) || { echo -e "${RED}压缩失败！${NC}"; return; }
    fn_print_success "压缩完成！"

    echo -e "3/3: 清理临时文件..."
    rm -rf "$backup_dir"
    fn_print_success "清理完成。"

    echo -e "\n${GREEN}备份成功：${backup_name}.zip${NC}"
    fn_press_any_key
}
run_restore() {
    fn_print_header "从备份恢复数据"
    if [ ! -d "$ST_DIR" ]; then
        fn_print_warning "SillyTavern 尚未安装，无法恢复。"
        fn_press_any_key
        return
    fi
    
    local backups=("$BACKUP_ROOT_DIR"/*.zip)
    if [ ! -d "$BACKUP_ROOT_DIR" ] || [ ! -e "${backups[0]}" ]; then
        fn_print_warning "未找到任何备份文件。"
        fn_press_any_key
        return
    fi

    echo -e "检测到以下备份："
    local i=1
    for backup in "${backups[@]}"; do
        echo -e "  [${i}] $(basename "$backup")"
        i=$((i+1))
    done
    
    read -p "输入编号恢复 (其他键取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        echo -e "操作已取消。"
        fn_press_any_key
        return
    fi
    
    local chosen_backup="${backups[$((choice-1))]}"
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
    
    echo -e "1/2: 解压备份..."
    unzip -q "$chosen_backup" -d "$temp_restore_dir" || { echo -e "${RED}解压失败！${NC}"; rm -rf "$temp_restore_dir"; fn_press_any_key; return; }
    fn_print_success "解压完成。"

    echo -e "2/2: 同步文件..."
    rsync -a "$temp_restore_dir/" "$ST_DIR/" || { echo -e "${RED}同步失败！${NC}"; rm -rf "$temp_restore_dir"; fn_press_any_key; return; }
    rm -rf "$temp_restore_dir"
    fn_print_success "数据恢复成功！"
    fn_press_any_key
}
main_backup_restore_menu() {
    while true; do
        clear
        fn_print_header "SillyTavern 数据管理"
        echo -e "      [1] ${GREEN}备份当前数据${NC}"
        echo -e "      [2] ${YELLOW}从备份恢复数据${NC}"
        echo -e "      [0] ${RED}返回主菜单${NC}"
        read -p "    请输入选项: " choice

        case $choice in
            1) run_backup ;;
            2) run_restore ;;
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
    echo -e "即将打开Termux官方的镜像源选择器。"
    fn_print_warning "接下来会弹出一个界面，按两次回车或OK确认即可。"
    read -n 1 -s -r -p "  准备好后，请按任意键继续..."
    echo
    
    termux-change-repo
    yes | pkg update && yes | pkg upgrade
    fn_print_success "软件源配置完成。"

    fn_print_header "2/5: 安装核心依赖"
    local packages="git nodejs-lts rsync zip termux-api"
    for pkg_name in $packages; do
        if fn_check_command $pkg_name; then
            fn_print_warning "'$pkg_name' 已安装。"
        else
            echo -e "正在安装 '$pkg_name'..."
            yes | pkg install $pkg_name || fn_print_error_exit "'$pkg_name' 安装失败。"
        fi
    done
    fn_print_success "核心依赖安装完毕。"

    fn_print_header "3/5: 下载 ST 主程序"
    if [ -d "$ST_DIR" ]; then
        fn_print_warning "目录已存在，跳过下载。"
    else
        echo -e "正从镜像下载主程序 (${REPO_BRANCH} 分支)..."
        git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$ST_DIR" || fn_print_error_exit "下载失败。"
        fn_print_success "主程序下载完成。"
    fi
    
    fn_print_header "4/5: 配置 NPM 环境"
    if [ ! -d "$ST_DIR" ]; then
        fn_print_warning "SillyTavern 目录不存在，跳过此步。"
    else
        cd "$ST_DIR" || fn_print_error_exit "无法进入 '$ST_DIR'。"
        echo -e "正在配置 NPM 国内镜像..."
        npm config set registry https://registry.npmmirror.com
        fn_print_success "NPM 配置完成。"
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
    
    echo -e "正在拉取最新代码..."
    git pull origin "$REPO_BRANCH"
    if [ $? -eq 0 ]; then
        fn_print_success "代码更新成功。"
        echo -e "正在同步依赖包..."
        npm install --no-audit --no-fund --omit=dev
        fn_print_success "依赖包更新完成。"
    else
        fn_print_warning "代码更新失败，可能存在冲突。"
    fi
    fn_press_any_key
}

# --- 模块：助手自我更新 ---
main_update_script() {
    clear
    fn_print_header "更新助手脚本"
    echo -e "正在从 Gitee 检查新版本..."
    
    local temp_file="${SCRIPT_SELF_PATH}.tmp"
    curl -L -o "$temp_file" "$SCRIPT_URL"
    
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
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

# --- 模块：管理自动启动 ---
main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"
    local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""
    
    grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true || is_set=false
    
    if [[ "$1" == "set_default" ]]; then
        if ! $is_set; then
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已设置 Termux 启动时自动运行本助手。"
        else
            fn_print_warning "检测到已设置自启。"
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
        else
            echo "操作已取消。"
        fi
    else
        echo -e "当前状态: ${RED}未启用${NC}"
        read -p "是否设置自启？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已成功设置自启。"
        else
            echo "操作已取消。"
        fi
    fi
    fn_press_any_key
}

# --- 模块：打开在线文档 ---
main_open_docs() {
    clear
    fn_print_header "打开在线帮助文档"
    if fn_check_command "termux-open-url"; then
        echo -e "正在调用浏览器打开文档..."
        termux-open-url "https://stdocs.723123.xyz"
        sleep 1
    else
        fn_print_warning "命令 'termux-open-url' 不存在。"
        echo -e "请先安装【Termux:API】应用，"
        echo -e "并执行 'pkg install termux-api'。"
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
    ╔═════════════════════════════╗
    ║        SillyTavern 助手        ║
    ║  by Qingjue | XHS:826702880 ║
    ╚═════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "    请选择操作："
    echo
    echo -e "      ${GREEN}[1]${NC} ${BOLD}启动 SillyTavern${NC}"
    echo -e "      ${CYAN}[2]${NC} ${BOLD}备份 / 恢复数据${NC}"
    echo -e "      ${YELLOW}[3]${NC} ${BOLD}首次部署 (全新安装)${NC}"
    echo
    echo -e "      ${CYAN}[4]${NC} ${BOLD}更新 ST 主程序${NC}"
    echo -e "      ${CYAN}[5]${NC} ${BOLD}更新助手脚本${NC}"
    echo -e "      ${CYAN}[6]${NC} ${BOLD}管理助手自启${NC}"
    echo -e "      ${CYAN}[7]${NC} ${BOLD}查看在线文档${NC}"
    echo
    echo -e "      ${RED}[0]${NC} ${BOLD}退出助手${NC}"
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
