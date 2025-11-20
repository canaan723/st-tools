#!/bin/bash

# Copyright (c) 2025 清绝 (QingJue) <blog.qjyg.de>
# This script is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
# To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
#
# 郑重声明：
# 本脚本为免费开源项目，仅供个人学习和非商业用途使用。
# 未经作者授权，严禁将本脚本或其修改版本用于任何形式的商业盈利行为（包括但不限于倒卖、付费部署服务等）。
# 任何违反本协议的行为都将受到法律追究。

SCRIPT_URL="https://gugu.qjyg.de/ad"
FILENAME="ad-st-test.sh"

echo "正在准备下载最新版的 ${FILENAME} 脚本..."

curl -fsSL -o "${FILENAME}" "${SCRIPT_URL}"

if [ $? -ne 0 ]; then
  echo "哎呀，下载失败了。检查下网络或者链接？"
  exit 1
fi

chmod +x "${FILENAME}"

echo "脚本准备好了！马上运行..."
echo "------------------------------------"

./"${FILENAME}" "$@" < /dev/tty
