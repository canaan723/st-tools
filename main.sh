#!/bin/bash

#
# 应用程序主入口脚本
#

# --- 应用程序初始化 ---

# 获取脚本所在目录的绝对路径，并将其设置为应用程序根目录
# export 该变量使其对所有 source 的子脚本可见
export APP_ROOT
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# 加载核心库
# 必须先设置好 APP_ROOT，core.sh 中的路径变量依赖它
source "${APP_ROOT}/lib/core.sh"

# 执行初始化 (此函数会加载所有其他库)
core_init

# --- 主程序执行 ---

# 记录启动日志
core_log "INFO" "应用程序启动。"

# 进入主循环
core_main_loop

# --- 应用程序关闭 ---

# 记录退出日志
core_log "INFO" "应用程序关闭。"

# 正常退出
exit 0