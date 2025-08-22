#!/data/data/com.termux/files/usr/bin/bash
# =========================================================================
#
#                       SillyTavern 助手 v1.0
#
#   作者: Qingjue
#   小红书号: 826702880
#
#   一个为 Termux 用户量身打造的 SillyTavern 一站式管理工具，
#   提供安装、启动、更新、备份、恢复及便捷设置等全方位功能。
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
SCRIPT_NAME=$(basename "$SCRIPT_SELF_PATH")
# !!! 重要：请将下面的链接替换为您自己托管的脚本原始文件链接 !!!
SCRIPT_URL="https://gitee.com/your-name/repo/raw/main/SillyTavern助手.sh"


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
    echo -e "\n${CYAN}请按任意键返回主菜单...${NC}"
    read -n 1 -s
}
fn_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# =========================================================================
#   核心功能模块
# =========================================================================

# --- 模块一：首次部署 ---
main_install() {
    clear
    fn_print_header "SillyTavern 首次部署向导"

    echo "正在检验 Termux 环境..."
    [[ "$PREFIX" != "/data/data/com.termux/files/usr" ]] && fn_print_error_exit "非标准 Termux 环境。"
    fn_print_success "环境检验通过。"

    fn_print_header "步骤 1/5: 配置与更新软件源"
    echo "此步骤将使用官方推荐方式，自动选择最快的镜像源。"
    fn_print_warning "接下来，请根据提示【按两次回车键】来完成设置。"
    sleep 3
    pkg update -y && pkg upgrade -y
    fn_print_success "软件源配置与系统更新完成。"

    fn_print_header "步骤 2/5: 安装核心依赖"
    local packages="git nodejs-lts rsync zip termux-api"
    for pkg_name in $packages; do
        if fn_check_command $pkg_name; then
            fn_print_warning "依赖 '$pkg_name' 已安装。"
        else
            echo "正在安装 '$pkg_name'..."
            pkg install $pkg_name -y || fn_print_error_exit "'$pkg_name' 安装失败。"
            fn_print_success "'$pkg_name' 安装成功。"
        fi
    done
    fn_print_success "所有核心依赖安装完毕。"

    fn_print_header "步骤 3/5: 下载 SillyTavern 主程序"
    if [ -d "$ST_DIR" ]; then
        fn_print_warning "SillyTavern 目录已存在，跳过下载。"
    else
        echo "正在从国内镜像下载主程序 (${REPO_BRANCH} 分支)..."
        git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$ST_DIR" || fn_print_error_exit "主程序下载失败。"
        fn_print_success "SillyTavern 下载完成。"
    fi

    fn_print_header "步骤 4/5: 配置 NPM 环境"
    cd "$ST_DIR" || fn_print_error_exit "无法进入目录 '$ST_DIR'。"
    echo "正在配置 NPM 国内镜像源以加速..."
    npm config set registry https://registry.npmmirror.com
    fn_print_success "NPM 配置完成。"

    fn_print_header "步骤 5/5: 设置自动运行"
    main_manage_autostart "set_default"
    
    echo -e "\n${GREEN}${BOLD}========================================="
    echo -e "  恭喜！SillyTavern 已完成全部署。"
    echo -e "  下次打开 Termux 将自动运行本助手。"
    echo -e "=========================================${NC}"
    fn_press_any_key
}

# --- 模块二：启动 SillyTavern ---
main_start() {
    clear
    fn_print_header "启动 SillyTavern"
    [ ! -f "$ST_DIR/start.sh" ] && fn_print_warning "未找到启动脚本，请先执行首次部署。" && fn_press_any_key && return
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"
    
    npm config set registry https://registry.npmmirror.com
    echo "即将启动 SillyTavern，在 Termux 中按 ${BOLD}Ctrl + C${NC} 可随时停止。"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

# --- 模块三：更新 SillyTavern ---
main_update_st() {
    clear
    fn_print_header "更新 SillyTavern"
    [ ! -d "$ST_DIR/.git" ] && fn_print_warning "未找到 Git 仓库，无法更新。" && fn_press_any_key && return
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"
    
    echo "正在拉取最新版本..."
    git pull origin "$REPO_BRANCH"
    if [ $? -ne 0 ]; then
        fn_print_warning "代码更新失败，可能存在冲突或网络问题。"
    else
        fn_print_success "代码已更新至最新。"
        echo "正在同步更新依赖包..."
        npm install --no-audit --no-fund --omit=dev
        fn_print_success "依赖包更新完成。"
    fi
    fn_press_any_key
}

# --- 模块四：备份与恢复 ---
run_backup() {
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"
    fn_print_header "执行数据备份"

    local paths_to_backup=("./data" "./plugins" "./public/scripts/extensions/third-party")
    mkdir -p "$BACKUP_ROOT_DIR"
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup_name="SillyTavern_备份_${timestamp}"
    local backup_dir="${BACKUP_ROOT_DIR}/${backup_name}"
    
    echo "将备份以下内容到 '$BACKUP_ROOT_DIR' 文件夹："
    for path in "${paths_to_backup[@]}"; do echo "  - $path"; done
    echo
    read -p "是否开始备份？ (输入 'y' 继续): " confirm
    [[ ! "$confirm" =~ ^[yY](es)?$ ]] && echo "操作已取消。" && return

    echo "步骤 1/3: 复制文件..."
    mkdir -p "$backup_dir"
    rsync -aR --exclude='_cache' --exclude='.git' --exclude='*.log' "${paths_to_backup[@]}" "${backup_dir}/" || { echo "${RED}文件复制失败！${NC}"; return; }
    fn_print_success "文件复制成功。"

    echo "步骤 2/3: 压缩文件..."
    (cd "$backup_dir" && zip -rq "../${backup_name}.zip" .) || { echo "${RED}压缩失败！${NC}"; return; }
    fn_print_success "压缩完成！"

    echo "步骤 3/3: 清理临时文件..."
    rm -rf "$backup_dir"
    fn_print_success "清理完成。"

    echo -e "\n${GREEN}备份已成功创建：${backup_name}.zip${NC}"
}

run_restore() {
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录。"
    fn_print_header "从备份恢复数据"
    
    [ ! -d "$BACKUP_ROOT_DIR" ] && fn_print_warning "未找到备份目录 '$BACKUP_ROOT_DIR'。" && return
    
    local backups=("$BACKUP_ROOT_DIR"/*.zip)
    if [ ! -e "${backups[0]}" ]; then
        fn_print_warning "备份目录中没有任何 .zip 备份文件。"
        return
    fi

    echo "检测到以下备份文件："
    local i=1
    for backup in "${backups[@]}"; do
        echo "  [${i}] $(basename "$backup")"
        i=$((i+1))
    done
    
    read -p "请输入要恢复的备份编号 (输入其他内容取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        echo "输入无效，操作已取消。"
        return
    fi
    
    local chosen_backup="${backups[$((choice-1))]}"
    echo
    echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!! 严重警告 !!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${YELLOW}此操作将使用 '$(basename "$chosen_backup")' 的内容【覆盖】当前 SillyTavern 的数据。"
    echo -e "${YELLOW}这个过程是【不可逆】的！请确保您了解后果。${NC}"
    read -p "输入 'yes' 确认恢复，输入其他内容取消: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已取消。"
        return
    fi
    
    local temp_restore_dir="/tmp/st_restore_$$"
    mkdir -p "$temp_restore_dir"
    
    echo "步骤 1/2: 解压备份文件..."
    unzip -q "$chosen_backup" -d "$temp_restore_dir" || { echo "${RED}解压失败！${NC}"; rm -rf "$temp_restore_dir"; return; }
    fn_print_success "解压完成。"

    echo "步骤 2/2: 同步文件到主目录..."
    rsync -a "$temp_restore_dir/" "$ST_DIR/" || { echo "${RED}文件同步失败！${NC}"; rm -rf "$temp_restore_dir"; return; }
    rm -rf "$temp_restore_dir"
    fn_print_success "数据恢复成功！"
}

main_backup_restore_menu() {
    while true; do
        clear
        fn_print_header "SillyTavern 数据管理"
        echo "      [1] ${GREEN}备份当前数据${NC}"
        echo "      [2] ${YELLOW}从备份恢复数据${NC}"
        echo "      [0] ${RED}返回主菜单${NC}"
        read -p "    请输入选项: " choice

        case $choice in
            1) run_backup; fn_press_any_key ;;
            2) run_restore; fn_press_any_key ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# --- 模块五：管理自动启动 ---
main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"
    local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""
    
    if grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE"; then
        is_set=true
    else
        is_set=false
    fi
    
    # 静默设置模式，用于首次部署
    if [[ "$1" == "set_default" ]]; then
        if ! $is_set; then
            echo -e "\n# SillyTavern 助手自动启动项\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已为您设置：打开 Termux 时自动运行本助手。"
        else
            fn_print_warning "检测到已设置自动运行，无需重复添加。"
        fi
        return
    fi

    # 手动管理模式
    clear
    fn_print_header "管理 Termux 启动时自动运行"
    if $is_set; then
        echo "当前状态: ${GREEN}已启用${NC}"
        read -p "是否要取消自动运行？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            # 使用 sed 删除相关行
            sed -i "/# SillyTavern 助手自动启动项/d" "$BASHRC_FILE"
            sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"
            fn_print_success "已取消自动运行。"
        else
            echo "操作已取消。"
        fi
    else
        echo "当前状态: ${RED}未启用${NC}"
        read -p "是否要设置自动运行？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            echo -e "\n# SillyTavern 助手自动启动项\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已成功设置自动运行。"
        else
            echo "操作已取消。"
        fi
    fi
    fn_press_any_key
}


# --- 模块六：助手自我更新 ---
main_update_script() {
    clear
    fn_print_header "检查并更新助手脚本"
    echo "正在从以下地址检查新版本："
    echo "$SCRIPT_URL"
    echo
    
    local temp_file="${SCRIPT_SELF_PATH}.tmp"
    curl -L -o "$temp_file" "$SCRIPT_URL"
    
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
        fn_print_warning "下载新版本失败，请检查网络或URL配置。"
        rm -f "$temp_file"
        fn_press_any_key
        return
    fi
    
    # 对比新旧文件，如果没变化就不更新
    if cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
        fn_print_success "您当前已是最新版本，无需更新。"
        rm -f "$temp_file"
    else
        mv "$temp_file" "$SCRIPT_SELF_PATH"
        chmod +x "$SCRIPT_SELF_PATH"
        echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"
        sleep 2
        # 使用 exec 无缝交接给新版脚本
        exec "$SCRIPT_SELF_PATH" --updated
    fi
    fn_press_any_key
}

# --- 模块七：打开在线文档 ---
main_open_docs() {
    clear
    fn_print_header "打开在线帮助文档"
    if fn_check_command "termux-open-url"; then
        echo "即将调用浏览器打开文档网站..."
        termux-open-url "https://stdocs.723123.xyz"
        sleep 2
    else
        fn_print_warning "未找到 'termux-open-url' 命令。"
        echo "此功能需要 Termux:API 支持。"
        echo "请先从 F-Droid 应用商店安装【Termux:API】应用，"
        echo "然后在本脚本的首次部署菜单中，确保 'termux-api' 包已安装。"
    fi
    fn_press_any_key
}


# =========================================================================
#   主菜单与脚本入口
# =========================================================================

# 处理 --updated 参数，用于无缝更新后的提示
if [[ "$1" == "--updated" ]]; then
    clear
    fn_print_success "助手已成功更新至最新版本！"
    sleep 2
fi

while true; do
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
    ╔═════════════════════════════════════════╗
    ║                                         ║
    ║            SillyTavern 助手 v1.0          ║
    ║         作者: Qingjue | 小红书: 826702880 ║
    ║                                         ║
    ╚═════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo "    请选择操作："
    echo
    echo -e "      ${GREEN}[1]${NC} ${BOLD}首次部署 SillyTavern${NC} (环境、程序、自启一步到位)"
    echo -e "      ${CYAN}[2]${NC} ${BOLD}启动 SillyTavern${NC}"
    echo -e "      ${YELLOW}[3]${NC} ${BOLD}更新 SillyTavern 主程序${NC}"
    echo
    echo -e "      ${CYAN}[4]${NC} ${BOLD}备份 / 恢复 数据${NC}"
    echo -e "      ${CYAN}[5]${NC} ${BOLD}管理助手自动启动${NC}"
    echo -e "      ${YELLOW}[6]${NC} ${BOLD}检查并更新助手脚本${NC}"
    echo -e "      ${CYAN}[7]${NC} ${BOLD}打开在线帮助文档${NC}"
    echo
    echo -e "      ${RED}[0]${NC} ${BOLD}退出助手${NC}"
    echo
    read -p "    请输入选项数字: " choice

    case $choice in
        1) main_install ;;
        2) main_start ;;
        3) main_update_st ;;
        4) main_backup_restore_menu ;;
        5) main_manage_autostart ;;
        6) main_update_script ;;
        7) main_open_docs ;;
        0) echo -e "\n感谢使用，助手已退出。"; exit 0 ;;
        *) echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 1.5 ;;
    esac
done
