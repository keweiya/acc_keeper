#!/system/bin/sh
# 卸载模块时请求守护进程自行退出，保留配置与日志。
# 进程号可能已被系统其它进程复用，所以不直接按 pid 文件发送信号。
DATA_DIR=/data/adb/acc_keeper
[ -d "$DATA_DIR" ] && : > "$DATA_DIR/.stop"
exit 0
