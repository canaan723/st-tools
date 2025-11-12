#!/bin/bash

# 定义要下载的脚本URL和本地文件名
SCRIPT_URL="https://gugu.qjyg.de/adtest"
FILENAME="ad-st-test.sh"

# 使用 -o 来下载并强制覆盖本地文件
echo "Downloading the latest version of ${FILENAME}..."
curl -sSL -o "${FILENAME}" "${SCRIPT_URL}"

# 检查curl是否成功下载
if [ $? -ne 0 ]; then
  echo "Error: Failed to download the script."
  exit 1
fi

# 赋予执行权限
chmod +x "${FILENAME}"

echo "Script updated successfully."

# 如果需要，可以在这里加上自启逻辑或直接执行
# ./$FILENAME
