#!/system/bin/sh
# 早期阶段：只保证数据目录存在、权限正确（此时 settings 服务还没起来）
# 目录分层：logs/ 日志、state/ 运行状态、locks/ 文件锁
DATA_DIR=/data/adb/acc_keeper
umask 077
mkdir -p "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/locks" 2>/dev/null
chmod 700 "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/locks" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null
# 每次开机先清空上一轮日志，守护启动后再写入本轮内容
: > "$DATA_DIR/logs/acc_keeper.log" 2>/dev/null
chmod 600 "$DATA_DIR/logs/acc_keeper.log" 2>/dev/null
exit 0
