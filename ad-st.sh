#!/data/data/com.termux/files/usr/bin/bash
# =========================================================================
#
#                       SillyTavern 助手 v1.1
#
#   一个为 Termux 用户设计的 SillyTavern 管理与维护脚本。
#   此版本支持动态测试并选择最快的Git镜像进行下载与更新。
#
#   作者: Qingjue
#   小红书号: 826702880
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
# Git 镜像列表 (脚本将自动测试并选择最快的)
MIRROR_LIST=(
    "https://github.com/SillyTavern/SillyTavern.git"
    "https://git.ark.xx.kg/gh/SillyTavern/SillyTavern.git"
    "https://git.723123.xyz/gh/SillyTavern/SillyTavern.git"
    "https://xget.xi-xu.mez/gh/SillyTavern/SillyTavern.git"
    "https://git.yylx.win/github.com/SillyTavern/SillyTavern.git"
    "https://git.ppp.ac.cn/https://github.com/SillyTavern/SillyTavern.git"
    "https://github.moeyy.xyz/https://github.com/SillyTavern/SillyTavern.git"
    "https://git.886.be/https://github.com/SillyTavern/SillyTavern.git"
)
REPO_BRANCH="release"
BACKUP_ROOT_DIR="$ST_DIR/_我的备份"
BACKUP_LIMIT=10
SCRIPT_SELF_PATH=$(readlink -f "$0")
SCRIPT_URL="https://gitee.com/canaan723/st-assistant/raw/master/ad-st.sh"
CONFIG_FILE="$HOME/.st_assistant.conf"
UPDATE_FLAG_FILE="/data/data/com.termux/files/usr/tmp/.st_assistant_update_flag"

# =========================================================================
#   辅助函数库
# =========================================================================

fn_print_header() { echo -e "\n${CYAN}═══ ${BOLD}$1 ${NC}═══${NC}"; }
fn_print_success() { echo -e "${GREEN}✓ ${BOLD}$1${NC}"; }
fn_print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
fn_print_error_exit() {
    # 修正：将错误信息输出到 stderr
    echo -e "\n${RED}✗ ${BOLD}$1${NC}\n${RED}流程已终止。${NC}" >&2
    exit 1
}
fn_press_any_key() {
    echo -e "\n${CYAN}请按任意键返回...${NC}"
    read -n 1 -s
}
fn_check_command() { command -v "$1" >/dev/null 2>&1; }

# === 修正：镜像测速函数 ===
# 作用: 将所有进度信息输出到 stderr，只将最终结果 URL 输出到 stdout
fn_find_fastest_mirror() {
    local fastest_mirror=""
    local min_time=9999
    local total_mirrors=${#MIRROR_LIST[@]}
    
    # 进度信息输出到 stderr (>&2)
    echo -e "${YELLOW}开始测试 Git 镜像连通性与速度...${NC}" >&2

    for i in "${!MIRROR_LIST[@]}"; do
        local mirror_url="${MIRROR_LIST[$i]}"
        local mirror_host; mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
        
        # 进度信息输出到 stderr (>&2)
        echo -ne "  [${YELLOW}$((i+1))/${total_mirrors}${NC}] 正在测试: ${CYAN}${mirror_host}${NC} ..." >&2

        local elapsed_time
        elapsed_time=$(TIMEFORMAT='%R'; { time git ls-remote "$mirror_url" HEAD >/dev/null 2>&1; } 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ] && [[ "$elapsed_time" =~ ^[0-9.]+$ ]]; then
            # 进度信息输出到 stderr (>&2)
            echo -e "\r  [${GREEN}✓${NC}] 测试成功: ${CYAN}${mirror_host}${NC} - 耗时 ${GREEN}${elapsed_time}s${NC}          " >&2
            if [ "$(awk -v t1="$elapsed_time" -v t2="$min_time" 'BEGIN{print(t1<t2)}')" -eq 1 ]; then
                min_time=$elapsed_time
                fastest_mirror=$mirror_url
            fi
        else
            # 进度信息输出到 stderr (>&2)
            echo -e "\r  [${RED}✗${NC}] 测试失败: ${CYAN}${mirror_host}${NC} - ${RED}连接超时或无效${NC}      " >&2
        fi
    done

    if [ -z "$fastest_mirror" ]; then
        fn_print_error_exit "所有镜像都无法连接，请检查网络或更新镜像列表。"
    else
        local fastest_host; fastest_host=$(echo "$fastest_mirror" | sed -e 's|https://||' -e 's|/.*$||')
        # 进度信息输出到 stderr (>&2)
        echo -e "${GREEN}✓ ${BOLD}已选定最快镜像: ${fastest_host} (耗时 ${min_time}s)${NC}" >&2
        # ！！！关键：只将最终的 URL 输出到 stdout，这样才能被 $(...) 正确捕获
        echo "$fastest_mirror"
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
    npm config set registry https://registry.npmmirror.com
    echo -e "${YELLOW}环境准备就绪，正在启动SillyTavern服务...${NC}"
    bash start.sh
    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

# --- 模块：数据管理 ---
# (此部分无改动，保持原样)
run_backup_interactive() {
    clear; fn_print_header "创建自定义备份"; if [ ! -d "$ST_DIR" ]; then fn_print_warning "SillyTavern 尚未安装，无法备份。"; fn_press_any_key; return; fi; cd "$ST_DIR" || return
    declare -A ALL_PATHS=(["./data"]="用户数据 (聊天/角色/设置)" ["./public/scripts/extensions/third-party"]="前端扩展" ["./plugins"]="后端扩展" ["./config.yaml"]="服务器配置 (网络/安全)"); local options=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    local default_selection=("./data" "./plugins" "./public/scripts/extensions/third-party"); local selection_to_load=(); if [ -f "$CONFIG_FILE" ]; then mapfile -t selection_to_load < "$CONFIG_FILE"; if [ ${#selection_to_load[@]} -eq 0 ]; then selection_to_load=("${default_selection[@]}"); fi; else selection_to_load=("${default_selection[@]}"); fi
    declare -A selection_status; for key in "${options[@]}"; do selection_status["$key"]=false; done; for key in "${selection_to_load[@]}"; do if [[ -v selection_status["$key"] ]]; then selection_status["$key"]=true; fi; done
    while true; do
        clear; fn_print_header "请选择要备份的内容"; echo "输入数字可切换勾选状态。"
        for i in "${!options[@]}"; do local key="${options[$i]}"; local description="${ALL_PATHS[$key]}"; if ${selection_status[$key]}; then printf "  [%-2d] ${GREEN}[✓] %s${NC}\n" "$((i+1))" "$key"; else printf "  [%-2d] [ ] %s\n" "$((i+1))" "$key"; fi; printf "      ${CYAN}(%s)${NC}\n" "$description"; done
        echo -e "      ${GREEN}[回车] 开始备份${NC}      ${RED}[0] 取消备份${NC}"; read -p "请操作 [输入数字, 回车 或 0]: " user_choice
        case "$user_choice" in "" | [sS]) break ;; 0) echo "备份已取消。"; fn_press_any_key; return ;; *) if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "${#options[@]}" ]; then local selected_key="${options[$((user_choice-1))]}"; if ${selection_status[$selected_key]}; then selection_status[$selected_key]=false; else selection_status[$selected_key]=true; fi; else fn_print_warning "无效输入。"; sleep 1; fi ;; esac
    done
    local paths_to_backup=(); for key in "${options[@]}"; do if ${selection_status[$key]}; then if [ -e "$key" ]; then paths_to_backup+=("$key"); else fn_print_warning "路径 '$key' 不存在，已跳过。"; fi; fi; done
    if [ ${#paths_to_backup[@]} -eq 0 ]; then fn_print_warning "您没有选择任何有效的项目，备份已取消。"; fn_press_any_key; return; fi
    mkdir -p "$BACKUP_ROOT_DIR"; local timestamp; timestamp=$(date +"%Y-%m-%d_%H-%M"); local backup_name="ST_备份_${timestamp}"; local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}.zip"
    echo -e "\n${YELLOW}正在根据您的选择压缩文件...${NC}"; echo "包含项目:"; for item in "${paths_to_backup[@]}"; do echo "  - $item"; done
    local exclude_params=(-x "*/.git/*" -x "*/_cache/*" -x "*.log"); zip -rq "$backup_zip_path" "${paths_to_backup[@]}" "${exclude_params[@]}"
    if [ $? -ne 0 ]; then fn_print_warning "备份失败！"; fn_press_any_key; return; fi
    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-); fn_print_success "备份成功：${backup_name}.zip (当前备份数: ${#all_backups[@]}/${BACKUP_LIMIT})"
    printf "%s\n" "${paths_to_backup[@]}" > "$CONFIG_FILE"
    if [ "${#all_backups[@]}" -gt $BACKUP_LIMIT ]; then
        echo -e "${YELLOW}备份数量超过上限，正在清理旧备份...${NC}"; local backups_to_delete=("${all_backups[@]:$BACKUP_LIMIT}"); for old_backup in "${backups_to_delete[@]}"; do rm "$old_backup"; echo "  - 已删除: $(basename "$old_backup")"; done; fn_print_success "清理完成。"
    fi; fn_press_any_key
}
main_manual_restore_guide() {
    clear; fn_print_header "手动恢复指南 (使用MT管理器)"; echo -e "${YELLOW}自动恢复有风险，手动操作更安全。请遵循以下步骤：${NC}"; echo -e "  1. 在MT管理器中找到备份文件: ${CYAN}${ST_DIR}/_我的备份/${NC}"; echo -e "  2. 长按zip文件, 选择 ${GREEN}“解压到...”${NC}。"; echo -e "  3. 路径选择到酒馆主目录: ${CYAN}${ST_DIR}${NC}"; echo -e "  4. 提示同名文件时, 选择 ${YELLOW}“全部覆盖”${NC}。"; echo -e "\n${RED}${BOLD}警告：此操作会用备份文件覆盖现有文件，请谨慎操作。${NC}"; fn_press_any_key
}
run_delete_backup() {
    clear; fn_print_header "删除旧备份"; mkdir -p "$BACKUP_ROOT_DIR"; mapfile -t backup_files < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    if [ ${#backup_files[@]} -eq 0 ]; then fn_print_warning "未找到任何备份文件。"; fn_press_any_key; return; fi
    echo -e "检测到以下备份 (当前/上限: ${#backup_files[@]}/${BACKUP_LIMIT}):"; local i=0; for file in "${backup_files[@]}"; do if [ -f "$file" ]; then local size; size=$(du -h "$file" | cut -f1); printf "    [%-2d] %-40s (%s)\n" "$((++i))" "$(basename "$file")" "$size"; fi; done
    read -p "输入要删除的备份编号 (其他键取消): " choice; if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then echo "操作已取消."; fn_press_any_key; return; fi
    local chosen_backup="${backup_files[$((choice-1))]}"; read -p "确认删除 '$(basename "$chosen_backup")' 吗？(y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then rm "$chosen_backup"; fn_print_success "备份已删除。"; else echo "操作已取消。"; fi; fn_press_any_key
}
main_data_management_menu() {
    while true; do clear; fn_print_header "SillyTavern 数据管理"; echo -e "      [1] ${GREEN}创建自定义备份${NC}"; echo -e "      [2] ${CYAN}手动恢复指南 (MT管理器)${NC}"; echo -e "      [3] ${RED}删除旧备份${NC}"; echo -e "      [0] ${CYAN}返回主菜单${NC}"; read -p "    请输入选项: " choice
        case $choice in 1) run_backup_interactive ;; 2) main_manual_restore_guide ;; 3) run_delete_backup ;; 0) break ;; *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;; esac
    done
}

# --- 模块：首次部署 ---
main_install() {
    clear; fn_print_header "SillyTavern 首次部署向导"
    fn_print_header "1/5: 配置软件源"
    fn_print_warning "即将自动配置软件源，请在弹窗中按两次回车或OK确认。"
    sleep 3; termux-change-repo
    echo -e "${YELLOW}正在更新软件包列表...${NC}"; yes | pkg update && yes | pkg upgrade || fn_print_error_exit "软件源更新失败！"
    fn_print_success "软件源配置完成。"
    fn_print_header "2/5: 安装核心依赖"
    echo -e "${YELLOW}正在安装所需的核心软件包...${NC}"; yes | pkg install git nodejs-lts rsync zip termux-api coreutils gawk || fn_print_error_exit "核心依赖安装失败！"
    fn_print_success "核心依赖安装完毕。"
    fn_print_header "3/5: 下载 ST 主程序"
    if [ -d "$ST_DIR" ]; then 
        fn_print_warning "目录 $ST_DIR 已存在，跳过下载。"
    else
        local fastest_repo_url; fastest_repo_url=$(fn_find_fastest_mirror)
        echo -e "${YELLOW}正在从最快镜像下载主程序 (${REPO_BRANCH} 分支)...${NC}"
        git clone --depth 1 -b "$REPO_BRANCH" "$fastest_repo_url" "$ST_DIR" || fn_print_error_exit "主程序下载失败！请检查网络或更换镜像列表。"
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
    local fastest_repo_url; fastest_repo_url=$(fn_find_fastest_mirror)
    echo -e "${YELLOW}正在同步远程仓库地址为当前最快镜像...${NC}"
    git remote set-url origin "$fastest_repo_url"
    if [ $? -ne 0 ]; then fn_print_warning "同步远程地址失败，更新可能使用旧链接。"; fi
    echo -e "${YELLOW}正在拉取最新代码...${NC}"; git pull origin "$REPO_BRANCH"
    if [ $? -eq 0 ]; then fn_print_success "代码更新成功。"; echo -e "${YELLOW}正在同步依赖包...${NC}"; npm install --no-audit --no-fund --omit=dev; fn_print_success "依赖包更新完成。"; else fn_print_warning "代码更新失败，可能存在冲突。"; fi
    fn_press_any_key
}

# --- 模块：助手自我更新 ---
main_update_script() {
    clear; fn_print_header "更新助手脚本"
    echo -e "${YELLOW}正在从 Gitee 下载新版本...${NC}"
    local temp_file; temp_file=$(mktemp)
    curl -L -o "$temp_file" "$SCRIPT_URL"
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then rm -f "$temp_file"; fn_print_warning "下载失败，请检查网络。"; elif cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then rm -f "$temp_file"; fn_print_success "当前已是最新版本。"; else
        sed -i 's/\r$//' "$temp_file"; mv "$temp_file" "$SCRIPT_SELF_PATH"; chmod +x "$SCRIPT_SELF_PATH"; rm -f "$UPDATE_FLAG_FILE"
        echo -e "${GREEN}助手更新成功！正在自动重启...${NC}"; sleep 2; exec "$SCRIPT_SELF_PATH" --updated
    fi; fn_press_any_key
}

# --- 模块：后台更新检查 ---
check_for_updates_on_start() {
    ( local temp_file; temp_file=$(mktemp); if curl -L -s -o "$temp_file" "$SCRIPT_URL"; then if ! cmp -s "$SCRIPT_SELF_PATH" "$temp_file"; then touch "$UPDATE_FLAG_FILE"; else rm -f "$UPDATE_FLAG_FILE"; fi; fi; rm -f "$temp_file" ) &
}

# --- 模块：其它功能 ---
main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"; local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""; grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true || is_set=false
    if [[ "$1" == "set_default" ]]; then if ! $is_set; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"; fn_print_success "已设置 Termux 启动时自动运行本助手。"; fi; return; fi
    clear; fn_print_header "管理助手自启"; if $is_set; then echo -e "当前状态: ${GREEN}已启用${NC}"; read -p "是否取消自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then sed -i "/# SillyTavern 助手/d" "$BASHRC_FILE"; sed -i "\|$AUTOSTART_CMD|d" "$BASHRC_FILE"; fn_print_success "已取消自启。"; fi; else echo -e "当前状态: ${RED}未启用${NC}"; read -p "是否设置自启？ (y/n): " confirm; if [[ "$confirm" =~ ^[yY]$ ]]; then echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >> "$BASHRC_FILE"; fn_print_success "已成功设置自启。"; fi; fi; fn_press_any_key
}
main_open_docs() {
    clear; fn_print_header "查看帮助文档"; if fn_check_command "termux-open-url"; then termux-open-url "https://stdocs.723123.xyz"; fn_print_success "已调用浏览器打开文档。"; else fn_print_warning "命令 'termux-open-url' 不存在。"; echo "请先安装【Termux:API】应用及 'pkg install termux-api'。"; fi; fn_press_any_key
}

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

if [[ "$1" != "--no-check" ]]; then check_for_updates_on_start; fi
if [[ "$1" == "--updated" ]]; then clear; fn_print_success "助手已成功更新至最新版本！"; sleep 2; fi

while true; do
    clear
    echo -e "${CYAN}${BOLD}"; cat << "EOF"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v1.1      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    update_notice=""; if [ -f "$UPDATE_FLAG_FILE" ]; then update_notice=" ${YELLOW}[!] 有更新${NC}"; fi
    echo -e "${NC}"; echo -e "    选择一个操作来开始：\n";
    echo -e "      ${GREEN}[1]${NC} ${BOLD}启动 SillyTavern${NC}"; echo -e "      ${CYAN}[2]${NC} ${BOLD}数据管理${NC}"; echo -e "      ${YELLOW}[3]${NC} ${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [4] 更新 ST 主程序    [5] 更新助手脚本${update_notice}"; echo -e "      [6] 管理助手自启      [7] 查看帮助文档\n"
    echo -e "      ${RED}[0] 退出助手${NC}\n"; read -p "    请输入选项数字: " choice
    case $choice in
        1) main_start ;; 2) main_data_management_menu ;; 3) main_install ;; 4) main_update_st ;; 5) main_update_script ;; 6) main_manage_autostart ;; 7) main_open_docs ;; 0) echo -e "\n感谢使用，助手已退出。"; rm -f "$UPDATE_FLAG_FILE"; exit 0 ;; *) echo -e "\n${RED}无效输入，请重新选择。${NC}"; sleep 1.5 ;;
    esac
done
