#!/system/bin/sh
# 早期阶段：只保证数据目录存在、权限正确（此时 settings 服务还没起来）
DATA_DIR=/data/adb/acc_keeper
[ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null
touch "$DATA_DIR/acc_keeper.log" 2>/dev/null
chmod 600 "$DATA_DIR/acc_keeper.log" 2>/dev/null
exit 0
