# 无障碍守护 (acc_keeper)

KernelSU / KernelSU Next / Magisk 模块。开机自动启用指定应用的无障碍服务，并在它被系统、安全中心、省电策略或任何后台清理关掉后自动恢复，同时记录每一次"被关闭"的时间与组件。带 WebUI。

## 原理

无障碍服务的启用状态本质只是 `Settings.Secure` 里的两个值：

```
enabled_accessibility_services = 包名/类名:包名/类名
accessibility_enabled = 1
```

`AccessibilityManagerService` 监听这两个值的变化——写进去就**立即生效**，不需要重启、不需要点授权弹窗。从「设置 → 无障碍」手动点开，做的也只是这两次写入。

模块做的事：

1. `service.sh` 在开机 `late_start service` 阶段拉起守护进程；
2. 守护进程周期性读取这两个值，发现目标组件缺失或总开关被关就补回去；
3. 每次检测到服务消失/新增都写日志——这就是"监控"部分。

## 日志

`/data/adb/acc_keeper/logs/acc_keeper.log`，用 `su -c acc_ctl log 50` 看最后 50 行。

默认（`VERBOSE=0`）记的全是关键事件：

| 行首 | 含义 |
| --- | --- |
| `=== 守护启动 v1.23.0 (pid N)` | 进程起来。紧跟的几行给出设备型号 / Android 版本 / 内核 / boot_id / 已开机时长 / **启动类型**（`设备重启` = boot_id 变了，`进程重启` = boot_id 没变）/ 上次退出原因 / 生效配置 / 目标清单 |
| `--- 守护退出 pid=N 原因=… 运行=… 累计检查=N 修复=N` | 退出原因（`.stop` 标记 / SIGTERM / SIGHUP / SIGINT）与本次运行时长、检查次数 |
| `♥ 心跳: 运行 2小时0分 检查 #120 修复 8 目标 5 个 间隔 60s` | 每 `HEARTBEAT_SECONDS`（默认 1800 秒）一条存活记录。判断"守护还在不在跑"先看这条 |
| `!! 守护的服务被移除 N 个: …` | 目标从系统列表里消失（数量 + 前 3 个组件） |
| `!!` 之后必有 `✓ 已恢复 N 个（耗时 Xms，列表 M 项）` 或 `✗ 恢复失败 … 读回 AE=… / 列表 M 项` | 修复结果，成功会同时读回校验 |
| `⏸ 暂停中，停止巡检（还剩 N 分钟）` / `▶ 暂停结束，恢复巡检` | 暂停状态切换 |
| `! 检查 #N 偏慢: 用时 Xms` | 单轮超过 `SLOW_TICK_MS`（默认 3000ms） |

`VERBOSE=1` 时额外记录：每轮巡检摘要（总开关 / 目标 / 在线 / 系统列表项数）、写入前后的完整列表、每轮耗时。

辅助状态文件：

- `.last_boot` — 上次记录到的 `boot_id`，用来区分「手机重启」和「守护进程重启」
- `.last_exit` — 上一次退出的单行摘要（时间、时长、检查次数、原因）
- `ticks.count` — 累计检查次数（跨重启）

## 待机耗电

v1.22.0 之前，守护的 `nap()` 把 60 秒切成了 12 段 `sleep 5`，用来快速响应 `.stop` 标记。后果是熄屏后系统每 5 秒被唤醒一次，每次唤醒都要走完整的 suspend → 冻结/解冻全部进程 → resume 流程。实测这台设备 5 小时 21 分里累计 3685 次成功挂起（平均 5.2 秒一次），`android.system.suspend-service` 单进程吃掉 8 分 14 秒 CPU —— 这部分耗电在电池页面会被算到提供 root 的 KernelSU 头上。

v1.22.0 起 `nap()` 整段用一次 `sleep`，停止/重启由 `acc_ctl` 校验进程身份（boot_id + 进程起始时刻 + 完整 argv）后发 `SIGTERM` 立即打断，不再需要 5 秒轮询。

## WebUI

KernelSU 管理器 → 模块卡片 → **打开**。

**顶部只有状态，没有统计**：

```
无障碍守护                              ⋯
● 运行中 · 守护 2 个应用 · 每 60 秒巡检
```

圆点绿=运行中、橙=已暂停、灰=未运行；后面那句跟着状态变（暂停时显示"还剩 N 分钟"）。

**下面就是搜索 + 应用列表**（没有多余的汇总卡）：

- 应用图标 + 系统里的中文名（KernelSU 的 `ksu://icon/<包名>` 与 `ksu.getPackagesInfo()`）
- 只显示**手机上下载安装的应用**（`isSystem=false`），设置、TalkBack、系统界面这类系统应用不进来
- 应用名是异步补上的：KernelSU 管理器要等 WebUI 打开后才去抓应用列表，所以列表会先出包名、1~3 秒后自动换成中文名（重试 5 次）
- 已守护的排最上面，第三行按已选择的守护目标显示：系统已启用 / 等待恢复；若守护进程未运行，会单独标明
- 不做静态过滤：能不能启用由系统实际行为决定。第一次写进去被系统丢弃的组件，会记到 `/data/adb/acc_keeper/state/rejected.txt`，界面标"系统不接受此服务（已记录）"、开关置灰、不再重试；应用更新后重新打开成功的话，记录会自动清掉
- 开关 = 立即开启或关闭该应用的无障碍服务（关掉会同时取消守护，不然会被弹回来）

**⋯ 打开「设置与操作」底部面板**（iOS 分组列表样式）：

| 分组 | 内容 |
|---|---|
| 显示 | 仅看已守护 / 显示全部应用（iOS 小开关） |
| 巡检 | 轮询间隔 →（显示当前值，点进去改） |
| 操作 | 暂停守护 30 分钟（暂停后变成"恢复守护"）/ 查看日志 |
| 外观 | 跟随系统 / 浅色 / 深色（分段控件，记在 localStorage） |
| — | 关于（版本号 + 当前状态） |

**只有两个刷新入口，不重复**：

- 下拉刷新 → 重新读一遍数据（`acc_ctl dump`）
- 右下角「立即检查」→ 检查所选守护目标；进程未运行时先尝试拉起，再核实检查结果。模块卡片的 Action 也是同一套点检流程。

没有第三个"刷新"按钮。默认只显示"有服务的用户应用 + 已守护的应用"。

- **守护开关以目标列表为准**；系统里已开启但未选择守护的服务，只显示其系统状态，打开页面或重启手机都不会自动纳入。
- 面板打开时背后列表锁死，点遮罩空白处即可关闭

## 模块卡片上的状态

`module.prop` 里的 `description` 是上次刷新时的状态快照，KernelSU 模块卡片会读取它：

| 状态 | 显示 |
|---|---|
| 正常 | `● 运行中｜守护 2 个应用｜已恢复 7 次｜每 60 秒巡检` |
| 暂停 | `⏸ 已暂停｜还剩 27 分钟｜守护 2 个应用` |
| 进程没起来 | `○ 未运行｜守护 2 个应用｜点检可尝试启动` |
| 已暂停且进程没起来 | `○ 未运行｜已暂停 27 分钟｜守护 2 个应用` |
| 还没选应用 | `● 运行中｜还没选应用，打开 WebUI 配置` |
| 刚装上没重启 | `○ 尚未启动｜开机自动启动｜点立即检查可启动守护` |

每轮巡检、打开 WebUI、点检、开关任一应用、暂停/恢复、改间隔都会刷新它。管理器里的模块列表要重新进一次才会重新读取；卡片读取的是 `module.prop` 的最后一次快照，如果进程突然退出，下一次状态查询或点检才会刷新该快照。真实进程状态以 WebUI 或 `acc_ctl status` 查询结果为准。进程身份校验同时核对进程信息，避免上次开机遗留 PID 被其它进程复用时显示“运行中”。

## 命令行

```sh
su -c acc_ctl                          # 状态总览
su -c acc_ctl scan                     # 列出设备上所有无障碍服务
su -c acc_ctl on com.example.app       # 开启 + 守护
su -c acc_ctl off com.example.app      # 关闭 + 取消守护
su -c acc_ctl add com.example.app      # 只加守护（多个服务时用 acc_ctl add 包名/类名）
su -c acc_ctl del com.example.app      # 只取消守护
su -c acc_ctl status                   # 系统值 / 进程 / 最近日志
su -c acc_ctl log 50
su -c acc_ctl apply                    # 立即检查修复一次
su -c acc_ctl check                    # 点检选中目标，守护未运行则拉起
su -c acc_ctl pause 30                 # 暂停守护 30 分钟
su -c acc_ctl resume
su -c acc_ctl interval 5 60            # 改轮询间隔：快速 5 秒 / 稳定 60 秒（会重启守护进程）
su -c acc_ctl restart                  # 改完 settings.conf 后让它生效
su -c acc_ctl clean                   # 清掉守护列表里本机已不存在的组件
```

`acc_ctl` 已挂到 `/system/bin/acc_ctl`。overlay 没生效时用完整路径：
`sh /data/adb/modules/acc_keeper/bin/acc_ctl status`

## 它到底会不会自动开回来

会。在系统设置里关掉目标应用的无障碍之后：

1. 守护进程下一次醒来（默认 **60 秒**内，平均 30 秒）读到 `enabled_accessibility_services` 少了这个组件，或者 `accessibility_enabled` 变成 0；
2. 仅把选中的目标组件合并写回列表，保留未纳入守护的已启用服务；按需打开总开关；
3. 日志记录目标被移除与恢复结果。

例外只有三种：开了 `acc_ctl pause`、守护进程没起来（`acc_ctl status` 可以看到）、或者目标组件名写错（日志里是 `✗ 恢复失败`）。另外注意：系统的无障碍设置页面不会实时刷新，你关掉后停在那个页面看到的是旧状态，退出去再进就是"开"了。

## 耗电

守护进程就是一个跑 `sleep` 的 shell 循环，**不持有 wakelock**，不会阻止系统休眠；每次检查才会唤起一次 `app_process`（`settings` 命令）读值。

| 场景 | 唤醒次数 | 量级 |
|---|---|---|
| 开机后前 3 分钟（3 秒一次） | ≈60 | 一次性 |
| 稳定期（60 秒一次） | 1440/天 | 每次约 100~300ms CPU |
| 修复成功后（3 秒一次，10 次） | 突发 10 次 | 防止安全中心连续补刀 |

按 60 秒算，一天大约 3~8 分钟 CPU 时间，折算待机耗电在 0.1% 量级——比微信一个心跳还轻。想改间隔：WebUI「更多 → 轮询间隔」，或者 `acc_ctl interval 5 30`，两种方式都会立即重启守护进程生效；也可以直接改 `settings.conf` 里的 `POLL_FAST` / `POLL_SLOW` 再 `acc_ctl restart`。

## 日志

`/data/adb/acc_keeper/logs/acc_keeper.log`：**每次设备重启重新生成**（`post-fs-data.sh` 和守护启动各清一次），单次开机内上限 **1MB**，超过就滚动覆盖（只保留最新的一半），不会无限长大。

**默认只记事件和错误**，启动、新增、每次恢复的明细都不写（`VERBOSE=1` 才写）：

```
[2026-11-21 00:48:22] !! 检测到无障碍服务被移除 1 个: com.omarea.vtools/…AccessibilitySceneMode
[2026-11-21 00:48:24] ✓ 已恢复 1 个
```

一次被关 → 一次恢复，正好两行。失败长这样：

```
✗ 恢复失败 1 个（未生效）: x/y —— 组件可能已不存在，试 su -c acc_ctl clean
```

同类失败 10 分钟内只记一次，不会刷屏。

恢复失败时保留 `targets.txt` 中的选择并记录失败；手动执行 `acc_ctl clean` 时才会清理已经不存在的组件。点检的失败与拒绝计数只针对当前选中的目标。

要排查问题就把 `/data/adb/acc_keeper/settings.conf` 里的 `VERBOSE` 改成 1 再 `acc_ctl restart`，会额外记录进程启动、新启用、每轮恢复的完整明细。

## 配置文件与目录

数据目录 `/data/adb/acc_keeper/` 只有两层：根目录放用户文件，运行时文件按用途分目录。

```
/data/adb/acc_keeper/
├── targets.txt     守护列表，一行一个组件，支持 # 注释
├── settings.conf   POLL_FAST / POLL_SLOW / BOOT_FAST_SECONDS / BOOST_TICKS / STRICT
├── logs/
│   └── acc_keeper.log   本轮开机的日志（设备重启时清空重建）
├── state/
│   ├── daemon.pid       守护进程身份（pid + 启动时刻 + boot_id）
│   ├── last_good        上次确认在线的目标
│   ├── last_boot        上次记录的 boot_id
│   ├── last_exit        上次退出摘要
│   ├── last_fail        失败节流签名与时间
│   ├── rejected.txt     被系统拒绝的组件（不再重试）
│   ├── fixes.count      累计修复次数
│   ├── ticks.count      累计检查次数
│   ├── paused           暂停到期时间戳
│   └── stop             停止标记
└── locks/
    ├── daemon.lock      守护单实例锁
    ├── work.lock        巡检 / 目标修改互斥锁
    └── lifecycle.lock   启动 / 停止 / 重启互斥锁
```

旧版平铺在根目录的文件（`acc_keeper.log`、`daemon.pid`、`.last_boot`、`.daemon.lock` 等）会在首次运行新版本时自动搬到上面的位置，无需手工处理。

每次**设备重启**，模块卡片上的描述会被重置成「○ 未运行｜开机初始化中」，`fixes.count` 与 `ticks.count` 也从 0 重新计；守护起来后按实际状态改写描述，所以卡片上的「已恢复 N 次」是**本次开机**的次数。同一 boot_id 内的 `acc_ctl restart` 不重置，方便连续排查。

`STRICT` 是旧版兼容字段；当前守护与点检始终保留系统中未选入守护的服务。

## 排查

**WebUI 一直转圈 / 列表空白**

v1.5.0 有个致命 bug：调用 `ksu.exec` 时把回调函数当成了第二个参数，而 KernelSU 的签名是 `exec(cmd, optionsJson, callbackFuncName)` —— 第三个参数必须是**注册在 window 上的函数名字符串**。传错的结果是原生侧永远不回调，页面等 20 秒超时。v1.5.1 已修，界面现在会明确写出"命令超时"或"读取失败"，不再是空白。

分两层排查：

```sh
su -c acc_ctl dump | head -20     # 有输出 = 模块本身正常，问题在 WebUI 桥接
su -c acc_ctl status              # 守护进程是否在跑、系统里的值是什么
```

- `dump` 有 `H|` `T|` `S|` `P|` 行 → 模块正常。WebUI 还空着，就把这条命令的完整输出发我。
- `dump` 报错/无输出 → 模块侧问题，看 `acc_ctl status` 和 `/data/adb/acc_keeper/logs/acc_keeper.log`。

**扫描不到任何无障碍服务**（列表只剩"没有可显示的应用"）

不同 ROM 的 `cmd package query-services` 输出格式不一样：有的给 `name=com.foo/.Svc`，有的把 `name=` 和 `packageName=` 分成两行。v1.5.1 改成三个来源合并（带斜杠的、分开的、`dumpsys accessibility`），覆盖这两种。

## 注意

- **它会和你的手动操作对抗**：在系统设置里关掉目标服务，60 秒内会被重新打开。要临时关闭：`acc_ctl pause 30`。
- 只能恢复"设置里的开关状态"。应用本身崩溃、被冻结、被卸载时无能为力（日志里能看到是哪个组件没恢复）。
- 如果目标组件名写错，日志会出现 `✗ 恢复失败`。
- 模块脚本以 root 运行，`settings put secure` 对 uid 0 是放行的，不需要额外授权。
- WebUI 的图标和中文名来自 KernelSU 管理器的 WebView 接口（`ksu://icon/<包名>`、`ksu.getPackagesInfo()`）；如果你的 KernelSU 版本不提供这些，会自动退回"包名 + 首字母色块"，功能不受影响。
