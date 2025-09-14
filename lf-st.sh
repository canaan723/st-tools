#!/bin/bash

# --- 脚本开始 ---
echo "----------------------------------------------------------------"
echo "这是一个 leaflow 云酒馆 (SillyTavern) 一键配置脚本"
echo "请勿用于其他用途。"
echo
echo "by Qingjue | XHS:826702880"
echo "----------------------------------------------------------------"
echo

# 默认的配置文件路径
CONFIG_FILE="/mnt/config/config.yaml"

# --- 1. 检查并确认配置文件路径 ---
# 循环直到找到一个有效的文件路径或用户选择退出
while [ ! -f "$CONFIG_FILE" ]; do
    echo "错误：在默认路径 '$CONFIG_FILE' 未找到配置文件。"
    
    # 询问用户是提供新路径还是退出，回车默认为 'N'
    read -p "是否要指定一个新的文件路径？ (y/N): " choice
    
    # 如果用户直接回车，choice变量为空，将按 N 处理
    case "$choice" in
        [Yy]* )
            # 请求用户输入新的路径
            read -p "请输入正确的配置文件完整路径: " CONFIG_FILE
            # 如果用户输入了路径但仍然是空的，提示并继续循环
            if [ -z "$CONFIG_FILE" ]; then
                echo "输入为空，请重新操作。"
            fi
            ;;
        [Nn]* | "" ) # 匹配 'n', 'N', 或空输入 (回车)
            # 用户选择退出
            echo "操作已取消，退出脚本。"
            exit 1
            ;;
        * )
            # 无效输入
            echo "无效输入，请输入 'y' 或 'n'。"
            ;;
    esac
    echo # 增加一个空行以改善可读性
done

echo "成功定位配置文件: $CONFIG_FILE"
echo "----------------------------------------------------------------"


# --- 2. 获取用户输入 ---
echo "请输入认证信息（注意：密码将明文显示在屏幕上）："
read -p "请输入新的用户名: " NEW_USERNAME
read -p "请输入新的密码: " NEW_PASSWORD

# 检查用户名和密码是否为空
if [ -z "$NEW_USERNAME" ] || [ -z "$NEW_PASSWORD" ]; then
    echo "错误：用户名和密码均不能为空。操作已终止。"
    exit 1
fi

echo "----------------------------------------------------------------"
echo "信息确认完毕，准备执行修改..."
sleep 1 # 短暂暂停，让用户看到信息


# --- 3. 使用 sed 执行修改 ---
# 使用 '#' 作为 sed 的分隔符，以避免密码中的 '/' 字符导致命令出错
# -i 表示直接修改文件 (in-place)
# -e 表示执行一个表达式，可以连接多个 -e
sed -i \
    -e 's#^\(listen:\s*\)false#\1true#' \
    -e 's#^\(whitelistMode:\s*\)true#\1false#' \
    -e 's#^\(basicAuthMode:\s*\)false#\1true#' \
    -e "s#^\(\s*username:\s*\).*#\1\"$NEW_USERNAME\"#" \
    -e "s#^\(\s*password:\s*\).*#\1\"$NEW_PASSWORD\"#" \
    -e 's#^\(sessionTimeout:\s*\).*#\186400#' \
    -e 's#^\(\s*numberOfBackups:\s*\).*#\15#' \
    -e 's#^\(\s*lazyLoadCharacters:\s*\)false#\1true#' \
    "$CONFIG_FILE"

# 检查 sed 命令是否成功执行
if [ $? -ne 0 ]; then
    echo "严重错误：在修改文件 '$CONFIG_FILE' 时发生未知错误。"
    echo "文件可能未被修改或已损坏，请手动检查。"
    exit 1
fi


# --- 4. 显示结果 ---
echo "成功！配置文件 '$CONFIG_FILE' 修改完成。"
echo "----------------------------------------------------------------"
echo "已更新的配置详情："
echo
echo "  - listen: true                (作用：允许外部网络访问酒馆)"
echo "  - whitelistMode: false         (作用：关闭IP白名单，允许任意IP访问)"
echo "  - basicAuthMode: true           (作用：启用基础登录认证，使用用户名和密码登录)"
echo "  - sessionTimeout: 86400       (作用：会话超时，24小时无操作后需重新登录)"
echo "  - numberOfBackups: 5           (作用：单个角色聊天记录的备份文件保留数量)"
echo "  - lazyLoadCharacters: true    (作用：启用角色卡懒加载，加快启动速度)"
echo
echo "----------------------------------------------------------------"
echo "重要：请务必记录登录凭证！"
echo
echo "  用户名: $NEW_USERNAME"
echo "  密  码: $NEW_PASSWORD"
echo
echo "----------------------------------------------------------------"

exit 0
