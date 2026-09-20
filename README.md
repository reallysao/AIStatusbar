# AI Statusbar

在 **Touch Bar 右侧控制条**常驻显示主流 AI 助手（豆包 / ChatGPT / DeepSeek / 通义千问 …）的工作状态，任何前台 App 下都可见，不用切回豆包盯进度。

## 效果

**常驻项**（Touch Bar 最右侧控制条，宽度被系统固定为～55.5pt，紧凑显示）：



| 状态             | Touch Bar 显示                    | 菜单栏图标 |
| -------------- | ------------------------------- | ----- |
| 有 AI 正在执行任务    | 绿点 + `● 2个`（进行中 + 阿拉伯数字：几个任务在跑） | 绿点    |
| AI 停下来等确认 / 权限 | 红点 + `● 等待`（红色提醒）               | 红点    |
| 任务刚结束          | 橙色闪烁 3 次 `● 完成`                 | 橙点    |
| 全部空闲（但应用开着）    | 灰点 + `● 空闲`                     | 灰点    |
| 所有监控应用都没在运行    | 灰点 + `● 未运行`                    | 灰点    |
| 用户暂停           | 灰点 + `● 暂停`                     | 灰点    |

**一级详情**（**点击常驻项**弹出，30 秒无操作自动收起）：只显示**正在运行**的 AI，最多 4 个；每个一栏：



* 状态圆点 + 应用名 + 工作状态 + 并发数量（阿拉伯数字）+ 各自进度（已完成步骤数）

* 不显示运行时间

> **关于 "任务数 / 进度" 的口径**（都是估算 / 可观测信号，非官方数据）：
> **并发任务数**
>
>  \= 任务执行基础设施（AgentInfraService）当前活动的直接子进程数（实测每个都是 
>
> `/bin/bash`
>
> ，一个 = 一个正在执行的工具调用）；
> **已完成步骤数**
>
>  \= 逐个跟踪这些子进程的消亡，每结束一个计一步（支持并发）。

## 自动识别

启动时自动扫描 `/Applications` 与 `~/Applications`，匹配内置的主流 AI 应用表（豆包、ChatGPT、DeepSeek、通义千问、Kimi、智谱清言、文心一言、元宝、Copilot、Claude、Gemini、Grok、天工、秘塔、讯飞星火、Poe），**装上即被识别**；详情面板只显示正在运行的、最多 `maxActive`(4) 个。

## 安装



1. 把 `AIStatusbar.app` 拷到「应用程序」或任意位置，双击启动。

2. 菜单栏图标 →「测试状态条」，Touch Bar 应闪烁 3 次。

3. 想开机自启：菜单栏 →「开机自动启动」（记录的是 App 当前路径，移动后需重新点一次）。

## 原理与隐私



* **状态检测**：纯进程级监测（枚举进程、读 CPU），**不读取任何按键、屏幕或网络内容**。


  * 豆包执行任务时，内部 `AgentInfraService` 会派生工作子进程（子进程数 = 并发任务数）；

  * 思考 / 生成阶段无子进程但应用全部进程瞬时 CPU 明显升高（CPU 仅作为活动判定信号，不展示）；

  * 等待确认 / 权限的判定：工作途中无活动信号持续超过分级阈值 → 红色提醒；持续 `awaitingSeconds` 秒仍无恢复 → 结束并闪烁。分级阈值：一步未完成的刚启动任务 10 秒（`awaitingEnterSeconds`）；已跑过多步的任务思考间隙更长，自动放宽到 3 倍（30 秒），避免把正常思考间隙误报成"等待确认"。

* **Touch Bar 显示**：公开 API `NSTouchBarItem.addSystemTrayItem` + 私有框架 DFRFoundation 的 `DFRElementSetControlStripPresenceForIdentifier` 注入控制条；详情面板用 NSTouchBar 的 `presentSystemModalTouchBar:systemTrayItemIdentifier:`（类方法，动态调用）。BetterTouchTool / MTMR 同款机制，仅需显示权限。系统睡眠唤醒 / 外接屏切换会清掉第三方控制条项，App 每 5 秒保活、每 60 秒完整重注册。

* 退出时自动移除 Touch Bar 状态条。

## 配置

配置文件：`~/Library/Application Support/AIStatusbar/config.json`（首次启动自动生成）



```
{

&#x20; "pollSeconds": 2,

&#x20; "enterSeconds": 2,

&#x20; "exitSeconds": 4,

&#x20; "flashCount": 3,

&#x20; "awaitingSeconds": 15,

&#x20; "awaitingEnterSeconds": 10,

&#x20; "maxActive": 4,

&#x20; "apps": \[

&#x20;   { "name": "豆包", "processes": \["Doubao.app"], "infraProcesses": \["AgentInfraService"], "cpuThreshold": 15 },

&#x20;   { "name": "ChatGPT", "processes": \["ChatGPT.app"], "cpuThreshold": 20 },

&#x20;   { "name": "DeepSeek", "processes": \["DeepSeek.app"], "cpuThreshold": 20 },

&#x20;   { "name": "通义千问", "processes": \["通义千问.app", "Qianwen.app", "Tongyi.app"], "cpuThreshold": 20 }

&#x20; ]

}
```



* `processes`：进程路径关键词（大小写不敏感），匹配到即算该应用在运行。

* `infraProcesses`：任务基础设施进程名。其**直接子进程**作为 "并发任务数"、逐个消亡作为 "已完成步骤数"。没有就不填，仅靠 CPU 信号判定。

* `cpuThreshold`：聚合 CPU% 阈值，仅作为 "是否在思考 / 生成" 的判定信号。

* `awaitingSeconds`：进入"等待确认"后，持续无活动多久视为任务结束；`awaitingEnterSeconds`：任务刚启动（一步未完成）时，无活动多久进入"等待确认"（已跑过多步的任务自动用 3 倍阈值）；`maxActive`：详情面板最多显示的活跃应用数。

修改后重启 App 生效。

**扩展其他应用（如 WorkBuddy）**：装上后若未被识别，在 config.json 的 `apps` 里复制一个条目，改 `name`/`processes` 即可；若该应用有类似 AgentInfraService 的任务基础设施进程，把进程名加进 `infraProcesses`，就能显示并发数与步骤进度。

## 日志

`~/Library/Logs/AIStatusbar.log` — 每个应用独立的状态切换、并发 / 步骤计数，排查先看这里。

## 重新构建



```
./build.sh   # 产物 AIStatusbar.app
```

## 已知限制



* 仅支持带 Touch Bar 的 MacBook。

* 控制条项目宽度被系统固定为～55.5pt，常驻项只显示紧凑内容；完整数据在详情面板和菜单栏。

* DeepSeek、通义千问桌面版需自行安装，装上即自动识别；若包名与预置关键词不同导致没识别，把真实包名填进 config.json 即可。

* 应用不开放任务进度 API，"进度" 以**并发任务数 + 已完成步骤数**体现（可观测信号，非官方数据）。

* 低资源占用：共享进程表 + 字节级粗筛 + 路径缓存 + 2 秒轮询 + 界面去重，稳态 CPU 约 1%（可配置 `pollSeconds` 放宽）。