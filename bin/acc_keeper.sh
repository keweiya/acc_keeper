#!/system/bin/sh
# ==========================================================================
#  Accessibility Keeper —— 无障碍服务守护进程  (KernelSU / KernelSU Next / Magisk)
#
#  运行模式:
#    sh acc_keeper.sh          后台常驻守护（由 service.sh 开机拉起）
#    sh acc_keeper.sh --once   只执行一轮检查/修复后退出（acc_ctl apply 用）
# ==========================================================================
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/adb/ap/bin:$PATH

DATA_DIR=/data/adb/acc_keeper
TARGETS_FILE=$DATA_DIR/targets.txt
CONF_FILE=$DATA_DIR/settings.conf
LOG_FILE=$DATA_DIR/acc_keeper.log
STATE_FILE=$DATA_DIR/last_good
PAUSE_FILE=$DATA_DIR/paused
REJECTED_FILE=$DATA_DIR/rejected.txt
FIXES_FILE=$DATA_DIR/fixes.count
PID_FILE=$DATA_DIR/daemon.pid
MAXLOG=1048576        # 日志上限 1MB，超过就滚动保留后半段

MODDIR=${MODDIR:-/data/adb/modules/acc_keeper}

# ---- 默认参数，可被 /data/adb/acc_keeper/settings.conf 覆盖 ----
VERBOSE=0              # 1 = 连启动/新增/详细恢复过程都记，默认只记变更与错误
POLL_FAST=3            # 开机初期轮询间隔（秒）
POLL_SLOW=60           # 稳定后轮询间隔（秒）
BOOT_FAST_SECONDS=180  # 开机后多少秒内使用快速轮询
BOOST_TICKS=10         # 修复成功后额外快查的次数
VERIFY_SLEEP=1         # 写完设置后等多久再读回来校验（秒）
STRICT=0               # 1 = 只保留 targets.txt 内的服务，其它全部移除

[ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR" 2>/dev/null
if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; fi

# ---------------------------------------------------------------- 日志
log() {
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
  sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
  if [ "${sz:-0}" -gt "$MAXLOG" ]; then
    tail -c $((MAXLOG / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
  fi
}

# ------------------------------------------------- 组件名规范化
# com.foo/.Svc 或 com.foo/com.foo.Svc -> 统一输出 com.foo/com.foo.Svc
norm_one() {
  c=$1
  case "$c" in */*) ;; *) return 1 ;; esac
  pkg=${c%%/*}; cls=${c#*/}
  [ -z "$pkg" ] && return 1
  [ -z "$cls" ] && return 1
  case "$cls" in */*) return 1 ;; esac
  case "$cls" in
    .*) cls="$pkg$cls" ;;
    *.*) ;;
    *) cls="$pkg.$cls" ;;
  esac
  printf '%s/%s\n' "$pkg" "$cls"
}

norm_list() {
  printf '%s\n' "$1" | tr -d '\r' | tr ':' '\n' | while IFS= read -r c || [ -n "$c" ]; do
    [ -z "$c" ] && continue
    case "$c" in null|NULL|Null) continue ;; esac
    norm_one "$c" || continue
  done | sort -u
}

read_targets_norm() {
  [ -f "$TARGETS_FILE" ] || return 0
  sed -e 's/#.*//' "$TARGETS_FILE" 2>/dev/null | tr -d ' \t\r' | while IFS= read -r c || [ -n "$c" ]; do
    [ -z "$c" ] && continue
    norm_one "$c" || continue
  done | sort -u
}

# ------------------------------------------- 把当前状态写进 module.prop
# KernelSU 的模块卡片显示的就是 description，所以让它当状态栏用：
#   ● 运行中｜守护 2 个应用｜已恢复 7 次｜每 60 秒巡检
# 累计"恢复次数"：存文件，不受日志滚动/清空影响
read_fixes() {
  _f=$(cat "$FIXES_FILE" 2>/dev/null)
  case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
  printf '%s' "$_f"
}
bump_fixes() {
  _n=$(read_fixes)
  printf '%s' $((_n + 1)) > "$FIXES_FILE" 2>/dev/null
  chmod 600 "$FIXES_FILE" 2>/dev/null
}

update_desc() {
  mp="$MODDIR/module.prop"
  [ -f "$mp" ] || return 0
  [ -w "$mp" ] || return 0

  n=$(read_targets_norm | sed 's#/.*##' | sort -u | grep -c .)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  fixes=$(read_fixes)
  case "$fixes" in ''|*[!0-9]*) fixes=0 ;; esac

  pid=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then running=1; else running=0; fi

  exp=$(cat "$PAUSE_FILE" 2>/dev/null)
  now=$(date +%s)
  case "$exp" in ''|*[!0-9]*) exp=0 ;; esac

  if [ "$exp" -gt "$now" ]; then
    left=$(( (exp - now + 59) / 60 ))
    if [ "$n" -gt 0 ]; then
      desc="⏸ 已暂停｜还剩 $left 分钟｜守护 $n 个应用"
    else
      desc="⏸ 已暂停｜还剩 $left 分钟"
    fi
  elif [ "$running" = "1" ]; then
    if [ "$n" -gt 0 ]; then
      desc="● 运行中｜守护 $n 个应用｜已恢复 $fixes 次｜每 ${POLL_SLOW} 秒巡检"
    else
      desc="● 运行中｜还没选应用，打开 WebUI 配置"
    fi
  else
    if [ "$n" -gt 0 ]; then
      desc="○ 未运行｜守护 $n 个应用｜重启设备可恢复"
    else
      desc="○ 未运行｜未配置应用"
    fi
  fi

  cur=$(sed -n 's/^description=//p' "$mp" 2>/dev/null | head -n 1)
  [ "$cur" = "$desc" ] && return 0

  tmp="$mp.tmp.$$"
  {
    grep -v '^description=' "$mp" 2>/dev/null
    printf 'description=%s\n' "$desc"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$mp" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ------------------------------------------------- 读 settings
# 唤醒一次 app_process 就把两个值都读回来（原来要两次，省一半唤醒开销）
AE=""
EAS=""
read_settings() {
  AE=""; EAS=""
  dump=$(settings list secure 2>/dev/null)
  if [ -n "$dump" ]; then
    AE=$(printf '%s\n' "$dump" | sed -n 's/^accessibility_enabled=//p' | head -n 1)
    EAS=$(printf '%s\n' "$dump" | sed -n 's/^enabled_accessibility_services=//p' | head -n 1)
  fi
  if [ -z "$AE" ] && [ -z "$EAS" ]; then
    AE=$(settings get secure accessibility_enabled 2>/dev/null)
    EAS=$(settings get secure enabled_accessibility_services 2>/dev/null)
  fi
}

settings_put() { settings put secure "$1" "$2" 2>/dev/null; }

# ------------------------------------------------- 等系统就绪
wait_ready() {
  i=0
  while [ $i -lt 90 ]; do
    read_settings
    case "$AE" in
      ''|Error*|Exception*) sleep 1; i=$((i + 1)) ;;
      *) return 0 ;;
    esac
  done
  log "警告: 等待 settings 服务超时"
}

# ------------------------------------------------- 核心：执行一轮检查
# 返回值 0 = 无事发生，1 = 做过修复
FIXED=0
apply_once() {
  FIXED=0
  read_settings
  cur=$(norm_list "$EAS")
  tgt=$(read_targets_norm)

  # ---- 变更监控 ----
  if [ -s "$STATE_FILE" ]; then
    removed=$(while IFS= read -r p || [ -n "$p" ]; do
      [ -z "$p" ] && continue
      printf '%s\n' "$cur" | grep -qxF "$p" || printf '%s\n' "$p"
    done < "$STATE_FILE")
    if [ -n "$removed" ]; then
      _rt=""; _ro=""
      for _r in $removed; do
        if printf '%s\n' "$tgt" | grep -qxF "$_r"; then _rt="$_rt $_r"; else _ro="$_ro $_r"; fi
      done
      if [ -n "$_rt" ]; then
        rcnt=$(printf '%s\n' $_rt | grep -c .)
        rsample=$(printf '%s\n' $_rt | head -n 3 | tr '\n' ' ')
        log "!! 守护的服务被移除 ${rcnt} 个: ${rsample}"
      fi
      # 没在守护列表里的服务被关，不算事件，只有 VERBOSE 才记
      if [ "$VERBOSE" = "1" ] && [ -n "$_ro" ]; then
        ocnt=$(printf '%s\n' $_ro | grep -c .)
        log "· 非守护服务被移除 ${ocnt} 个（未处理）"
      fi
    fi
    added=$(printf '%s\n' "$cur" | while IFS= read -r p || [ -n "$p" ]; do
      [ -z "$p" ] && continue
      grep -qxF "$p" "$STATE_FILE" || printf '%s\n' "$p"
    done)
    if [ -n "$added" ]; then
      acnt=$(printf '%s\n' $added | grep -c .)
      asample=$(printf '%s\n' $added | head -n 3 | tr '\n' ' ')
      [ "$VERBOSE" = "1" ] && log "++ 新启用无障碍服务 ${acnt} 个: ${asample}"
    fi
  fi
  printf '%s\n' "$cur" > "$STATE_FILE" 2>/dev/null

  [ -z "$tgt" ] && return 0

  # ---- 找出缺失的目标 ----
  missing=""
  for t in $tgt; do
    printf '%s\n' "$cur" | grep -qxF "$t" || missing="$missing $t"
  done

  if [ -z "$missing" ] && [ "$AE" = "1" ]; then
    return 0
  fi

  # ---- 组装新值 ----
  if [ "$STRICT" = "1" ]; then
    new_val=$(printf '%s\n' "$tgt" | sed '/^$/d' | sort -u | tr '\n' ':' | sed 's/:$//')
  else
    new_val=$(printf '%s\n%s\n' "$cur" "$tgt" | sed '/^$/d' | sort -u | tr '\n' ':' | sed 's/:$//')
  fi
  [ -z "$new_val" ] && return 0

  mcnt=0
  if [ -n "$missing" ]; then
    mcnt=$(printf '%s\n' $missing | grep -c .)
    msample=$(printf '%s\n' $missing | head -n 3 | tr '\n' ' ')
    [ "$VERBOSE" = "1" ] && log "→ 恢复服务 ${mcnt} 个: ${msample}"
  else
    [ "$VERBOSE" = "1" ] && log "→ 总开关 accessibility_enabled=1（当前 $AE）"
  fi

  settings_put enabled_accessibility_services "$new_val"
  settings_put accessibility_enabled 1
  sleep "$VERIFY_SLEEP"
  # ---- 校验 ----
  sleep 1
  read_settings
  cur2=$(norm_list "$EAS")
  bad=""
  for t in $tgt; do
    printf '%s\n' "$cur2" | grep -qxF "$t" || bad="$bad $t"
  done
  if [ -z "$bad" ] && [ "$AE" = "1" ]; then
    if [ "$mcnt" -gt 0 ]; then log "✓ 已恢复 ${mcnt} 个"; else log "✓ 总开关已恢复"; fi
    bump_fixes
    printf '%s\n' "$cur2" > "$STATE_FILE" 2>/dev/null
    FIXED=1
    rm -f "$DATA_DIR/.last_fail" 2>/dev/null
    # 写成功了：把目标从"系统拒绝"名单里摘掉（应用更新后可能又能用了）
    if [ -s "$REJECTED_FILE" ]; then
      _rt="$REJECTED_FILE.tmp.$$"
      : > "$_rt"
      while IFS= read -r _r || [ -n "$_r" ]; do
        [ -z "$_r" ] && continue
        printf '%s\n' "$tgt" | grep -qxF "$_r" || printf '%s\n' "$_r" >> "$_rt"
      done < "$REJECTED_FILE"
      mv -f "$_rt" "$REJECTED_FILE"
    fi
  else
    # 同一种失败 10 分钟内只记一次，免得日志被刷爆
    sig=$(printf '%s\n' $bad | sort -u | tr '\n' ',')
    nowt=$(date +%s)
    lf=""; lt=0
    if [ -f "$DATA_DIR/.last_fail" ]; then
      lf=$(sed -n '1p' "$DATA_DIR/.last_fail" 2>/dev/null)
      lt=$(sed -n '2p' "$DATA_DIR/.last_fail" 2>/dev/null)
    fi
    case "$lt" in ''|*[!0-9]*) lt=0 ;; esac
    if [ "$sig" != "$lf" ] || [ $((nowt - lt)) -gt 600 ]; then
      bcnt=$(printf '%s\n' $bad | grep -c .)
      bsample=$(printf '%s\n' $bad | head -n 2 | tr '\n' ' ')
      log "✗ 恢复失败 ${bcnt} 个（未生效）: ${bsample} —— 组件可能已不存在，试 su -c acc_ctl clean"
      printf '%s\n%s\n' "$sig" "$nowt" > "$DATA_DIR/.last_fail" 2>/dev/null
      # 记进"系统拒绝"名单：以后不再尝试、界面标灰，免得每轮白写一次
      for _b in $bad; do
        grep -qxF "$_b" "$REJECTED_FILE" 2>/dev/null || printf '%s\n' "$_b" >> "$REJECTED_FILE"
      done
    fi

    # 失败时做一次校验：把本机已经不存在的守护项自动摘掉，
    # 否则每轮都会写一遍、又存不住，日志会被刷爆永久失败。
    if [ -n "$bad" ] && [ -f "$TARGETS_FILE" ]; then
      slist=$(sh "$MODDIR/bin/acc_ctl" scan-list 2>/dev/null)
      if [ -n "$slist" ]; then
        tmp="$TARGETS_FILE.tmp.$$"
        : > "$tmp"
        dropped=0
        while IFS= read -r tl || [ -n "$tl" ]; do
          [ -z "$tl" ] && continue
          case "$tl" in \#*) continue ;; esac
          tc=$(norm_one "$tl")
          if [ -n "$tc" ] && printf "%s\n" "$slist" | grep -qxF "$tc" && ! grep -qxF "$tc" "$REJECTED_FILE" 2>/dev/null; then
            printf '%s\n' "$tc" >> "$tmp"
          else
            dropped=$((dropped + 1))
          fi
        done < "$TARGETS_FILE"
        if [ "$dropped" -gt 0 ]; then
          mv -f "$tmp" "$TARGETS_FILE"
          log "!! 自动移除 $dropped 个本机不存在的守护项"
          FIXED=1
        else
          rm -f "$tmp" 2>/dev/null
        fi
      fi
    fi
  fi
  return 0
}

# ------------------------------------------------- 只刷新模块卡片上的状态行
if [ "$1" = "--desc" ]; then
  update_desc
  exit 0
fi

# ------------------------------------------------- 单次模式
if [ "$1" = "--once" ]; then
  if [ "$2" = "--fast" ]; then
    VERIFY_SLEEP=0.3      # 开关操作走这条：少等 0.7 秒，界面已经乐观更新过了
  else
    wait_ready
  fi
  apply_once
  update_desc
  exit 0
fi

# ------------------------------------------------- 常驻模式
if [ -f "$PID_FILE" ]; then
  old=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    exit 0   # 已有实例
  fi
fi
chmod 600 "$PID_FILE" "$LOG_FILE" "$STATE_FILE" "$REJECTED_FILE" "$TARGETS_FILE" 2>/dev/null
echo $$ > "$PID_FILE"
rm -f "$DATA_DIR/.stop" 2>/dev/null   # 清掉可能残留的停止标记，否则起来就退出
[ "$VERBOSE" = "1" ] && log "=== 守护进程启动 (pid $$) ==="

wait_ready
# 开机时把"系统里已经开着"的无障碍服务默认纳入守护
sh "$MODDIR/bin/acc_ctl" adopt >/dev/null 2>&1
apply_once
update_desc
boost=0
[ "$FIXED" = "1" ] && boost=$BOOST_TICKS
start_ts=$(date +%s)

# 分片睡眠：每秒看一次有没有停止请求。
# 跨 PID 命名空间时 kill 打不到别的会话起的进程，只能靠文件通知。
nap() {
  _n=$1
  case "$_n" in ''|*[!0-9]*) _n=60 ;; esac
  _step=5
  [ "$_n" -lt 5 ] && _step=1        # 快速轮询（开机前 3 分钟）保持原精度
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    if [ -f "$DATA_DIR/.stop" ]; then
      rm -f "$DATA_DIR/.stop" "$PID_FILE" 2>/dev/null
      exit 0
    fi
    # 5 秒一片：既能让 restart 在 5 秒内生效，又不至于每分钟 fork 60 个 sleep
    sleep "$_step"
    _i=$((_i + _step))
  done
}

while :; do
  if [ -f "$DATA_DIR/.stop" ]; then
    rm -f "$DATA_DIR/.stop" "$PID_FILE" 2>/dev/null
    exit 0
  fi
  # 暂停开关
  if [ -f "$PAUSE_FILE" ]; then
    exp=$(cat "$PAUSE_FILE" 2>/dev/null)
    now=$(date +%s)
    case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
    if [ "$exp" -gt "$now" ]; then
      sleep 10
      continue
    else
      rm -f "$PAUSE_FILE" 2>/dev/null
      log "暂停结束，恢复守护"
    fi
  fi

  apply_once
  update_desc
  [ "$FIXED" = "1" ] && boost=$BOOST_TICKS

  now=$(date +%s)
  iv=$POLL_SLOW
  if [ "$boost" -gt 0 ]; then
    boost=$((boost - 1))
    iv=$POLL_FAST
  elif [ $((now - start_ts)) -lt "$BOOT_FAST_SECONDS" ]; then
    iv=$POLL_FAST
  fi
  nap "$iv"
done
