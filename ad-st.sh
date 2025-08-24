#!/data/data/com.termux/files/usr/bin/bash
# =========================================================================
#
#                       SillyTavern 助手 v1.5
#                           作者: Qingjue
#                        小红书号: 826702880
#
# =========================================================================

# --- 脚本环境与色彩定义 ---
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# --- 核心配置 ---
ST_DIR="$HOME/SillyTavern"                                                   # SillyTavern 的安装目录
MIRROR_LIST=(                                                               # Git 镜像列表
    "https://github.com/SillyTavern/SillyTavern.git"
    "https://git.ark.xx.kg/gh/SillyTavern/SillyTavern.git"
    "https://git.723123.xyz/gh/SillyTavern/SillyTavern.git"
    "https://xget.xi-xu.me/gh/SillyTavern/SillyTavern.git"
    "https://gh-proxy.com/github.com/SillyTavern/SillyTavern.git"
    "https://gh.llkk.cc/https://github.com/SillyTavern/SillyTavern.git"
    "https://tvv.tw/https://github.com/SillyTavern/SillyTavern.git"
    "https://proxy.pipers.cn/https://github.com/SillyTavern/SillyTavern.git"
)
REPO_BRANCH="release"                                                       # 指定下载的 Git 分支
BACKUP_ROOT_DIR="$ST_DIR/_我的备份"                                           # 备份文件的存放目录
BACKUP_LIMIT=10                                                             # 最多保留的备份文件数量
SCRIPT_SELF_PATH=$(readlink -f "$0")                                        # 脚本自身路径
SCRIPT_URL="https://gitee.com/canaan723/st-assistant/raw/master/ad-st.sh"   # 脚本更新源地址
CONFIG_FILE="$HOME/.st_assistant.conf"                                      # 保存用户备份偏好的配置文件
UPDATE_FLAG_FILE="/data/data/com.termux/files/usr/tmp/.st_assistant_update_flag" # 脚本更新标记文件

# =========================================================================
#   辅助函数库
# =========================================================================

# 打印带样式的标题
fn_print_header() { echo -e "\n${CYAN}═══ ${BOLD}$1 ${NC}═══${NC}"; }
# 打印成功信息
fn_print_success() { echo -e "${GREEN}✓ ${BOLD}$1${NC}"; }
# 打印警告信息
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
# 打印错误信息并退出
fn_print_error_exit() {
    echo -e "\n${RED}✗ ${BOLD}$1${NC}\n${RED}流程已终止。${NC}" >&2
    exit 1
}
# 等待用户按键继续
fn_press_any_key() {
    echo -e "\n${CYAN}请按任意键返回...${NC}"
    read -n 1 -s
}
# 检查命令是否存在
fn_check_command() { command -v "$1" >/dev/null 2>&1; }

# 动态测试并选择最快的 Git 镜像 (带8秒超时)
fn_find_fastest_mirror() {
    local fastest_mirror=""
    local min_time=9999
    local total_mirrors=${#MIRROR_LIST[@]}
    
    echo -e "${YELLOW}开始测试 Git 镜像连通性与速度...${NC}" >&2

    for i in "${!MIRROR_LIST[@]}"; do
        local mirror_url="${MIRROR_LIST[$i]}"
        local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
        
        echo -ne "  [${YELLOW}$((i+1))/${total_mirrors}${NC}] 正在测试: ${CYAN}${mirror_host}${NC} ..." >&2

        local elapsed_time
        elapsed_time=$(TIMEFORMAT='%R'; { time timeout 8s git ls-remote "$mirror_url" HEAD >/dev/null 2>&1; } 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ] && [[ "$elapsed_time" =~ ^[0-9.]+$ ]]; then
            echo -e "\r  [${GREEN}✓${NC}] 测试成功: ${CYAN}${mirror_host}${NC} - 耗时 ${GREEN}${elapsed_time}s${NC}          " >&2
            if [ "$(awk -v t1="$elapsed_time" -v t2="$min_time" 'BEGIN{print(t1<t2)}')" -eq 1 ]; then
                min_time=$elapsed_time
                fastest_mirror=$mirror_url
            fi
        else
            echo -e "\r  [${RED}✗${NC}] 测试失败: ${CYAN}${mirror_host}${NC} - ${RED}连接超时或无效${NC}      " >&2
        fi
    done

    if [ -z "$fastest_mirror" ]; then
        fn_print_error_exit "所有镜像都无法连接，请检查网络或更新镜像列表。"
    else
        local fastest_host; fastest_host=$(echo "$fastest_mirror" | sed -e 's|https://||' -e 's|/.*$||')
        echo -e "${GREEN}✓ ${BOLD}已选定最快镜像: ${fastest_host} (耗时 ${min_time}s)${NC}" >&2
        echo "$fastest_mirror"
    fi
}

# =========================================================================
#   核心功能模块
# =========================================================================

# 启动 SillyTavern
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
    echo -e "${YELLOW}首次启动或更新后会安装依赖，耗时可能较长，请耐心等待...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

# 创建一个交互式的自定义备份
run_backup_interactive() {
    clear
    fn_print_header "创建自定义备份"
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "SillyTavern 尚未安装，无法备份。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录: $ST_DIR"

    declare -A ALL_PATHS=(
        ["./data"]="用户数据 (聊天/角色/设置)"
        ["./public/scripts/extensions/third-party"]="前端扩展"
        ["./plugins"]="后端扩展"
        ["./config.yaml"]="服务器配置 (网络/安全)"
    )
    local options=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    local default_selection=("./data" "./plugins" "./public/scripts/extensions/third-party")
    
    local selection_to_load=()
    if [ -f "$CONFIG_FILE" ]; then
        mapfile -t selection_to_load < "$CONFIG_FILE"
        if [ ${#selection_to_load[@]} -eq 0 ]; then
            selection_to_load=("${default_selection[@]}")
        fi
    else
        selection_to_load=("${default_selection[@]}")
    fi

    declare -A selection_status
    for key in "${options[@]}"; do selection_status["$key"]=false; done
    for key in "${selection_to_load[@]}"; do
        if [[ -v selection_status["$key"] ]]; then
            selection_status["$key"]=true
        fi
    done

    while true; do
        clear
        fn_print_header "请选择要备份的内容"
        echo "输入数字可切换勾选状态。"
        for i in "${!options[@]}"; do
            local key="${options[$i]}"
            local description="${ALL_PATHS[$key]}"
            if ${selection_status[$key]}; then
                printf "  [%-2d] ${GREEN}[✓] %s${NC}\n" "$((i+1))" "$key"
            else
                printf "  [%-2d] [ ] %s${NC}\n" "$((i+1))" "$key"
            fi
            printf "      ${CYAN}(%s)${NC}\n" "$description"
        done
        echo -e "      ${GREEN}[回车] 开始备份${NC}      ${RED}[0] 取消备份${NC}"
        read -p "请操作 [输入数字, 回车 或 0]: " user_choice
        
        case "$user_choice" in
            "" | [sS]) break ;;
            0) echo "备份已取消。"; fn_press_any_key; return ;;
            *)
                if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "${#options[@]}" ]; then
                    local selected_key="${options[$((user_choice-1))]}"
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

    local paths_to_backup=()
    for key in "${options[@]}"; do
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
    echo "包含项目:"
    for item in "${paths_to_backup[@]}"; do echo "  - $item"; done
    
    local exclude_params=(-x "*/.git/*" -x "*/_cache/*" -x "*.log" -x "*/backups/*")
    zip -rq "$backup_zip_path" "${paths_to_backup[@]}" "${exclude_params[@]}"
    
    if [ $? -ne 0 ]; then
        fn_print_warning "备份失败！"
        fn_press_any_key
        return
    fi
    
    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    fn_print_success "备份成功：${backup_name}.zip (当前备份数: ${#all_backups[@]}/${BACKUP_LIMIT})"
    printf "%s\n" "${paths_to_backup[@]}" > "$CONFIG_FILE"

    if [ "${#all_backups[@]}" -gt $BACKUP_LIMIT ]; then
        echo -e "${YELLOW}备份数量超过上限，正在清理旧备份...${NC}"
        local backups_to_delete=("${all_backups[@]:$BACKUP_LIMIT}")
        for old_backup in "${backups_to_delete[@]}"; do
            rm "$old_backup"
            echo "  - 已删除: $(basename "$old_backup")"
        done
        fn_print_success "清理完成。"
    fi
    fn_press_any_key
}

# 显示数据迁移或恢复的操作指南
main_migration_guide() {
    clear
    fn_print_header "数据迁移 / 恢复指南"
    echo -e "${YELLOW}请遵循以下步骤，将您的数据从旧设备迁移到新设备，或恢复备份：${NC}"
    echo -e "  1. 在旧设备上，用MT管理器等文件工具，进入目录："
    echo -e "     ${CYAN}${ST_DIR}/_我的备份/${NC}"
    echo -e "  2. 找到需要的备份压缩包 (例如 ST_备份_xxxx.zip)，并将其发送到新设备。"
    echo -e "  3. 在新设备上，将这个压缩包移动或复制到 SillyTavern 的根目录："
    echo -e "     ${CYAN}${ST_DIR}/${NC}"
    echo -e "  4. 使用 MT 管理器等工具，将压缩包 ${GREEN}“解压到当前目录”${NC}。"
    echo -e "  5. 如果提示文件已存在，请选择 ${YELLOW}“全部覆盖”${NC}。"
    echo -e "  6. 操作完成后，重启 SillyTavern 即可看到所有数据。"
    echo -e "\n${YELLOW}如需更详细的图文教程，请在主菜单选择 [7] 查看帮助文档。${NC}"
    fn_press_any_key
}

# 提供删除旧备份文件的功能
run_delete_backup() {
    clear; fn_print_header "删除旧备份"
    if [ ! -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "SillyTavern 尚未安装，没有可管理的备份。"
        fn_press_any_key
        return
    fi
    mkdir -p "$BACKUP_ROOT_DIR"
    mapfile -t backup_files < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    if [ ${#backup_files[@]} -eq 0 ]; then
        fn_print_warning "未找到任何备份文件。"
        fn_press_any_key
        return
    fi
    echo -e "检测到以下备份 (当前/上限: ${#backup_files[@]}/${BACKUP_LIMIT}):"
    local i=0
    for file in "${backup_files[@]}"; do
        if [ -f "$file" ]; then
            local size; size=$(du -h "$file" | cut -f1)
            printf "    [%-2d] %-40s (%s)\n" "$((++i))" "$(basename "$file")" "$size"
        fi
    done
    read -p "输入要删除的备份编号 (其他键取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        echo "操作已取消."
        fn_press_any_key
        return
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

# 数据管理功能的二级菜单
main_data_management_menu() {
    while true; do
        clear
        fn_print_header "SillyTavern 数据管理"
        echo -e "      [1] ${GREEN}创建自定义备份${NC}"
        echo -e "      [2] ${CYAN}数据迁移/恢复指南${NC}"
        echo -e "      [3] ${RED}删除旧备份${NC}"
        echo -e "      [0] ${CYAN}返回主菜单${NC}"
        read -p "    请输入选项: " choice
        case $choice in
            1) run_backup_interactive ;;
            2) main_migration_guide ;;
            3) run_delete_backup ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# 首次安装 SillyTavern 的完整流程
main_install() {
    clear; fn_print_header "SillyTavern 首次部署向导"
    
    fn_print_header "1/5: 配置软件源"
    echo -e "${YELLOW}即将开始配置 Termux 软件源，请注意：${NC}"
    echo -e "  - 稍后会弹出一个蓝白色窗口，请根据以下提示操作。"
    echo -e "  - ${GREEN}推荐选项：${NC}依次选择 ${BOLD}${GREEN}第一项${NC} -> ${BOLD}${GREEN}第三项${NC}，这是国内网络的最优组合。"
    echo -e "  - ${CYAN}国内外通用选项：${NC}直接按 ${BOLD}${YELLOW}两次回车键${NC} 也能自动完成配置。"
    echo -e "\n${CYAN}请按任意键以继续...${NC}"; read -n 1 -s
    termux-change-repo

    echo -e "${YELLOW}正在更新软件包列表...${NC}"
    yes | pkg update && yes | pkg upgrade || fn_print_error_exit "软件源更新失败！"
    fn_print_success "软件源配置完成。"
    
    fn_print_header "2/5: 安装核心依赖"
    echo -e "${YELLOW}正在安装所需的核心软件包...${NC}"
    yes | pkg install git nodejs-lts rsync zip termux-api coreutils gawk || fn_print_error_exit "核心依赖安装失败！"
    fn_print_success "核心依赖安装完毕。"
    
    fn_print_header "3/5: 下载 ST 主程序"
    if [ -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "检测到完整的 SillyTavern 安装，跳过下载。"
    elif [ -d "$ST_DIR" ] && [ -n "$(ls -A "$ST_DIR")" ]; then
        fn_print_error_exit "目录 $ST_DIR 已存在但安装不完整。请手动删除该目录后再试。"
    else
        local fastest_repo_url; fastest_repo_url=$(fn_find_fastest_mirror)
        echo -e "${YELLOW}正在从最快镜像下载主程序 (${REPO_BRANCH} 分支)...${NC}"
        git clone --depth 1 -b "$REPO_BRANCH" "$fastest_repo_url" "$ST_DIR" || fn_print_error_exit "主程序下载失败！请检查网络或更换镜像列表。"
        fn_print_success "主程序下载完成。"
    fi

    fn_print_header "4/5: 配置 NPM 环境"
    if [ -d "$ST_DIR" ]; then
        cd "$ST_DIR" || exit
        echo -e "${YELLOW}正在配置NPM国内镜像...${NC}"
        npm config set registry https://registry.npmmirror.com
        fn_print_success "NPM配置完成。"
    else
        fn_print_warning "SillyTavern 目录不存在，跳过此步。"
    fi
    
    fn_print_header "5/5: 设置自启与快捷命令"
    main_manage_autostart "set_default"
    fn_create_shortcut
    echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"; sleep 3; main_start
}

# 更新 SillyTavern 主程序
main_update_st() {
    clear; fn_print_header "更新 SillyTavern 主程序"
    if [ ! -d "$ST_DIR/.git" ]; then
        fn_print_warning "未找到Git仓库，请先完整部署。"
        fn_press_any_key
        return
    fi
    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录: $ST_DIR"
    
    local fastest_repo_url; fastest_repo_url=$(fn_find_fastest_mirror)
    echo -e "${YELLOW}正在同步远程仓库地址为当前最快镜像...${NC}"
    git remote set-url origin "$fastest_repo_url"
    if [ $? -ne 0 ]; then
        fn_print_warning "同步远程地址失败，更新可能使用旧链接。"
    fi
    echo -e "${YELLOW}正在拉取最新代码...${NC}"
    git pull origin "$REPO_BRANCH"
    if [ $? -eq 0 ]; then
        fn_print_success "代码更新成功。"
        echo -e "${YELLOW}正在同步依赖包...${NC}"
        npm install --no-audit --no-fund --omit=dev
        fn_print_success "依赖包更新完成。"
    else
        fn_print_warning "代码更新失败，可能存在冲突。"
    fi
    fn_press_any_key
}

# 助手脚本自我更新
main_update_script() {
    clear; fn_print_header "更新助手脚本"
    echo -e "${YELLOW}正在从 Gitee 下载新版本...${NC}"
    local temp_file; temp_file=$(mktemp)
    curl -L -o "$temp_file" "$SCRIPT_URL"
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        fn_print_warning "下载失败，请检查网络。"
    elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
        rm -f "$temp_file"
        fn_print_success "当前已是最新版本。"
    else
        sed -i 's/\r$//' "$temp_file"
        mv "$temp_file" "$SCRIPT_SELF_PATH"
        chmod +x "$SCRIPT_SELF_PATH"
        rm -f "$UPDATE_FLAG_FILE"
        echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"
        sleep 2
        exec "$SCRIPT_SELF_PATH" --updated
    fi
    fn_press_any_key
}

# 在后台静默检查脚本是否有新版本
check_for_updates_on_start() {
    (
        local temp_file; temp_file=$(mktemp)
        if curl -L -s -o "$temp_file" "$SCRIPT_URL"; then
            if ! cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then
                touch "$UPDATE_FLAG_FILE"
            else
                rm -f "$UPDATE_FLAG_FILE"
            fi
        fi
        rm -f "$temp_file"
    ) &
}

# 创建 'st' 快捷命令并确保脚本可执行
fn_create_shortcut() {
    local BASHRC_FILE="$HOME/.bashrc"
    local ALIAS_CMD="alias st='\"$SCRIPT_SELF_PATH\"'"
    local ALIAS_COMMENT="# SillyTavern 助手快捷命令"
    if ! grep -qF "$ALIAS_CMD" "$BASHRC_FILE"; then
        chmod +x "$SCRIPT_SELF_PATH"
        echo -e "\n$ALIAS_COMMENT\n$ALIAS_CMD" >> "$BASHRC_FILE"
        fn_print_success "已创建快捷命令 'st' 并授予执行权限。"
        echo -e "${YELLOW}请重启 Termux 或执行 'source ~/.bashrc' 使其生效。${NC}"
    fi
}

# 管理脚本是否在 Termux 启动时自动运行
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

    clear; fn_print_header "管理助手自启"
    if $is_set; then
        echo -e "当前状态: ${GREEN}已启用${NC}"
        echo -e "${CYAN}提示: 关闭自启后，输入 'st' 命令即可手动启动助手。${NC}"
        read -p "是否取消自启？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            sed -i "/# SillyTavern 助手/d" "$BASHRC_FILE"
            sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"
            fn_print_success "已取消自启。"
        fi
    else
        echo -e "当前状态: ${RED}未启用${NC}"
        echo -e "${CYAN}提示: 在 Termux 中输入 'st' 命令可以手动启动助手。${NC}"
        read -p "是否设置自启？ (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"
            fn_print_success "已成功设置自启。"
        fi
    fi
    fn_press_any_key
}

# 显示并尝试打开在线帮助文档
main_open_docs() {
    clear; fn_print_header "查看帮助文档"
    local docs_url="https://stdocs.723123.xyz"
    echo -e "文档网址: ${CYAN}${docs_url}${NC}\n"
    if fn_check_command "termux-open-url"; then 
        termux-open-url "$docs_url"
        fn_print_success "已尝试在浏览器中打开，若未自动跳转请手动复制上方网址。"
    else 
        fn_print_warning "命令 'termux-open-url' 不存在。"
        echo "请先安装【Termux:API】应用及 'pkg install termux-api'。"
    fi
    fn_press_any_key
}

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

# 启动时检查更新 (除非被告知不检查)
if [[ "$1" != "--no-check" ]]; then check_for_updates_on_start; fi
# 如果是从更新后重启，则显示成功信息
if [[ "$1" == "--updated" ]]; then clear; fn_print_success "助手已成功更新至最新版本！"; sleep 2; fi

# 主循环，显示菜单
while true; do
    clear
    echo -e "${CYAN}${BOLD}"; cat << "EOF"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v1.5      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    update_notice=""; if [ -f "$UPDATE_FLAG_FILE" ]; then update_notice=" ${YELLOW}[!] 有更新${NC}"; fi
    echo -e "${NC}"; echo -e "    选择一个操作来开始：\n";
    echo -e "      ${GREEN}[1]${NC} ${BOLD}启动 SillyTavern${NC}"; echo -e "      ${CYAN}[2]${NC} ${BOLD}数据管理${NC}"; echo -e "      ${YELLOW}[3]${NC} ${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [4] 更新 ST 主程序    [5] 更新助手脚本${update_notice}"; echo -e "      [6] 管理助手自启      [7] 查看帮助文档\n"
    echo -e "      ${RED}[0] 退出助手${NC}\n"; read -p "    请输入选项数字: " choice
    case $choice in
        1) main_start ;;
        2) main_data_management_menu ;;
        3) main_install ;;
        4) main_update_st ;;
        5) main_update_script ;;
        6) main_manage_autostart ;;
        7) main_open_docs ;;
        0) echo -e "\n感谢使用，助手已退出。"; rm -f "$UPDATE_FLAG_FILE"; exit 0 ;;
        *) echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 1.5 ;;
    esac
done