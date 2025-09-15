#!/data/data/com.termux/files/usr/bin/bash

# SillyTavern 助手 v1.80
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
CONFIG_FILE="$HOME/.st_assistant.conf"
UPDATE_FLAG_FILE="/data/data/com.termux/files/usr/tmp/.st_assistant_update_flag"
CACHED_MIRRORS=()

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

    fn_print_warning "开始测试 Git 镜像连通性与速度..." >&2
    local github_url="https://github.com/SillyTavern/SillyTavern.git"
    local temp_sorted_list=()

    if [[ " ${MIRROR_LIST[*]} " =~ " ${github_url} " ]]; then
        echo -e "  [1/?] 正在优先测试 GitHub 官方源..." >&2
        if timeout 15s git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
            fn_print_success "GitHub 官方源直连可用，将优先使用！" >&2
            temp_sorted_list=("$github_url")
        else
            fn_print_error "GitHub 官方源连接超时，将测试其他镜像..." >&2
        fi
    fi

    if [ ${#temp_sorted_list[@]} -gt 0 ]; then
        CACHED_MIRRORS=("${temp_sorted_list[@]}")
        printf '%s\n' "${CACHED_MIRRORS[@]}"
        return 0
    fi

    local other_mirrors=()
    for mirror in "${MIRROR_LIST[@]}"; do
        [[ "$mirror" != "$github_url" ]] && other_mirrors+=("$mirror")
    done

    if [ ${#other_mirrors[@]} -eq 0 ]; then
        fn_print_error "没有其他可用的镜像进行测试。" >&2
        return 1
    fi

    echo -e "${YELLOW}已启动并行测试，等待所有镜像响应...${NC}" >&2
    local results_file
    results_file=$(mktemp)
    local pids=()

    for mirror_url in "${other_mirrors[@]}"; do
        (
            local mirror_host
            mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
            local start_time
            start_time=$(date +%s.%N)
            if timeout 15s git ls-remote "$mirror_url" HEAD >/dev/null 2>&1; then
                local end_time
                end_time=$(date +%s.%N)
                local elapsed_time
                elapsed_time=$(echo "$end_time - $start_time" | bc)
                echo "$elapsed_time $mirror_url" >>"$results_file"
                echo -e "  [${GREEN}✓${NC}] 测试成功: ${CYAN}${mirror_host}${NC} - 耗时 ${GREEN}${elapsed_time}s${NC}" >&2
            else
                echo -e "  [${RED}✗${NC}] 测试失败: ${CYAN}${mirror_host}${NC} - ${RED}连接超时或无效${NC}" >&2
            fi
        ) &
        pids+=($!)
    done

    wait "${pids[@]}"

    if [ ! -s "$results_file" ]; then
        fn_print_error "所有镜像都无法连接。" >&2
        rm -f "$results_file"
        return 1
    fi

    local fastest_line
    fastest_line=$(sort -n "$results_file" | head -n 1)
    fn_print_success "已选定最快镜像: $(echo "$fastest_line" | awk '{print $2}' | sed -e 's|https://||' -e 's|/.*$||') (耗时 $(echo "$fastest_line" | awk '{print $1}')s)" >&2
    mapfile -t temp_sorted_list < <(sort -n "$results_file" | awk '{print $2}')
    rm -f "$results_file"

    if [ ${#temp_sorted_list[@]} -gt 0 ]; then
        CACHED_MIRRORS=("${temp_sorted_list[@]}")
        printf '%s\n' "${CACHED_MIRRORS[@]}"
    else
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
#   核心功能模块
# =========================================================================

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
    echo -e "${YELLOW}首次启动或更新后会自动安装依赖，耗时可能较长...${NC}"

    bash start.sh

    echo -e "\n${YELLOW}SillyTavern 已停止运行。${NC}"
    fn_press_any_key
}

fn_create_data_zip_backup() {
    fn_print_warning "正在创建核心数据备份 (.zip)..."
    if [ ! -d "$ST_DIR" ]; then
        fn_print_error "SillyTavern 目录不存在，无法备份。"
        return 1
    fi

    local paths_to_backup=("./data" "./public/scripts/extensions/third-party" "./plugins" "./config.yaml")
    mkdir -p "$BACKUP_ROOT_DIR"
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_核心数据_${timestamp}.zip"
    local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}"

    cd "$ST_DIR" || {
        fn_print_error "无法进入 SillyTavern 目录进行备份。"
        return 1
    }

    local has_files=false
    for item in "${paths_to_backup[@]}"; do
        if [ -e "$item" ]; then
            has_files=true
            break
        fi
    done

    if ! $has_files; then
        fn_print_error "未能收集到任何有效的数据文件进行备份。"
        cd "$HOME"
        return 1
    fi

    local exclude_params=(-x "*/_cache/*" -x "*.log" -x "*/backups/*")
    if zip -rq "$backup_zip_path" "${paths_to_backup[@]}" "${exclude_params[@]}"; then
        fn_print_success "核心数据备份成功: ${backup_name}"
        cd "$HOME"
        echo "$backup_zip_path"
        return 0
    else
        fn_print_error "创建 .zip 备份失败！"
        cd "$HOME"
        return 1
    fi
}

main_install() {
    local auto_start=true
    if [[ "$1" == "no-start" ]]; then
        auto_start=false
    fi

    clear
    fn_print_header "SillyTavern 部署向导"

    if [[ "$auto_start" == "true" ]]; then
        while true; do
            if ! fn_update_source_with_retry; then
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

    fn_print_header "3/5: 下载 ST 主程序"
    if [ -f "$ST_DIR/start.sh" ]; then
        fn_print_warning "检测到完整的 SillyTavern 安装，跳过下载。"
    elif [ -d "$ST_DIR" ] && [ -n "$(ls -A "$ST_DIR")" ]; then
        fn_print_error_exit "目录 $ST_DIR 已存在但安装不完整。请手动删除该目录后再试。"
    else
        local download_success=false
        while ! $download_success; do
            mapfile -t sorted_mirrors < <(fn_find_fastest_mirror)
            if [ ${#sorted_mirrors[@]} -eq 0 ]; then
                read -p $'\n'"${RED}所有 Git 镜像均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice
                if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                    fn_print_error_exit "下载失败，用户取消操作。"
                fi
                CACHED_MIRRORS=()
                continue
            fi
            for mirror_url in "${sorted_mirrors[@]}"; do
                local mirror_host
                mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
                fn_print_warning "正在尝试从镜像 [${mirror_host}] 下载 (${REPO_BRANCH} 分支)..."
                if git clone --depth 1 -b "$REPO_BRANCH" "$mirror_url" "$ST_DIR"; then
                    fn_print_success "主程序下载完成。"
                    download_success=true
                    break
                else
                    fn_print_error "使用镜像 [${mirror_host}] 下载失败！正在切换..."
                    rm -rf "$ST_DIR"
                fi
            done
            if ! $download_success; then
                read -p $'\n'"${RED}所有线路均下载失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice
                if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                    fn_print_error_exit "下载失败，用户取消操作。"
                fi
                CACHED_MIRRORS=()
            fi
        done
    fi

    fn_print_header "4/5: 配置并安装依赖"
    if [ -d "$ST_DIR" ]; then
        if ! fn_run_npm_install_with_retry; then
            fn_print_error_exit "依赖安装最终失败，部署中断。"
        fi
    else
        fn_print_warning "SillyTavern 目录不存在，跳过此步。"
    fi

    if $auto_start; then
        fn_print_header "5/5: 设置快捷方式与自启"
        fn_create_shortcut
        main_manage_autostart "set_default"
        echo -e "\n${GREEN}${BOLD}部署完成！即将进行首次启动...${NC}"
        sleep 3
        main_start
    else
        fn_print_success "全新版本下载与配置完成。"
    fi
}

main_update_st() {
    clear
    fn_print_header "更新 SillyTavern 主程序"
    if [ ! -d "$ST_DIR/.git" ]; then
        fn_print_warning "未找到Git仓库，请先完整部署。"
        fn_press_any_key
        return
    fi

    cd "$ST_DIR" || fn_print_error_exit "无法进入 SillyTavern 目录: $ST_DIR"
    local update_success=false
    while ! $update_success; do
        mapfile -t sorted_mirrors < <(fn_find_fastest_mirror)
        if [ ${#sorted_mirrors[@]} -eq 0 ]; then
            read -p $'\n'"${RED}所有 Git 镜像均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice
            if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                fn_print_warning "更新失败，用户取消操作。"
                fn_press_any_key
                return
            fi
            CACHED_MIRRORS=()
            continue
        fi

        local pull_attempted_in_loop=false
        for mirror_url in "${sorted_mirrors[@]}"; do
            local mirror_host
            mirror_host=$(echo "$mirror_url" | sed -e 's|https://||' -e 's|/.*$||')
            fn_print_warning "正在尝试使用镜像 [${mirror_host}] 更新..."
            git remote set-url origin "$mirror_url"

            local git_output
            git_output=$(git pull origin "$REPO_BRANCH" 2>&1)
            if [ $? -eq 0 ]; then
                fn_print_success "代码更新成功。"
                if fn_run_npm_install_with_retry; then
                    update_success=true
                fi
                break
            else
                if echo "$git_output" | grep -qE "overwritten by merge|Please commit|unmerged files"; then
                    clear
                    fn_print_header "检测到更新冲突！"
                    fn_print_warning "原因: 你可能修改过酒馆的文件，导致无法自动合并新版本。"
                    echo "--- 冲突文件预览 ---"
                    echo "$git_output" | grep -E "^\s+" | head -n 5
                    echo "--------------------"
                    echo -e "\n请选择操作方式："
                    echo -e "  [${GREEN}回车${NC}] ${BOLD}自动备份并重新安装 (推荐)${NC}"
                    echo -e "  [1]    ${YELLOW}强制覆盖更新 (危险)${NC}"
                    echo -e "  [0]    ${CYAN}放弃更新${NC}"
                    read -p "请输入选项: " choice

                    case "$choice" in
                    "" | 'b' | 'B')
                        clear
                        fn_print_header "步骤 1/5: 创建核心数据备份"
                        local data_backup_zip_path
                        data_backup_zip_path=$(fn_create_data_zip_backup)
                        if [ -z "$data_backup_zip_path" ]; then
                            fn_print_error_exit "核心数据备份(.zip)创建失败，更新流程终止。"
                        fi

                        fn_print_header "步骤 2/5: 完整备份当前目录"
                        local renamed_backup_dir="${ST_DIR}_backup_$(date +%Y%m%d%H%M%S)"
                        cd "$HOME"
                        mv "$ST_DIR" "$renamed_backup_dir" || fn_print_error_exit "备份失败！请检查权限或手动重命名后重试。"
                        fn_print_success "旧目录已完整备份为: $(basename "$renamed_backup_dir")"

                        fn_print_header "步骤 3/5: 下载并安装新版 SillyTavern"
                        main_install "no-start"
                        if [ ! -d "$ST_DIR" ]; then
                            fn_print_error_exit "新版本安装失败，流程终止。"
                        fi

                        fn_print_header "步骤 4/5: 自动恢复用户数据"
                        fn_print_warning "正在将备份数据解压至新目录..."
                        if ! unzip -o "$data_backup_zip_path" -d "$ST_DIR" >/dev/null 2>&1; then
                            fn_print_error_exit "数据恢复失败！请检查zip文件是否有效。"
                        fi
                        fn_print_success "用户数据已成功恢复到新版本中。"

                        fn_print_header "步骤 5/5: 更新完成，请确认"
                        fn_print_success "SillyTavern 已更新并恢复数据！"
                        fn_print_warning "请注意:"
                        echo -e "  - 您的聊天记录、角色卡、插件和设置已恢复。"
                        echo -e "  - 如果您曾手动修改过酒馆核心文件(如 server.js)，这些修改需要您重新操作。"
                        echo -e "  - 您的完整旧版本已备份在: ${CYAN}$(basename "$renamed_backup_dir")${NC}"
                        echo -e "  - 本次恢复所用的核心数据备份位于: ${CYAN}$(basename "$BACKUP_ROOT_DIR")/$(basename "$data_backup_zip_path")${NC}"

                        echo -e "\n${CYAN}请按任意键，启动更新后的 SillyTavern...${NC}"
                        read -n 1 -s
                        main_start
                        return
                        ;;
                    '1')
                        fn_print_warning "正在执行强制覆盖 (git reset --hard)..."
                        if git reset --hard "origin/$REPO_BRANCH" && git pull origin "$REPO_BRANCH"; then
                            fn_print_success "强制更新成功。"
                            if fn_run_npm_install_with_retry; then
                                update_success=true
                            fi
                        else
                            fn_print_error "强制更新失败！"
                        fi
                        pull_attempted_in_loop=true
                        break
                        ;;
                    *)
                        fn_print_warning "已取消更新。"
                        fn_press_any_key
                        return
                        ;;
                    esac
                else
                    fn_print_error "使用镜像 [${mirror_host}] 更新失败！错误: $(echo "$git_output" | tail -n 1)"
                    fn_print_error "正在切换下一条线路..."
                    sleep 1
                fi
            fi
        done

        if $pull_attempted_in_loop; then
            break
        fi

        if ! $update_success; then
            read -p $'\n'"${RED}所有线路均更新失败。是否重新测速并重试？(直接回车=是, 输入n=否): ${NC}" retry_choice
            if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                fn_print_warning "更新失败，用户取消操作。"
                break
            fi
            CACHED_MIRRORS=()
        fi
    done

    if $update_success; then
        fn_print_success "SillyTavern 更新完成！"
    fi
    fn_press_any_key
}

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
        fn_print_header "请选择要备份的内容"
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
        echo -e "      ${GREEN}[回车] 开始备份${NC}      ${RED}[0] 取消备份${NC}"
        read -p "请操作 [输入数字, 回车 或 0]: " user_choice
        case "$user_choice" in
        "" | [sS])
            break
            ;;
        0)
            echo "备份已取消。"
            fn_press_any_key
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
                fn_print_warning "无效输入。"
                sleep 1
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
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M")
    local backup_name="ST_备份_${timestamp}"
    local backup_zip_path="${BACKUP_ROOT_DIR}/${backup_name}.zip"

    echo -e "\n${YELLOW}正在根据您的选择压缩文件...${NC}"
    echo "包含项目:"
    for item in "${paths_to_backup[@]}"; do
        echo "  - $item"
    done

    local exclude_params=(-x "*/_cache/*" -x "*.log" -x "*/backups/*")
    zip -rq "$backup_zip_path" "${paths_to_backup[@]}" "${exclude_params[@]}"
    if [ $? -ne 0 ]; then
        fn_print_warning "备份失败！"
        fn_press_any_key
        return
    fi

    mapfile -t all_backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -name "*.zip" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    fn_print_success "备份成功：${backup_name}.zip (当前备份数: ${#all_backups[@]}/${BACKUP_LIMIT})"
    printf "%s\n" "${paths_to_backup[@]}" >"$CONFIG_FILE"

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

main_migration_guide() {
    clear
    fn_print_header "数据迁移 / 恢复指南"
    echo -e "${YELLOW}请遵循以下步骤，将您的数据从旧设备迁移到新设备，或恢复备份：${NC}"
    echo -e "  1. 在旧设备上，用MT管理器等文件工具，进入目录：\n     ${CYAN}${BACKUP_ROOT_DIR}/${NC}"
    echo -e "  2. 找到需要的备份压缩包 (例如 ST_核心数据_xxxx.zip)，并将其发送到新设备。"
    echo -e "  3. 在新设备上，将这个压缩包移动或复制到 SillyTavern 的根目录：\n     ${CYAN}${ST_DIR}/${NC}"
    echo -e "  4. 使用 MT 管理器等工具，将压缩包 ${GREEN}“解压到当前目录”${NC}。"
    echo -e "  5. 如果提示文件已存在，请选择 ${YELLOW}“全部覆盖”${NC}。"
    echo -e "  6. 操作完成后，重启 SillyTavern 即可看到所有数据。"
    echo -e "\n${YELLOW}如需更详细的图文教程，请在主菜单选择 [7] 查看帮助文档。${NC}"
    fn_press_any_key
}

run_delete_backup() {
    clear
    fn_print_header "删除旧备份"
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
            local size
            size=$(du -h "$file" | cut -f1)
            printf "    [%-2d] %-40s (%s)\n" "$((++i))" "$(basename "$file")" "$size"
        fi
    done

    read -p "输入要删除的备份编号 (其他键取消): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        echo "操作已取消."
        fn_press_any_key
        return
    fi

    local chosen_backup="${backup_files[$((choice - 1))]}"
    read -p "确认删除 '$(basename "$chosen_backup")' 吗？(y/n): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        rm "$chosen_backup"
        fn_print_success "备份已删除。"
    else
        echo "操作已取消。"
    fi
    fn_press_any_key
}

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
        *)
            echo -e "${RED}无效输入。${NC}"
            sleep 1
            ;;
        esac
    done
}

main_update_script() {
    clear
    fn_print_header "更新助手脚本"
    echo -e "${YELLOW}正在从 Gitee 下载新版本...${NC}"
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

fn_create_shortcut() {
    local BASHRC_FILE="$HOME/.bashrc"
    local ALIAS_CMD="alias st='\"$SCRIPT_SELF_PATH\"'"
    local ALIAS_COMMENT="# SillyTavern 助手快捷命令"
    if ! grep -qF "$ALIAS_CMD" "$BASHRC_FILE"; then
        chmod +x "$SCRIPT_SELF_PATH"
        echo -e "\n$ALIAS_COMMENT\n$ALIAS_CMD" >>"$BASHRC_FILE"
        fn_print_success "已创建快捷命令 'st'。请重启 Termux 或执行 'source ~/.bashrc' 生效。"
    fi
}

main_manage_autostart() {
    local BASHRC_FILE="$HOME/.bashrc"
    local AUTOSTART_CMD="[ -f \"$SCRIPT_SELF_PATH\" ] && \"$SCRIPT_SELF_PATH\""
    local is_set=false
    grep -qF "$AUTOSTART_CMD" "$BASHRC_FILE" && is_set=true

    if [[ "$1" == "set_default" ]]; then
        if ! $is_set; then
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"
            fn_print_success "已设置 Termux 启动时自动运行本助手。"
        fi
        return
    fi

    clear
    fn_print_header "管理助手自启"
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
            echo -e "\n# SillyTavern 助手\n$AUTOSTART_CMD" >>"$BASHRC_FILE"
            fn_print_success "已成功设置自启。"
        fi
    fi
    fn_press_any_key
}

main_open_docs() {
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

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

if [[ "$1" != "--no-check" && "$1" != "--updated" ]]; then
    check_for_updates_on_start
fi
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
    ║      SillyTavern 助手 v1.8      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
EOF
    update_notice=""
    if [ -f "$UPDATE_FLAG_FILE" ]; then
        update_notice=" ${YELLOW}[!] 有更新${NC}"
    fi

    echo -e "${NC}\n    选择一个操作来开始：\n"
    echo -e "      [1] ${GREEN}${BOLD}启动 SillyTavern${NC}"
    echo -e "      [2] ${CYAN}${BOLD}数据管理${NC}"
    echo -e "      [3] ${YELLOW}${BOLD}首次部署 (全新安装)${NC}\n"
    echo -e "      [4] 更新 ST 主程序    [5] 更新助手脚本${update_notice}"
    echo -e "      [6] 管理助手自启      [7] 查看帮助文档\n"
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
    0)
        echo -e "\n感谢使用，助手已退出。"
        rm -f "$UPDATE_FLAG_FILE"
        exit 0
        ;;
    *)
        fn_print_warning "无效输入，请重新选择。"
        sleep 1.5
        ;;
    esac
done
