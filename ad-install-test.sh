#!/bin/bash

SCRIPT_URL="https://gugu.qjyg.de/adtest"
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

./"${FILENAME}" "$@"
