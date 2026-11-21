#!/bin/sh
# 打包成 KernelSU / Magisk 可安装的模块 zip
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' module.prop)
OUT=${1:-"../acc_keeper-${VER}.zip"}

rm -f "$OUT"
zip -r -X "$OUT" \
  module.prop customize.sh service.sh post-fs-data.sh uninstall.sh action.sh \
  README.md bin system config webroot >/dev/null

echo "已生成: $OUT"
unzip -l "$OUT" | tail -3
