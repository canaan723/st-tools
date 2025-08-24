#!/bin/bash
#
# 通用辅助函数库
# 提供与具体业务无关的、可在整个应用程序中复用的基础功能。
#

# 检查一个命令是否存在
# @param $1 command_name - 需要检查的命令名称
# @return 0 (成功) 如果命令存在, 1 (失败) 如果命令不存在
util_check_command() {
    command -v "$1" &>/dev/null
}

# 获取操作系统类型
# @return 通过 echo 输出 "linux", "darwin", 或 "unknown"
util_get_os_type() {
    case "$(uname -s)" in
        Linux)
            echo "linux"
            ;;
        Darwin)
            echo "darwin"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 检查文件或目录是否存在
# @param $1 path - 需要检查的文件或目录路径
# @return 0 (成功) 如果路径存在, 1 (失败) 如果路径不存在
util_file_exists() {
    [ -e "$1" ]
}

# 确保目录存在，如果不存在则创建
# @param $1 dir_path - 需要确保存在的目录路径
# @return 0 (成功) 目录已存在或创建成功, 1 (失败) 目录创建失败
util_ensure_dir_exists() {
    # 如果目录已经存在，直接返回成功
    if [ -d "$1" ]; then
        return 0
    fi
    # 否则，尝试创建目录，并返回 mkdir 命令自身的退出码
    mkdir -p "$1"
}