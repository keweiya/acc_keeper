#!/system/bin/sh
# 早期阶段：只保证数据目录存在、权限正确（此时 settings 服务还没起来）
# 目录分层：logs/ 日志、state/ 运行状态、locks/ 文件锁
DATA_DIR=/data/adb/acc_keeper
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/acc_keeper
umask 077
mkdir -p "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/locks" 2>/dev/null
chmod 700 "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/locks" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null
# 每次开机先清空上一轮日志，守护启动后再写入本轮内容
: > "$DATA_DIR/logs/acc_keeper.log" 2>/dev/null
chmod 600 "$DATA_DIR/logs/acc_keeper.log" 2>/dev/null

# 重置模块卡片描述：重启后不要继续显示上一次开机的「● 运行中｜已恢复 N 次」
# 守护进程起来后 update_desc 会按实际状态重新写（计数也已按开机周期归零）
MP="$MODDIR/module.prop"
if [ -f "$MP" ]; then
  _tmp="$MP.tmp.$$"
  grep -v '^description=' "$MP" 2>/dev/null > "$_tmp"
  printf 'description=○ 未运行｜开机初始化中\n' >> "$_tmp"
  mv -f "$_tmp" "$MP" 2>/dev/null
  rm -f "$_tmp" 2>/dev/null
fi
exit 0
