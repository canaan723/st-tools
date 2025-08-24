#!/bin/bash

#
# Core 模块：应用程序的骨架和调度中心。
#

# --- 全局变量和常量 ---

# 定义全局只读路径变量
# APP_ROOT 变量应由 main.sh 设置并导出
readonly LOG_DIR="${APP_ROOT}/logs"
readonly LOG_FILE="${LOG_DIR}/app.log"
readonly LIBS_DIR="${APP_ROOT}/lib"
readonly MODULES_DIR="${APP_ROOT}/modules" # 暂时未使用，为未来模块化保留

# --- 核心功能函数 ---

# 加载 lib/ 目录下的所有库文件
#
# @no-params
# @return void
core_load_libs() {
    for lib_file in "${LIBS_DIR}"/*.sh; do
        # 确保文件存在且可读
        if [[ -f "${lib_file}" && -r "${lib_file}" ]]; then
            # 跳过加载自身，避免无限递归
            if [[ "$(basename "${lib_file}")" != "core.sh" ]]; then
                # 使用 source 命令加载库文件
                source "${lib_file}"
            fi
        fi
    done
}

# 应用程序的總初始化函数
#
# @no-params
# @return void
core_init() {
    # 确保日志目录存在 (依赖 utils.sh 中的函数)
    # util_ensure_dir_exists 函数将在 core_load_libs 调用后可用
    
    # 首先加载所有库文件
    core_load_libs
    
    # 加载库后调用工具函数
    util_ensure_dir_exists "${LOG_DIR}"
}

# 统一的日志记录接口
#
# @param $1 string 日志级别 (INFO, SUCCESS, WARNING, ERROR)
# @param $2 string 日志消息
# @return void
core_log() {
    local level="$1"
    local message="$2"
    
    # 获取当前时间戳
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 根据日志级别，调用 UI 模块函数在控制台打印消息
    case "${level}" in
        "INFO")
            ui_info "${message}"
            ;;
        "SUCCESS")
            ui_success "${message}"
            ;;
        "WARNING")
            ui_warning "${message}"
            ;;
        "ERROR")
            ui_error "${message}"
            ;;
        *)
            # 对于未知级别，默认为 INFO
            ui_info "${message}"
            level="UNKNOWN" # 在日志文件中标记为未知级别
            ;;
    esac
    
    # 将格式化的日志消息追加到日志文件中
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

# 应用主菜单和交互循环
#
# @no-params
# @return void
core_main_loop() {
    while true; do
        # 定义主菜单选项
        local main_menu_options=(
            "1. SillyTavern 管理"
            "2. 数据管理"
            "0. 退出"
        )
        
        # 调用 ui_menu 显示菜单并获取用户选择
        local choice
        choice=$(ui_menu "主菜单" "${main_menu_options[@]}")
        
        # 根据用户选择执行相应操作
        case "${choice}" in
            "1")
                ui_info "功能开发中..."
                ;;
            "2")
                ui_info "功能开发中..."
                ;;
            "0")
                # 退出循环
                break
                ;;
            *)
                # 处理无效输入
                ui_warning "无效输入，请重新选择。"
                ;;
        esac
    done
}