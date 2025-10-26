#!/bin/bash
set -e

TMP_SCRIPT="./install.sh"
URL="https://raw.githubusercontent.com/yeongpin/cursor-free-vip/main/scripts/install.sh"

[ ! -f $TMP_SCRIPT ] && curl -fsSLk "$URL" -o "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"
./"$TMP_SCRIPT"
rm -f "$TMP_SCRIPT"

