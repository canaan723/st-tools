#!/bin/bash

# Copyright (c) 2025 清绝 (QingJue) <blog.qjyg.de>
# This script is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
# To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
#
# 郑重声明：
# 本脚本为免费开源项目，仅供个人学习和非商业用途使用。
# 未经作者授权，严禁将本脚本或其修改版本用于任何形式的商业盈利行为（包括但不限于倒卖、付费部署服务等）。
# 任何违反本协议的行为都将受到法律追究。

# --- 颜色定义 ---
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'

# --- 全局配置 ---
UNIFIED_STORAGE_DIR="/mnt/sillytavern"

CONFIG_FILE="$UNIFIED_STORAGE_DIR/config/config.yaml"
DATA_DIR="$UNIFIED_STORAGE_DIR/data"
TARGET_DIR_NAME="default-user"
TARGET_DIR_PATH="$DATA_DIR/$TARGET_DIR_NAME"
BACKUP_NAME="${TARGET_DIR_NAME}.bak"
BACKUP_PATH="$DATA_DIR/$BACKUP_NAME"
ZIP_FILE_NAME="${TARGET_DIR_NAME}.zip"
ZIP_FILE_PATH="$DATA_DIR/$ZIP_FILE_NAME"

fn_set_permissions() {
    echo -e "${BLUE}--- 权限自动检查与设置 ---${NC}"
    
    if [ ! -d "$UNIFIED_STORAGE_DIR" ]; then
        echo -e "${YELLOW}[警告]${NC} 存储目录 '${BOLD}$UNIFIED_STORAGE_DIR${NC}' 不存在。"
        echo -e "请确认脚本顶部的路径配置是否正确。将跳过权限设置。"
        read -p "按 Enter 键继续..."
        return
    fi

    local current_owner=$(stat -c '%U' "$UNIFIED_STORAGE_DIR")
    if [ "$current_owner" == "$(whoami)" ]; then
        echo -e "${GREEN}✓ 权限正确，目录所有者已是当前用户 (${BOLD}$(whoami)${NC})。无需修改。${NC}\n"
        sleep 1
        return
    fi

    echo -e "${YELLOW}[操作]${NC} 检测到目录所有者为 '${BOLD}$current_owner${NC}'，将尝试变更为当前用户 '${BOLD}$(whoami)${NC}'..."
    echo -e "这需要管理员权限，您可能需要输入密码。"
    
    if sudo chown -R "$(whoami):$(id -gn)" "$UNIFIED_STORAGE_DIR"; then
        echo -e "${GREEN}✓ 权限设置成功！${NC} 您现在可以使用当前用户通过文件管理器操作此目录了。\n"
    else
        echo -e "\n${RED}[错误]${NC} 权限设置失败。"
        echo -e "这可能是因为您输入的密码错误，或者当前用户没有 sudo 权限。"
        echo -e "${YELLOW}[提示]${NC} 您在后续操作中可能会遇到文件权限问题。"
        read -p "按 Enter 键继续..."
    fi
}


# --- 功能一：配置酒馆设置 (config.yaml) ---
fn_configure_settings() {
    tput reset
    echo -e "${CYAN}--- 功能: 配置酒馆设置 (config.yaml) ---${NC}\n"
    
    local current_config_file="$CONFIG_FILE"

    # 步骤 1: 定位配置文件
    echo -e "${BLUE}--- 步骤 1/4: 定位配置文件 ---${NC}"
    while [ ! -f "$current_config_file" ]; do
        echo -e "${RED}[错误]${NC} 在默认路径 '${BOLD}$current_config_file${NC}' 未找到配置文件。"
        echo -e "${YELLOW}[提示]${NC} 请检查脚本顶部的 'UNIFIED_STORAGE_DIR' 变量是否设置正确。"
        read -p "$(echo -e "${YELLOW}[操作]${NC} 是否要手动指定一个新的文件路径？ (y/N): ")" choice
        case "$choice" in
            [Yy]* ) read -p "$(echo -e "${YELLOW}[输入]${NC} 请输入正确的配置文件完整路径: ")" current_config_file
                    if [ -z "$current_config_file" ]; then echo -e "${RED}[提示]${NC} 输入为空，请重新操作。"; fi;;
            [Nn]* | "" ) echo -e "\n${RED}操作已取消，返回主菜单。${NC}"; return;;
            * ) echo -e "${RED}[提示]${NC} 无效输入，请输入 'y' 或 'n'。";;
        esac; echo
    done
    echo -e "${GREEN}✓ 成功定位配置文件: ${BOLD}$current_config_file${NC}\n"

    # 步骤 2: 设定登录凭证
    echo -e "${BLUE}--- 步骤 2/4: 设定登录凭证 ---${NC}"
    read -p "$(echo -e "${YELLOW}[输入]${NC} 请输入新的用户名: ")" NEW_USERNAME
    read -p "$(echo -e "${YELLOW}[输入]${NC} 请输入新的密码: ")" NEW_PASSWORD
    if [ -z "$NEW_USERNAME" ] || [ -z "$NEW_PASSWORD" ]; then
        echo -e "\n${RED}[错误] 用户名和密码均不能为空。操作已终止。${NC}"; return
    fi; echo

    # 步骤 3: 应用配置更改
    echo -e "${BLUE}--- 步骤 3/4: 应用配置更改 ---${NC}"
    echo -e "${YELLOW}[操作]${NC} 信息确认完毕，正在执行修改..."
    sleep 1
    sed -i \
        -e 's#^\(listen:\s*\)false#\1true#' \
        -e 's#^\(whitelistMode:\s*\)true#\1false#' \
        -e 's#^\(basicAuthMode:\s*\)false#\1true#' \
        -e "s#^\(\s*username:\s*\).*#\1\"$NEW_USERNAME\"#" \
        -e "s#^\(\s*password:\s*\).*#\1\"$NEW_PASSWORD\"#" \
        -e 's#^\(sessionTimeout:\s*\).*#\186400#' \
        -e 's#^\(\s*numberOfBackups:\s*\).*#\15#' \
        -e 's#^\(\s*lazyLoadCharacters:\s*\)false#\1true#' \
        "$current_config_file"
    if [ $? -ne 0 ]; then
        echo -e "\n${RED}[错误] 在修改文件时发生未知错误。${NC}"; return
    fi
    echo -e "${GREEN}✓ 配置文件修改成功！${NC}\n"

    # 步骤 4: 查看配置结果
    echo -e "${BLUE}--- 步骤 4/4: 查看配置结果 ---${NC}"
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                ${BOLD}配置完成！请查收！${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}\n"
    echo -e "${BOLD}已更新的配置详情：${NC}"
    printf "  - ${GREEN}%-28s${NC} %s\n" "listen: true" "(【基础】允许外部网络访问酒馆)"
    printf "  - ${GREEN}%-28s${NC} %s\n" "whitelistMode: false" "(【基础】关闭IP白名单，允许任意IP访问)"
    printf "  - ${GREEN}%-28s${NC} %s\n" "basicAuthMode: true" "(【基础】启用基础登录认证)"
    printf "  - ${GREEN}%-28s${NC} %s\n" "sessionTimeout: 86400" "(【安全】24小时无操作后需重新登录)"
    printf "  - ${GREEN}%-28s${NC} %s\n" "numberOfBackups: 5" "(【性能】单个聊天记录的备份保留数量)"
    printf "  - ${GREEN}%-28s${NC} %s\n" "lazyLoadCharacters: true" "(【性能】启用角色卡懒加载，加快启动)"
    echo
    echo -e "${YELLOW}=====================【 重要：请记录登录凭证 】=====================${NC}"
    echo -e "\n  ${BOLD}用户名 : ${CYAN}$NEW_USERNAME${NC}"
    echo -e "  ${BOLD}密  码 : ${CYAN}$NEW_PASSWORD${NC}\n"
    echo -e "${YELLOW}=====================================================================${NC}\n"
    echo -e "${RED}${BOLD}【重要提示】配置已保存，必须重启容器才能生效！${NC}"
}

# --- 功能二：安全替换用户数据 ---
fn_handle_backup() {
    if [ ! -d "$TARGET_DIR_PATH" ]; then
        echo -e "${YELLOW}[提示]${NC} 原始目录 '$TARGET_DIR_PATH' 不存在，无需备份。"
        return 0
    fi

    while [ -d "$BACKUP_PATH" ]; do
        echo -e "${YELLOW}[警告]${NC} 备份目录 '${BOLD}$BACKUP_NAME${NC}' 已存在。"
        read -p "请选择操作: [D]删除旧备份并继续, [R]我手动改名后继续, [C]取消操作: " backup_choice
        case "$backup_choice" in
            [Dd]*)
                echo -e "${YELLOW}[操作]${NC} 正在删除旧备份..."
                rm -rf "$BACKUP_PATH"
                echo -e "${GREEN}✓ 旧备份已删除。${NC}"
                break
                ;;
            [Rr]*)
                echo -e "${YELLOW}请在另一个终端窗口中将 '${BACKUP_NAME}' 重命名或移走。${NC}"
                read -p "操作完成后，按 Enter 键继续..."
                ;;
            [Cc]*)
                echo -e "${RED}操作已取消。${NC}"
                return 1
                ;;
            *) echo -e "${RED}无效输入。${NC}";;
        esac
    done

    echo -e "${BLUE}[操作]${NC} 正在备份 '$TARGET_DIR_PATH' -> '${BOLD}$BACKUP_NAME${NC}'..."
    if mv "$TARGET_DIR_PATH" "$BACKUP_PATH"; then
        echo -e "${GREEN}✓ 备份成功！${NC}"
        return 0
    else
        echo -e "${RED}[错误]${NC} 备份失败！请检查权限。"
        return 1
    fi
}

fn_replace_data() {
    tput reset
    echo -e "${CYAN}--- 功能: 安全替换 '${TARGET_DIR_NAME}' 用户数据 ---${NC}\n"
    
    # 步骤 0: 显示初始状态
    echo -e "${BLUE}--- 操作前 '${DATA_DIR}' 目录状态 ---${NC}"
    ls -lh "$DATA_DIR"
    echo
    read -p "请检查以上目录状态，按 Enter 键开始替换流程..."
    echo

    # 步骤 1: 备份
    if ! fn_handle_backup; then return; fi
    echo

    # 步骤 2: 引导上传
    echo -e "${BLUE}--- 步骤 2/4: 上传数据包 ---${NC}"
    echo -e "您可以使用 ${BOLD}任何方式${NC} (如 WinSCP, WindTerm 等) 将 '${BOLD}$ZIP_FILE_NAME${NC}' 文件上传到 '${BOLD}$DATA_DIR${NC}' 目录。"
    echo -e "如使用 Windows 终端，可参考以下命令模板：\n"
    echo -e "${CYAN}# --- 命令模板 ---${NC}"
    echo -e "${BOLD}scp -P <端口号> \"<您的本地文件完整路径>\" <用户名>@<服务器IP>:$DATA_DIR/${NC}"
    echo -e "${CYAN}# --- 虚构示例 ---${NC}"
    echo -e "${BOLD}scp -P 2222 \"E:\\downloads\\default-user.zip\" myuser@123.45.67.89:$DATA_DIR/${NC}\n"
    
    echo -e "脚本将在此等待文件上传..."
    while [ ! -f "$ZIP_FILE_PATH" ]; do echo -n "."; sleep 2; done
    
    echo -e "\n${GREEN}✓ 文件已出现!${NC} ${YELLOW}正在等待文件传输完成 (当文件大小连续3秒不变时继续)...${NC}"
    local old_size=0
    local new_size=1
    while [ "$new_size" -ne "$old_size" ] || [ "$new_size" -eq 0 ]; do
        old_size=$(stat -c %s "$ZIP_FILE_PATH" 2>/dev/null || echo 0)
        sleep 3
        new_size=$(stat -c %s "$ZIP_FILE_PATH" 2>/dev/null || echo 0)
        echo -n "."
    done
    echo -e "\n${GREEN}✓ 文件传输似乎已完成！${NC}\n"

    # 步骤 3: 安全解压
    echo -e "${BLUE}--- 步骤 3/4: 解压并验证 ---${NC}"
    read -p "$(echo -e "${YELLOW}确定文件已传输完毕并可以开始解压吗？ (Y/n): ${NC}")" confirm_unzip
    if [[ "$confirm_unzip" =~ ^[Nn]$ ]]; then
        echo -e "\n${RED}操作已取消。${NC}"
        echo -e "当前状态: 原始数据已备份为 '${BOLD}$BACKUP_NAME${NC}', 上传的压缩包 '${BOLD}$ZIP_FILE_NAME${NC}' 仍保留。"
        echo -e "您可以稍后重新运行此功能继续操作。"
        return
    fi

    echo -e "${YELLOW}[操作]${NC} 正在创建新目录并解压..."
    mkdir -p "$TARGET_DIR_PATH"
    if unzip -o "$ZIP_FILE_PATH" -d "$TARGET_DIR_PATH" > /dev/null; then
        echo -e "${GREEN}✓ 解压成功！${NC}"
        echo -e "\n${YELLOW}${BOLD}【重要】请现在登录您的酒馆，检查所有角色卡、聊天记录和设置是否都已正确加载。${NC}"
        read -p "确认一切正常后，请按 Enter 键继续进行清理步骤..."
    else
        echo -e "\n${RED}[错误]${NC} 解压失败！文件可能已损坏或不是有效的ZIP格式。正在执行自动回滚..."
        rm -rf "$TARGET_DIR_PATH"
        if [ -d "$BACKUP_PATH" ]; then
            mv "$BACKUP_PATH" "$TARGET_DIR_PATH"
            echo -e "${GREEN}✓ 回滚成功！${NC} 系统已恢复到操作前的状态。"
        fi
        echo -e "脚本已终止。"
        return
    fi

    # 步骤 4: 用户确认后清理
    echo -e "\n${BLUE}--- 步骤 4/4: 清理临时文件 ---${NC}"
    printf "是否删除已上传的压缩包 '${BOLD}%s${NC}'? (Y/n): " "$ZIP_FILE_NAME"
    read -r del_zip
    if [[ ! "$del_zip" =~ ^[Nn]$ ]]; then
        rm "$ZIP_FILE_PATH"
        echo -e "${GREEN}✓ 压缩包已删除。${NC}"
    else
        echo -e "${YELLOW}压缩包已保留。${NC}"
    fi

    printf "是否删除备份目录 '${BOLD}%s${NC}'? (Y/n): " "$BACKUP_NAME"
    read -r del_bak
    if [[ ! "$del_bak" =~ ^[Nn]$ ]]; then
        rm -rf "$BACKUP_PATH"
        echo -e "${GREEN}✓ 备份目录已删除。${NC}"
    else
        echo -e "${YELLOW}备份目录已保留。${NC}"
    fi

    echo -e "\n${CYAN}=======================================================${NC}"
    echo -e "${GREEN}${BOLD}          所有操作已成功完成！🎉${NC}"
    echo -e "${CYAN}=======================================================${NC}"

    # 步骤 5: 显示最终状态
    echo -e "\n${BLUE}--- 操作后 '${DATA_DIR}' 目录最终状态 ---${NC}"
    ls -lh "$DATA_DIR"
    echo
    echo -e "${GREEN}${BOLD}【重要提示】数据已更新，无需重启容器！请关闭浏览器中的酒馆页面后重新打开即可看到变化。${NC}"
}

# --- 主菜单 ---
fn_main_menu() {
    if ! command -v unzip &> /dev/null; then
        echo -e "${RED}[严重错误]${NC} 'unzip' 命令未找到，数据管理功能将无法使用。"
        echo -e "请先安装: ${YELLOW}sudo apt update && sudo apt install unzip${NC}"
        read -p "按 Enter 键退出脚本..."
        exit 1
    fi

    # 在主菜单显示前，首先执行权限设置
    tput reset
    fn_set_permissions

    while true; do
        tput reset
        echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║      ${BOLD}leaflow 云酒馆 (SillyTavern) 助手     ${NC}        ${CYAN}║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}\n"
        echo -e "${BLUE}============================ 主菜单 ============================${NC}"
        echo -e "  [1] ${CYAN}配置酒馆设置 (修改用户名/密码等)${NC}"
        echo -e "  [2] ${CYAN}替换 '${TARGET_DIR_NAME}' 用户数据 (别用)${NC}"
        echo -e "${BLUE}==============================================================${NC}"
        echo -e "  [q] ${YELLOW}退出脚本${NC}\n"
        read -p "请输入选项: " choice

        case "$choice" in
            1)
                fn_configure_settings
                read -p $'\n操作完成，按 Enter 键返回主菜单...'
                ;;
            2)
                fn_replace_data
                read -p $'\n操作完成，按 Enter 键返回主菜单...'
                ;;
            q|Q)
                echo -e "\n感谢使用，再见！"
                exit 0
                ;;
            *)
                echo -e "\n${RED}无效输入，请重新选择。${NC}"
                sleep 2
                ;;
        esac
    done
}

# --- 脚本执行入口 ---
fn_main_menu
