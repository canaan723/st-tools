#!/usr/bin/env bash

#
# UI 模块
#
# 负责提供所有与用户界面相关的功能，包括颜色输出、标准化消息、
# UI 元素渲染和用户交互。
# 设计原则：此模块不应包含任何业务逻辑。
#

# ==============================================================================
# 任务 1.3: 定义全局颜色变量
# ==============================================================================

# 颜色定义 (ANSI escape codes)
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[0;37m'

# ==============================================================================
# 阶段二: 标准化消息函数
# ==============================================================================

###
# 打印一条信息级别的消息。
# @param $1 消息内容
#
ui_info() {
    local message="$1"
    echo -e "${C_BLUE}[INFO]${C_RESET} ${message}"
}

###
# 打印一条成功级别的消息。
# @param $1 消息内容
#
ui_success() {
    local message="$1"
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} ${message}"
}

###
# 打印一条警告级别的消息。
# @param $1 消息内容
#
ui_warning() {
    local message="$1"
    echo -e "${C_YELLOW}[WARNING]${C_RESET} ${message}"
}

###
# 打印一条错误级别的消息。
# @param $1 消息内容
#
ui_error() {
    local message="$1"
    echo -e "${C_RED}[ERROR]${C_RESET} ${message}"
}

# ==============================================================================
# 阶段三: 通用 UI 元素
# ==============================================================================

###
# 打印一条横向分隔线。
# 默认宽度为 80 个字符。
#
ui_separator() {
    printf '%*s\n' 80 '' | tr ' ' '='
}

###
# 打印一个带标题的横幅。
# @param $1 横幅标题
#
ui_banner() {
    local title="== $1 =="
    local terminal_width=80
    local title_len=${#title}
    local padding=$(((terminal_width - title_len) / 2))

    ui_separator
    printf '%*s' $padding ''
    echo "$title"
    ui_separator
}

# ==============================================================================
# 阶段四: 用户交互函数
# ==============================================================================

###
# 暂停脚本执行，提示用户按任意键继续。
#
ui_press_any_key_to_continue() {
    echo "" # 确保提示在新的一行
    read -n 1 -s -r -p "按任意键继续..."
    echo "" # 确保后续输出在新的一行
}

###
# 显示提示并读取用户输入到一个变量中。
# 使用 nameref 来直接修改调用者作用域中的变量。
# @param $1 提示用户的消息
# @param $2 存储输入的变量名 (nameref)
#
ui_read_input() {
    local prompt_message="$1"
    local -n target_variable="$2" # 使用 nameref
    
    read -p "${prompt_message} " target_variable
}

# ==============================================================================
# 阶段五: 动态菜单函数
# ==============================================================================

###
# 动态生成一个菜单，并返回用户选择项对应的函数名。
#
# @param $1 菜单标题。
# @param $2 关联数组的名称（字符串），该数组的键是菜单项描述，值是对应的函数名。
# @return 返回用户选择的菜单项所关联的函数名。
#
# 使用示例:
#   declare -A MY_MENU=(
#       ["显示日期"]="show_date"
#       ["退出"]="exit"
#   )
#   local selected_func
#   selected_func=$(ui_menu "主菜单" MY_MENU)
#   $selected_func # 执行选择的函数
#
ui_menu() {
    local title="$1"
    local -n menu_items="$2" # 使用 nameref 引用关联数组

    echo "--- ${title} ---"

    # 使用一个索引数组来保证菜单项的顺序
    local options=()
    for key in "${!menu_items[@]}"; do
        options+=("$key")
    done
    
    # 打印菜单项
    for i in "${!options[@]}"; do
        printf "  %d. %s\n" "$((i+1))" "${options[$i]}"
    done

    # 读取用户选择
    local choice
    while true; do
        read -p "请输入选项 [1-${#options[@]}]: " choice
        # 验证输入是否为数字并且在有效范围内
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            # 根据用户的数字选择找到对应的菜单项描述
            local selected_option="${options[$((choice-1))]}"
            # 根据菜单项描述找到关联的函数名并返回
            echo "${menu_items[$selected_option]}"
            return 0
        else
            ui_error "无效输入，请输入 1 到 ${#options[@]} 之间的数字。"
        fi
    done
}