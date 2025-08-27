#!/usr/bin/env bash

# SillyTavern Docker 一键部署脚本
# 版本: 5.1 (最终稳定版)
# 作者: Qingjue
# 功能: 自动化部署 SillyTavern Docker 版，提供极致的自动化、健壮性和用户体验。

# --- 初始化与环境设置 ---
set -e

# --- 色彩定义 ---
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
fn_print_step() {
    echo -e "\n${CYAN}═══ $1 ═══${NC}"
}
fn_print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}
fn_print_error() {
    echo -e "\n${RED}✗ 错误: $1${NC}\n" >&2
    exit 1
}
fn_print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}
fn_print_info() {
    echo -e "  $1"
}

# --- 核心函数 ---
fn_get_public_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org) || \
    ip=$(curl -s --max-time 5 https://ifconfig.me) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

fn_detect_location() {
    local country_code
    country_code=$(curl -s --max-time 4 https://ipinfo.io/country) || country_code=""
    if [[ -z "$country_code" ]]; then
        country_code=$(curl -s --max-time 4 https://ip.sb/geoip | grep -oP '"country_code":"\K[^"]+') || country_code=""
    fi

    if [[ "$country_code" == "CN" ]]; then
        echo "CN"
    elif [[ -n "$country_code" ]]; then
        echo "OVERSEAS"
    else
        echo "UNKNOWN"
    fi
}

fn_configure_docker_mirror() {
    fn_print_info "正在检测服务器地理位置..."
    local location
    location=$(fn_detect_location)
    
    local recommendation_text
    local default_choice
    
    case "$location" in
        "CN")
            recommendation_text="检测到您的服务器位于【中国大陆】，推荐配置 Docker 加速镜像。"
            default_choice=1
            ;;
        "OVERSEAS")
            recommendation_text="检测到您的服务器位于【海外】，推荐跳过或移除 Docker 加速镜像。"
            default_choice=2
            ;;
        *)
            recommendation_text="无法自动检测服务器位置，请手动选择。"
            default_choice=""
            ;;
    esac
    
    echo -e "  ${YELLOW}${recommendation_text}${NC}"
    echo "请根据您的实际情况选择："
    echo -e "  [1] 我在中国大陆，${GREEN}请为我配置加速镜像${NC}。"
    echo -e "  [2] 我在海外，${CYAN}请跳过或移除加速镜像${NC}。"
    read -p "请输入选项数字 [按回车使用推荐选项]: " user_choice < /dev/tty
    
    local final_choice=${user_choice:-$default_choice}
    
    if [[ "$final_choice" == "1" ]]; then
        fn_print_info "正在为您配置国内 Docker 加速镜像..."
        # 【关键修复】直接定义语法正确的 JSON 数组内容，最后一个元素后没有逗号
        MIRROR_LIST='
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://hub1.nat.tf",
    "https://docker.1panel.live",
    "https://dockerproxy.1panel.live",
    "https://hub.rat.dev
