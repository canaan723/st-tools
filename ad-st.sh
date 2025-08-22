#!/data/data/com.termux/files/usr/bin/bash
# =========================================================================
#
#                       SillyTavern 助手 v2.1
#
#   作者: Qingjue
#   小红书号: 826702880
#
#   v2.1 更新日志:
#   - 核心: [重大修正] 根据用户反馈，彻底重构了交互式备份功能。
#   - 精简: 备份选项精简为4个核心项目(data, plugins, extensions, config)。
#   - 修正: 默认备份项排除了 'config.yaml'，避免覆盖网络配置。
#   - 修复: 解决了交互菜单中只能取消勾选、无法重新勾选的BUG。
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
    npm config set registry https://registry.npmmirror.com
    echo -e "${YELLOW}环境准备就绪，正在启动SillyTavern服务...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

# --- 模块：数据管理 ---

# [v2.1] 交互式备份 (重构版)
run_backup_interactive() {
    clear
    fn_print_header "创建自定义备份"
    if [ ! -d "$ST_DIR" ]; then
        fn_print_warning "SillyTavern 尚未安装，无法备份。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || return

    # [修正] 精简为4个核心备份项
    declare -A ALL_PATHS=(
        ["./data"]="用户数据 (聊天/角色/设置)"
        ["./plugins"]="后端扩展"
        ["./public/scripts/extensions/third-party"]="前端扩展"
        ["./config.yaml"]="服务器配置 (网络/安全)"
    )
    # [修正] 默认不勾选 config.yaml
    local default_selection=("./data" "./plugins" "./public/scripts/extensions/third-party")
    
    declare -A selection_status
    # 初始化所有为 false
    for key in "${!ALL_PATHS[@]}"; do
        selection_status["$key"]=false
    done
    # 设置默认勾选项为 true
    for key in "${default_selection[@]}"; do
        selection_status["$key"]=true
    done

    while true; do
        clear
        fn_print_header "请选择要备份的内容"
        echo "输入数字可切换勾选状态。"
        
        # 将key存入数组以保证顺序
        local options=()
        options+=("./data")
        options+=("./plugins")
        options+=("./public/scripts/extensions/third-party")
        options+=("./config.yaml")

        for i in "${!options[@]}"; do
            local key="${options[$i]}"
            local description="${ALL_PATHS[$key]}"
            if ${selection_status[$key]}; then
                printf "  [%-2d] ${GREEN}[✓] %-40s${NC} (%s)\n" "$((i+1))" "$key" "$description"
            else
                printf "  [%-2d] [ ] %-40s (%s)\n" "$((i+1))" "$key" "$description"
            fi
        done
        
        echo
        echo -e "      ${GREEN}[S] 开始备份${NC}      ${RED}[Q] 取消备份${NC}"
        read -p "请操作 [输入数字, S 或 Q]: " user_choice

        case "$user_choice" in
            [qQ]) echo "备份已取消。"; fn_press_any_key; return ;;
            [sS]) break ;;
            *)
                if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "${#options[@]}" ]; then
                    local selected_key="${options[$((user_choice-1))]}"
                    # [修复] 切换逻辑
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

    local paths_to_backup=()
    for key in "${!selection_status[@]}"; do
        if ${selection_status[$key]}; then
            if [ -e "$key" ]; then
                 paths_to_backup+=("$key")
            else
                 fn_print_warning "路径 '$key' 不存在，已跳过。"
            fi
        fi
    done

    if [ ${#paths_to_backup[@]} -eq 0 ]; then
        fn_print_warning "您没有选择任何有效的项目，备份已取消。"
        fn_press_any_key
        return
    fi
    
    mkdir -p "$BACKUP_ROOT_DIR"
    local timestamp; timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_备份_${timestamp}"
    local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}.zip"
    
    echo -e "\n${YELLOW}正在根据您的选择压缩文件...${NC}"
    echo "包含项目: ${paths_to_backup[*]}"
    zip -rq "$backup_zip_path" "${paths_to_backup[@]}"
    
    if [ $? -ne 0 ]; then fn_print_warning "备份失败！"; fn_press_any_key; return; fi
    
    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    fn_print_success "备份成功：${backup_name}.zip (当前备份数: ${#all_backups[@]}/${BACKUP_LIMIT})"

    if [ "${#all_backups[@]}" -gt $BACKUP_LIMIT ]; then
        echo -e "${YELLOW}备份数量超过上限，正在清理旧备份...${NC}"
        local backups_to_delete=("${all_backups[@]:$BACKUP_LIMIT}")
        for old_backup in "${backups_to_delete[@]}"; do
            rm "$old_backup"; echo "  - 已删除: $(basename "$old_backup")"
        done
        fn_print_success "清理完成。"
    fi
    fn_press_any_key
}

# 手动恢复指南
main_manual_restore_guide() {
    clear
    fn_print_header "手动恢复指南 (使用MT管理器)"
    echo -e "${YELLOW}自动恢复有风险，手动操作更安全。请遵循以下步骤：${NC}"
    echo
    echo -e "${BOLD}第1步：找到备份文件${NC}"
    echo -e "  - 备份文件通常位于: ${CYAN}${ST_DIR}/_我的备份/${NC}"
    echo -e "  - 文件名类似于: ${GREEN}ST_备份_2023-10-27_14-30.zip${NC}"
    echo
    echo -e "${BOLD}第2步：找到酒馆主目录${NC}"
    echo -e "  - 您的酒馆安装在: ${CYAN}${ST_DIR}${NC}"
    echo
    echo -e "${BOLD}第3步：执行解压覆盖 (核心操作)${NC}"
    echo -e "  1. 在MT管理器中，长按你的备份zip文件。"
    echo -e "  2. 在弹出的菜单中选择 ${GREEN}“解压到...”${NC}。"
    echo -e "  3. 在路径选择界面，导航到你的酒馆主目录 (${CYAN}SillyTavern${NC})。"
    echo -e "  4. 点击右下角的 ${GREEN}“确定”${NC}。"
    echo -e "  5. MT管理器会提示“存在同名文件”，请务必选择 ${YELLOW}“全部覆盖”${NC}。"
    echo
    echo -e "${RED}${BOLD}警告：此操作会用备份文件覆盖现有文件，请确保您选择了正确的备份包。${NC}"
    fn_press_any_key
}

# 删除备份
run_delete_backup() {
    clear
    fn_print_header "删除旧备份"
    mkdir -p "$BACKUP_ROOT_DIR"
    mapfile -t backup_files < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)

    if [ ${#backup_files[@]} -eq 0 ]; then
        fn_print_warning "未找到任何备份文件。"; fn_press_any_key; return;
    fi

    echo -e "检测到以下备份 (当前/上限: ${#backup_files[@]}/${BACKUP_LIMIT}):"
    for i in "${!backup_files[@]}"; do
        printf "    [%-2d] %s\n" "$((i+1))" "$(basename "${backup_files[$i]}")"
    done

    read -p "输入要删除的备份编号 (其他键取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        echo "操作已取消."; fn_press_any_key; return;
    fi

    local chosen_backup="${backup_files[$((choice-1))]}"
    read -p "确认删除 '$(basename "$chosen_backup")' 吗？(y/n): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        rm "$chosen_backup"
        fn_print_success "备份已删除。"
    else
        echo "操作已取消。"
    fi
    fn_press_any_key
}

# 数据管理主菜单
main_data_management_menu() {
    while true; do
        clear
        fn_print_header "SillyTavern 数据管理"
        echo -e "      [1] ${GREEN}创建自定义备份${NC}"
        echo -e "      [2] ${CYAN}手动恢复指南 (MT管理器)${NC}"
        echo -e "      [3] ${RED}删除旧备份${NC}"
        echo -e "      [0] ${CYAN}返回主菜单${NC}"
        read -p "    请输入选项: " choice

        case $choice in
            1) run_backup_interactive ;;
            2) main_manual_restore_guide ;;
            3) run_delete_backup ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# --- 模块：首次部署 ---
main_install() {
    clear; fn_print_header "SillyTavern 首次部署向导"
    fn_print_header "1/5: 配置软件源"
    fn_print_warning "接下来会弹出一个界面，按两次回车或OK确认即可。"
    read -n 1 -s -r -p "  准备好后，请按任意键继续..."; echo
    termux-change-repo
    echo -e "${YELLOW}正在更新软件包列表...${NC}"; yes | pkg update && yes | pkg upgrade || fn_print_error_exit "软件源更新失败！"
    fn_print_success "软件源配置完成。"
    fn_print_header "2/5: 安装核心依赖"
    echo -e "${YELLOW}正在安装所需的核心软件包...${NC}"; yes | pkg install git nodejs-lts rsync zip termux-api || fn_print_error_exit "核心依赖安装失败！"
    fn_print_success "核心依赖安装完毕。"
    fn_print_header "3/5: 下载 ST 主程序"
    if [ -d "$ST_DIR" ]; then fn_print_warning "目录已存在，跳过下载。"; else
        echo -e "${YELLOW}正在从镜像下载主程序 (${REPO_BRANCH} 分支)...${NC}"; git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$ST_DIR" || fn_print_error_exit "主程序下载失败！"
        fn_print_success "主程序下载完成。"
    fi
    fn_print_header "4/5: 配置 NPM 环境"
    if [ -d "$ST_DIR" ]; then cd "$ST_DIR" || exit; echo -e "${YELLOW}正在配置NPM国内镜像...${NC}"; npm config set registry https://registry.npmmirror.com; fn_print_success "NPM配置完成。"; else fn_print_warning "SillyTavern 目录不存在，跳过此步。"; fi
    fn_print_header "5/5: 设置自动运行"; main_manage_autostart "set_default"
    echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"; sleep 3; main_start
}

# --- 模块：更新 SillyTavern ---
main_update_st() {
    clear; fn_print_header "更新 SillyTavern 主程序"
    if [ ! -d "$ST_DIR/.git" ]; then fn_print_warning "未找到Git仓库，请先完整部署。"; fn_press_any_key; return; fi
    cd "$ST_DIR" || return
    echo -e "${YELLOW}正在拉取最新代码...${NC}"; git pull origin "$REPO_BRANCH"
    if [ $? -eq 0 ]; then fn_print_success "代码更新成功。"; echo -e "${YELLOW}正在同步依赖包...${NC}"; npm install --no-audit --no-fund --omit=dev; fn_print_success "依赖包更新完成。"; else fn_print_warning "代码更新失败，可能存在冲突。"; fi
    fn_press_any_key
}

# --- 模块：助手自我更新 ---
main_update_script() {
    clear; fn_print_header "更新助手脚本"
    echo -e "${YELLOW}正在从 Gitee 检查新版本...${NC}"
    local temp_file="${SCRIPT_SELF_PATH}.tmp"
    curl -L -o "$temp_file" "$SCRIPT_URL"
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then rm -f "$temp_file"; fn_print_warning "下载失败，请检查网络。";
    elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then rm -f "$temp_file"; fn_print_success "当前已是最新版本。";
    else mv "$temp_file" "$SCRIPT_SELF_PATH"; chmod +x "$SCRIPT_SELF_PATH"; echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"; sleep 2; exec "$SCRIPT_SELF_PATH" --updated; fi
    fn_press_any_key
}

# --- 其它模块 (自启, 文档) ---
main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"; local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""
    grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true || is_set=false
    if [[ "$1" == "set_default" ]]; then if ! $is_set; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"; fn_print_success "已设置 Termux 启动时自动运行本助手。"; fi; return; fi
    clear; fn_print_header "管理助手自启"
    if $is_set; then echo -e "当前状态: ${GREEN}已启用${NC}"; read -p "是否取消自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then sed -i "/# SillyTavern 助手/d" "$BASHRC_FILE"; sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"; fn_print_success "已取消自启。"; fi
    else echo -e "当前状态: ${RED}未启用${NC}"; read -p "是否设置自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"; fn_print_success "已成功设置自启。"; fi; fi
    fn_press_any_key
}
main_open_docs() {
    clear; fn_print_header "打开在线帮助文档"; if fn_check_command "termux-open-url"; then termux-open-url "https://stdocs.723123.xyz"; fn_print_success "已调用浏览器打开文档。"; else fn_print_warning "命令 'termux-open-url' 不存在。"; echo "请先安装【Termux:API】应用及 'pkg install termux-api'。"; fi; fn_press_any_key
}

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

if [[ "$1" == "--updated" ]]; then clear; fn_print_success "助手已成功更新至最新版本！"; sleep 2; fi

while true; do
    clear
    echo -e "${CYAN}${BOLD}"; cat << "EOF"
    ╔═════════════════════════════════╗
    ║        SillyTavern 助手         ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    echo -e "${NC}"; echo -e "    选择一个操作来开始：\n";
    echo -e "      ${GREEN}[1]${NC} ${BOLD}启动 SillyTavern${NC}"
    echo -e "      ${CYAN}[2]${NC} ${BOLD}数据管理${NC}"
    echo -e "      ${YELLOW}[3]${NC} ${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [4] 更新 ST 主程序    [5] 更新助手脚本"
    echo -e "      [6] 管理助手自启      [7] 查看在线文档\n"
    echo -e "      ${RED}[0] 退出助手${NC}\n"
    read -p "    请输入选项数字: " choice

    case $choice in
        1) main_start ;;
        2) main_data_management_menu ;;
        3) main_install ;;
        4) main_update_st ;;
        5) main_update_script ;;
        6) main_manage_autostart ;;
        7) main_open_docs ;;
        0) echo -e "\n感谢使用，助手已退出。"; exit 0 ;;
        *) echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 1.5 ;;
    esac
done
