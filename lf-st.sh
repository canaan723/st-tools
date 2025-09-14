#!/bin/bash

NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'

# --- 脚本开始 ---
tput reset
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ${BOLD}leaflow 云酒馆 (SillyTavern) 一键配置脚本${NC}      ${CYAN}║${NC}"
echo -e "${CYAN}║               by Qingjue | XHS:826702880               ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo

CONFIG_FILE="/mnt/config/config.yaml"

# --- 步骤 1: 检查并确认配置文件路径 ---
echo -e "${BLUE}--- 步骤 1/4: 定位配置文件 ---${NC}"
while [ ! -f "$CONFIG_FILE" ]; do
    echo -e "${RED}[错误]${NC} 在默认路径 '${BOLD}$CONFIG_FILE${NC}' 未找到配置文件。"
    
    read -p "$(echo -e "${YELLOW}[操作]${NC} 是否要指定一个新的文件路径？ (y/N): ")" choice
    
    case "$choice" in
        [Yy]* )
            read -p "$(echo -e "${YELLOW}[输入]${NC} 请输入正确的配置文件完整路径: ")" CONFIG_FILE
            if [ -z "$CONFIG_FILE" ]; then
                echo -e "${RED}[提示]${NC} 输入为空，请重新操作。"
            fi
            ;;
        [Nn]* | "" )
            echo -e "\n${RED}操作已取消，退出脚本。${NC}"
            exit 1
            ;;
        * )
            echo -e "${RED}[提示]${NC} 无效输入，请输入 'y' 或 'n'。"
            ;;
    esac
    echo
done

echo -e "${GREEN}✓ 成功定位配置文件: ${BOLD}$CONFIG_FILE${NC}"
echo

# --- 步骤 2: 获取用户输入 ---
echo -e "${BLUE}--- 步骤 2/4: 设定登录凭证 ---${NC}"
read -p "$(echo -e "${YELLOW}[输入]${NC} 请输入新的用户名: ")" NEW_USERNAME
read -p "$(echo -e "${YELLOW}[输入]${NC} 请输入新的密码: ")" NEW_PASSWORD

if [ -z "$NEW_USERNAME" ] || [ -z "$NEW_PASSWORD" ]; then
    echo -e "\n${RED}[错误] 用户名和密码均不能为空。操作已终止。${NC}"
    exit 1
fi
echo

# --- 步骤 3: 执行修改 ---
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
    "$CONFIG_FILE"

if [ $? -ne 0 ]; then
    echo -e "\n${RED}[错误] 在修改文件 '$CONFIG_FILE' 时发生未知错误。${NC}"
    echo -e "${RED}文件可能未被修改或已损坏，请手动检查。${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 配置文件修改成功！${NC}"
echo

# --- 步骤 4: 显示结果 ---
echo -e "${BLUE}--- 步骤 4/4: 查看配置结果 ---${NC}"
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "║                   ${BOLD}配置完成！请查收！${NC}                   ║"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BOLD}已更新的配置详情：${NC}"
printf "  - ${GREEN}%-28s${NC} %s\n" "listen: true" "(【基础】允许外部网络访问酒馆)"
printf "  - ${GREEN}%-28s${NC} %s\n" "whitelistMode: false" "(【基础】关闭IP白名单，允许任意IP访问)"
printf "  - ${GREEN}%-28s${NC} %s\n" "basicAuthMode: true" "(【基础】启用基础登录认证)"
printf "  - ${GREEN}%-28s${NC} %s\n" "sessionTimeout: 86400" "(【安全】24小时无操作后需重新登录)"
printf "  - ${GREEN}%-28s${NC} %s\n" "numberOfBackups: 5" "(【性能】单个聊天记录的备份保留数量)"
printf "  - ${GREEN}%-28s${NC} %s\n" "lazyLoadCharacters: true" "(【性能】启用角色卡懒加载，加快启动)"
echo
echo -e "${YELLOW}=====================【 重要：请记录登录凭证 】=====================${NC}"
echo
echo -e "  ${BOLD}用户名 : ${CYAN}$NEW_USERNAME${NC}"
echo -e "  ${BOLD}密  码 : ${CYAN}$NEW_PASSWORD${NC}"
echo
echo -e "${YELLOW}=====================================================================${NC}"
echo
echo -e "${BLUE}[提示] 如需更改用户名或密码，再次运行此脚本即可。${NC}"
echo -e "${BLUE}祝您使用愉快！${NC}"
echo

exit 0
