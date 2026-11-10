# Leapin 验收记录（v1.9，macOS 27.3 / arm64）

本文件只记录**真实跑过**的命令与结果，以及明确未验证的部分。所有结论都可用下方命令复现。
v1.3 在 v1.2 视觉基础上只动 App 层：动效令牌化 + 全量 reduceMotion、按钮焦点环、设置页窄窗单列；网络/策略/Runtime 行为未变。
v1.4 把视觉层迁到 macOS 26 Liquid Glass（窗口 behind-window 材质 + 功能层玻璃 + 内容层 clear glass），仍是纯 App 层改动，网络与策略行为未变。
v1.5 开始 v3 路线图的 P0（诚实性）：AUTO 真测速、PROCESS/SRC-IP 接上、每条连接带裁决链、导入报告单列不可拨协议。
v1.6 交付 P1 控制面（action API / SSE / token / 审计 / diff reload / CLI）与 P3 规则索引 + 永不命中诊断。
v1.7 交付 P2 设备身份 + 局域网同步 + 只读 Web 面板；P4+ 需 NE 签名，只交付设计 docs/P4-DESIGN.md。
v1.8 把项目从 TouchFlow 更名为 **Leapin**（中文名暂未定）：模块/CLI/App/bundle/数据目录/钥匙串/环境变量全部改名，旧数据自动迁移。
v1.9 把「永不命中」判定收敛成一份共享分析器（引擎 / 控制面 / 编辑器同一实现），补上 RULE-SET 递归与取反语义；网络与控制面行为未变。
历史小节（v1.0–v1.7）保留原验收事实，路径与二进制名按现名统一。

## 0. 视觉重构验证（v1.2）

- 构建：`swift build --scratch-path .build-app` 与 `./scripts/build-app.sh debug` 均成功，零 error / warning。
- 测试：`swift test --scratch-path .build-app` 全部 suite passed（Core 1 / Policy 41 / Net 69 / Integrations 11）。
- 端到端：`./scripts/smoke.sh` → **pass=7 fail=0**。
- 截图核对（1040×752 与 900×700 两档，浅色 + 深色）：总览 / 分流规则 / 抓包 / 去广告 / SSH / NAS / 智能学习 / 隐私 / 配置 / 设置十页逐页目视；
  取证目录 `/tmp/tffinal2/`（2026-11-05 最新一轮：10 页浅色 + 深色 + 900 宽三套）。
- 本轮修掉的可见缺陷：搜索框整框红描边 → 底部下划线；深色幽灵按钮白药丸（NSColor dynamic provider 在 ButtonStyle 内解析成浅色 → 改 `Color.primary` 语义色）；
  策略色滥用（绿/紫/红同时出现）→ 墨阶；隐私页 0/0/0 给 100 分 → 无样本态；抓包 900 宽 1:1 分栏 → 内容宽 <820 单栏 + 右侧详情检视层（esc 关闭）；总览首屏全 0 → 1 主 4 从 + 最近连接上移 + 双向流量地震仪；导航平铺十页 → 五组按域分组（工作区/代理/观测/工具/系统）；mono 字号收敛到 10 / 12、系统字号收敛到 9/10/12/13/22/34；永久骨架屏 → 空白账页横线（不再读作加载中）；隐私刻度 9pt×0.55 → 10pt 且全不透明；规则表补逐行发丝线与表尾合计；行选中从浅朱红改为中性墨底 + 左侧 accent 胶囊。
- 工作态取证：启动代理后经 127.0.0.1:7890 打真实请求（example.com / httpforever.com / doubleclick.net），
  截取总览（活动连接、拦截 2、抓包 9、34.0 KB、双向曲线有数据）、抓包列表（9 条含 403 拦截）与详情检视层（请求/响应头真实内容）。
- 未验证：真机 120Hz 下动画逐帧（只能目视）、VoiceOver 逐页完整走查（只验证了控件标签与 reduce-motion）。

## 0.1 交互一致性验证（v1.3，2026-11-05）

- 动效收敛：全 App 动画调用统一到 `LPMotion` 六条令牌（press 0.12 / quick 0.14 / standard 0.18 / emphasized 0.28 / spring 0.26·0.82 / enter 0.38）。
  声明式用 `.lpAnimation(token, value:)`，命令式用 `LPMotion.run(token) { … }`；两者内部读 `accessibilityReduceMotion`，打开时分别为 nil 与直接落位。
  `grep -rn "withAnimation|.animation(" Sources/LeapinApp` 只剩 `lpAnimation` / `LPMotion.run` 的实现与两处持续动画（状态点脉冲、不确定进度条），后者各自 guard reduceMotion。
- 按钮焦点环：`LPButtonFocusRing` 包在 `LPPrimaryButtonStyle` / `LPGhostButtonStyle` 内，读 `\.isFocused`，按钮外 3pt 处描 2pt 朱红（圆角 10）。
  验证方式：临时 `LEAPIN_RING=1` 强制显示并截图（去广告页「检查」按钮，环贴合 7pt 圆角按钮且不遮挡文字），取证后移除该临时开关（`grep LEAPIN_RING` 为 0）。
- 设置页单列：`EnvironmentValues.lpWindowWidth` 由根视图 GeometryReader 注入；`<1000` 单列（代理端口 → DNS → 启动与常驻 → 抓包与解密 → 高级，限宽 620 居中），`≥1000` 两列。
  实测 900×700 单列（浅色 `/tmp/tfm3/settings-900c.png`、深色 `/tmp/tfm3/settings-900-dark.png`）、1040×700 仍两列（`/tmp/tfm3/settings-1040.png`），均无中间截断、无横向溢出。
- 构建 / 测试 / 端到端：`./scripts/build-app.sh debug` 成功；`swift test --scratch-path .build-app` 122 条全绿（Core 1 / Policy 41 / Net 69 / Integrations 11）；`./scripts/smoke.sh` pass=7 fail=0。
- 未验证：真实键盘 Tab 走查（本机 `AppleKeyboardUIMode=0`，无辅助功能权限模拟按键）；焦点环的 `\.isFocused` 检测依赖该按钮成为 key view，属 SwiftUI 标准语义。

## 0.2 Liquid Glass 改造验证（v1.4，2026-11-05）

- 环境：macOS 27.3（26.0+ API 可用）/ Swift 6.4.2 / SDK MacOSX27.2；全部玻璃分支包在 if #available(macOS 26.0, *)，macOS 14–15 回落到 Material + 实色。
- 构建：./scripts/build-app.sh debug 成功；swift build --scratch-path .build-app 零 error / warning。
- 测试：swift test --scratch-path .build-app → 122 条全绿（Core 1 / Policy 41 / Net 69 / Integrations 11）。
- 端到端：./scripts/smoke.sh → pass=7 fail=0（明文 HTTP / CONNECT / SOCKS5 / 独立 socks 端口 / 规则解释 / 去广告 / DNS）。
- 窗口材质：Platform.swift WindowAutosave 里 window.isOpaque=false + backgroundColor=.clear，frame view 下插入 NSVisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)；验证方式为把窗口拖到彩色壁纸上截图，确认 40% 洗色后能看到壁纸色彩而非纯色。
- 截图核对（2026-11-05 最新一轮）：
  · 1040×752 浅色 10 页：/tmp/glass5/light-*.png；深色：/tmp/glass5/dark-*.png；
  · 900×700 窄窗：/tmp/glass5/narrow-settings.png、narrow-rules.png、dark-dashboard.png、dark-settings.png。
- 本轮修掉的可见缺陷：① 分流规则工具栏下方一条纯色白带（toolbar 的 background(LP.bg) 叠在玻璃页面上）→ 删除该背景；② 752 高时侧栏底部「配置 / 设置」被状态卡压住 → 组间距 16/6→10/4、行高 7→5；③ 900 宽 compact 侧栏选中行的左侧 accent 胶囊压在居中图标上 → overlay 仅在非 compact 时渲染；④ 面板偏白偏粉 → 卡片改 clear glass + cardTint，窗口洗色 62%→40%；⑤ 主按钮 tint 玻璃导致朱红发灰 → 回退不透明 accentFill（注释记录取舍）。
- 验证取舍：主操作按钮不使用 tint 玻璃（Glass.tint(accentFill) 在浅底把朱红洗成灰、白字对比 <2:1），代码注释写明“可读性优先于材质一致性”。
- 未验证：真实 macOS 26 硬件上的玻璃折射观感（本机系统版本高于 26，但截图无法反映动态折射）；reduceTransparency 关闭材质后的完整 10 页走查只抽查了总览与设置两页；真机 Tab 走查未做（无辅助功能权限，同 v1.3）。

## 0.3 P0 诚实性验证（v1.5，2026-11-05）

P0 的目标不是加功能，而是把「界面上说了、引擎里没做」的地方要么做真、要么说清。
本轮四项：AUTO 真测速 / PROCESS 与 SRC-IP 接上 / 规则链 / 导入报告标出不可拨协议。

- 构建：`swift build --scratch-path .build-app` 零 error；`./scripts/build-app.sh debug` 成功。
- 测试：`swift test --scratch-path .build-app` → **132 条全绿**（Core 1 / Policy 51 / Net 69 / Integrations 11）；
  新增 `Tests/LeapinPolicyTests/HonestyTests.swift` 10 条：url-test 选最快 + 滞回不抖、fallback 跳过 dead、
  SRC-IP-CIDR 命中、chain 含 RULE-SET 成员且 MATCH 为 final、vmess 标记不可拨、导入报告 notDialable 计数。
- 端到端：`./scripts/smoke.sh` → **pass=7 fail=0**。
- 工作态取证（`LEAPIN_AUTOSTART=1` 直接跑 `dist/Leapin.app/Contents/MacOS/LeapinApp`）：
  · 归属：`curl -x http://127.0.0.1:7890 http://httpforever.com/` → 200；抓包详情显示 `curl`、`127.0.0.1`，
    总览最近连接显示「23:23:32 curl PROXY 兜底」。进程归属走 libproc（C target `CLeapinProc`）+ 1 秒端口快照，
    不再依赖「猜测」。（`/tmp/tfp0/capture-chain3.png`、`/tmp/tfp0/dashboard-attr.png`）
  · 规则链：同一条请求的详情卡「裁决链 / RULE CHAIN」显示「第 9 / 9 条」「01 FINAL,PROXY」
    与脚注「没有命中具体规则，由兜底 MATCH 裁决」——链路数据来自 `RouteDecision.chain`，不是 UI 事后拼的。
  · 测速：启动代理 8 秒后规则页 AUTO 组显示「当前 DIRECT」「最快 DIRECT 698 ms」，出站行同步显示 `698 ms`；
    数值来自 `HealthProber` 对 `www.gstatic.com:443` 的真实 TCP 握手（`LPHealth` 记录），停代理后立刻回落为「未运行 / 尚未测速」。
    （`/tmp/tfp0/rules-latency3.png`）
- 行为变更（写进导出/导入路径）：
  · `ImportReport.notDialable`：导入含 vmess/vless/hysteria2/tuic 等协议的订阅时，报告单列「协议 X 已保留但暂不可拨号（N 个出站）」，
    并在 summary 追加「N 个出站暂不可拨号」；`validate()` 同样对不可拨协议出 issue，不再让用户以为「导入成功＝能用」。
  · `PROCESS-NAME` 规则与 `SRC-IP-CIDR` 规则现在真的参与裁决（前者用归属 PID 的可执行名，后者用客户端地址）。
  · 自动策略组（url-test / fallback / load-balance）使用实测延迟，180 秒内有效、带 50ms 容差滞回，避免来回切换。
- 已知未验证 / 边界：
  1. 真实 ss/vmess/trojan 节点的 url-test 只做了单元级（LPHealth 注入）验证；本机没有可用服务器，未做真节点握手。
  2. MITM 解密后的请求，chain 与 sourceIP 取的是 CONNECT 阶段的决策（主机级）；同一隧道内多个 URL 的链不重新计算。
  3. 进程归属基于 TCP 端口快照，UDP/QUIC 与生命周期短于一秒的连接可能归不到进程（此时仍显示 IP）。

## 0.4 P1 控制面 + P3 规则索引验证（v1.6，2026-11-05）

本轮两条线：P1 控制面（本地 action API + SSE + token + 审计 + 局部 diff reload + CLI 三件套），
P3 规则索引与诊断（后缀 Trie / AC keyword / IP radix + 10 万规则门限 + 编辑器「永不命中」）。

- 构建：`swift build --scratch-path .build-lead` → Build complete，0 error / 0 warning；`./scripts/build-app.sh debug` 成功。
- 测试：`swift test --scratch-path .build-lead` → **178 条**（Core 1 / Policy 75 / Net 75 / Integrations 11 / Control 16），0 failures；
  Policy 的 perf 用例在 debug 下 1 条 skip，release `LEAPIN_PERF=1` 通过。
- 端到端：`scripts/control-e2e.sh` → **pass=22 fail=0**；`scripts/smoke.sh` → **pass=10 fail=0**
  （明文 / CONNECT / SOCKS5h / 独立 socks 端口 / rule explain / adblock / dns resolve / rule diagnostics / dns trace / http probe）。

### P1 控制面

- 端点（默认 `127.0.0.1:7900`，`controlEnabled=true`、`controlAllowLAN=false`）：
  GET `/v1/status`、`/v1/connections`、`/v1/policies`、`/v1/audit`、`/v1/events`(SSE)；
  POST `/v1/policies/select`、`/v1/reload`、`/v1/explain`、`/v1/dns/trace`、`/v1/http/probe`。
- 鉴权：`$LEAPIN_PROFILE_ROOT/control-token`（目录 0700、文件 0600、64 hex、原子写、复用）；无 / 错 token → 401 且写审计；
  e2e 实测 `stat -f %Lp` = 600。
- 审计：`control-audit.jsonl`，字段 timestampMs / method / remote / allowed / tokenPrefix / action / status / path / detail，>5MB 轮转 `.1`；
  e2e 验证 reload 与被拒请求都落审计。
- 局部 reload：`POST /v1/reload` 重读配置并按 diff 应用；e2e 用 120000B 慢速下载贯穿 reload，连接未断（`restarted=false`），
  新规则在 reload 后立即生效（REJECT）。
- SSE：`/v1/events` 支持 `since` 回放 + 实时事件；e2e 收到含 example.com 的事件帧；客户端断开由空闲 receive 探针 <1s 摘除
  （修掉「只写不读」导致断连客户端泄漏）。
- CLI：`leapin rules <host> [--diagnose|--measure N]`、`dns <host> --trace`（source / upstream / elapsedMs / cacheTTL / resolved + steps）、
  `http-probe <url> [--timeout ms] [--json]`（不走系统代理，最多 3 跳重定向，逐跳 remoteAddress）。
- 导入 / 导出：Clash 与 Surge 双向支持 `control-port` / `control-allow-lan`。

### P3 规则索引与诊断

- 索引：域名后缀反向标签 Trie + 精确域名字典 + DOMAIN-KEYWORD Aho-Corasick（非 ASCII contains 兜底）+
  IPv4/IPv6 前缀树（目标 IP 与 SRC-IP-CIDR 各一棵）+ PROCESS-NAME 字典；negate / AND / OR / NOT / GEOIP / DOMAIN-REGEX 进 alwaysCheck 超集。
  candidates 返回升序去重候选，逐条 evaluate、首命中即停；explain 保持线性，确保未命中规则可见。
- 正确性：`RuleIndexDifferentialTests` 320 组随机规则集 × 12 meta（3840+ 次）与线性参考全字段对比
  （policy / outbound / matchedRule / chain index / isFinal / 步骤 label+detail / explain trace）全部一致。
- 性能（release）：`LEAPIN_PERF=1 swift test -c release --filter RuleIndexPerf` → rules=100001、load=99.6ms、p50=0.003ms、**p95=0.006ms**、p99=0.009ms
  （阈值 p95<2ms、load<300ms 均通过）。独立复核：`.build-bench/release/leapin rules example.com --profile .bench/profiles/rules-100000.surge --measure 2000`
  → p50 0.001ms / p95 0.001ms。
- 诊断：`RuleEngine.diagnostics()` 输出 duplicate / shadowed / unreachable / never-match / rule-set-missing
  （0-based index，reason 用 1-based 文案；宁可漏报不误报）；15 个单测覆盖 5 类与反例。
  `leapin rules <host> --diagnose` 打印 1-based 列表（#2 与「被 #1 遮蔽」）。
- 编辑器：RulesView 侧栏「诊断 / DIAGNOSTICS」显示永不命中计数与前 4 条（点击跳转并选中），RuleRow 加「永不命中」徽标 + help 原因，
  AddRuleSheet 在添加前预览 draft 是否永不命中；扫描只在 .task / 规则数变化 / 重载 / 增删后触发，不在 body 内计算。
  扫描实现 `RuleDiagnosticsScan.swift`（保守：regex 编译失败、CIDR 非法、父域覆盖、CIDR 包含、MATCH 之后不可达）。
  （v1.9 起该文件已删除，引擎与编辑器共用 `RuleDiagnosticsAnalyzer`，见 §0.8。）

### 未验证 / 限制

1. 编辑器诊断只做了编译级与逻辑级验证，未在真实 App 窗口目视取证（本次启动 App 未能可靠截到窗口）。
2. `diagnostics()` 只看已加载规则，不递归 RULE-SET 成员内部；成员诊断需对 set 引擎调用 `diagnostics(sourceRules:)`。
   （v1.9 已实现 RULE-SET 递归并统一为共享分析器，见 §0.8；此处保留 v1.6 当时的限制记录。）
3. 遮蔽只覆盖可证明场景（同 matcher、后缀祖先、CIDR 包含），regex / geo / keyword 跨 matcher 不判定。
4. control 热重载不覆盖监听器变更（MITM / capture / bypass 变更列 skipped，需手动重启）。
5. 真机 120Hz 动画与 VoiceOver 走查仍沿用 v1.4 结论，本轮未重做。

## 0.5 P2 设备身份 + 同步 + 只读面板验证（v1.7，2026-11-09）

P2 不在本轮点名的 P1/P3 里，但它是路线图中 P1 之后、且不依赖 Network Extension 签名的下一期；
上一轮残留的设备身份/同步半成品未提交，本轮把它做完并纳入验收，避免工作区长期挂着一份未验证的代码。

- 构建：`swift build --scratch-path .build-verify`（全新 scratch）→ Build complete，**0 error / 0 warning**；
  `./scripts/build-app.sh debug` 成功（ad-hoc 签名，App 内暂无同步页）。
- 测试：`swift test --scratch-path .build-lead` → **201 passed / 1 skipped / 0 failures**
  （Core 1 / Policy 75（1 skip）/ Net 75 / Integrations 11 / Control 16 / **Sync 24**）。
  新增 `Tests/LeapinSyncTests`：DeviceIdentity 5、ProfileVersionStore 6、SyncTransport 8、SyncPanel 5。
- 端到端：`LEAPIN_BIN=.build-lead/debug/leapin ./scripts/sync-e2e.sh` → **pass=36 fail=0**；
  `control-e2e.sh` → **pass=22 fail=0**；`smoke.sh` → **pass=10 fail=0**。
- 收敛：隔离双存储 A/B 从「配对」到「B 应用 A 的版本」实测 **0.19 s**（路线图阈值 5 s）。

### 设备身份
- Ed25519（CryptoKit），只持久化 32 字节 seed；默认登录钥匙串（service `com.leapin.device`），
  无钥匙串权限时回落 `$LEAPIN_PROFILE_ROOT/device/device.key`（0700 目录 / 0600 文件 / 原子写）。
- `deviceID` = SHA-256(公钥) 前 16 字节 hex；`fingerprint` = 前 8 字节按 4 hex 分组（`0b22-21b8-7708-9a61`）。
- 单测覆盖：签名/验签、tamper 拒绝、±300s 时间戳拒绝、文件 0600、创建后重载身份稳定。

### 版本与收敛
- 版本 id = 规范化 JSON（sortedKeys、ISO-8601）的 SHA-256；`ProfileContent` 排除本地 UUID 与 `sourcePath`，
  因此同一订阅在两端哈希一致；`ingest` 重算 hash，不匹配直接拒绝。
- 指针 LWW（updatedAtMs → deviceID 破平局），单调不回退；`override.json` 本机固定版本、永不同步。
- `SyncClient.syncOnce()` 一次完成：拉 manifest → 拉缺失版本 → merge 指针 → announce 发布 → 对端缺内容时 3 MiB 内联推送。
- e2e 步骤：首版本 → 配对 → 拉取/应用 → 停服离线编辑（B 新建版本）→ 重启 A → 重新配对 → A 收到 B 的离线版本
  → override 固定回 v1（A 不受影响）→ 清除 override → 错误配对码被拒。

### 协议与鉴权
- 明文 HTTP/1.1（`Connection: close`），路由 `/v1/info`、`/v1/pair`、`/v1/manifest`、`/v1/versions/<64hex>`、`/v1/announce`、`/panel`。
- 签名覆盖 `LP-SYNC-1\nMETHOD\nPATH\nSHA256(body)\nTS_MS\nNONCE`；服务端 ±300s + nonce 缓存（600s / 8192 上限）→ 重放 409。
- 配对码 6 位 / 300s / 单次 / 常量时间比较；请求体上限 4 MiB，响应 8 MiB，内联推送 3 MiB。
- e2e 覆盖：无签名 401、错误配对码拒绝、重放拒绝、未配对设备拒绝、未知版本 404（均见 SyncTransportTests + sync-e2e）。

### 只读面板
- `GET /panel`（HTML）与 `GET /panel.json`；令牌 32 字节 CSPRNG，`$LEAPIN_PROFILE_ROOT/sync/panel-token`（0600 / 目录 0700），
  每次请求重新读文件，`leapin sync panel --rotate` **即时生效**。
- 只展示元数据（设备、指纹、版本历史、指针、已配对设备），**不含规则/出站/DNS/凭据**；无脚本、无外链、插值全部 HTML-escape。
- 所有写方法 405；无令牌或错令牌 401；`--no-panel` 时路由 404。
- e2e 面板断言 10 项：令牌存在/0600、无令牌 401、错令牌 401、HTML 200、含只读横幅、不含规则值、
  panel.json 版本数、`readOnly=true`、POST 405、第二轮版本数与生效版本一致。

### 本轮修掉的真实缺陷
- `PeerRegistry.upsert` / `touch` 在持有 NSLock 时又调用会加锁的 `peer(deviceID:)`；NSLock 不可重入，
  首次配对即**死锁**——全量测试挂起，`sample` 显示 `com.leapin.sync.server` 队列停在 `PeerRegistry.upsert`。
  修复：新增 `peerLocked` 私有函数（调用方已持锁），`upsert`/`touch` 改用它；新增
  `testPeerUpsertAndTouchDoNotDeadlock`（3 s 信号量超时）防止回归。
- **控制面 select 偶发空响应**：`LeapinEngine.saveProfile()` 在 P2 里同步调用了 `syncService.recordActiveProfile()`，
  首次访问设备身份可能走 Keychain（或 0600 文件回落）；控制面 `POST /v1/policies/select` 在这条路径上被拖住，
  curl 5 秒超时后拿到空 body（状态其实已改），表现为 `select PROXY→REJECT` 偶发失败（fresh 全链路第一次 20/22、单跑 21/22）。
  修复：`syncService` 改为 init 时构造（不再是 lazy），版本记录移到 utility 队列异步执行，保存路径不等 Keychain；
  连续 3 次 `control-e2e.sh` 均 22/22。
- 顺带清掉 fresh build 暴露的全部编译警告：`ProfileStore.save` var→let、`LeapinEngine.saveProfile` 的 `_ = try?`、
  `ProfileVersionStore.setOverride` 多余 `try`、`MiniYAML` var→let、`ControlServer` 的 `_ = try?`，
  以及 `ByteStream` 的 NSLock 跨 await（改同步快照 + 一次性 ResumeGate，消除 Swift 6 并发诊断）。

### 未验证 / 限制
1. 两台**真实物理机**的局域网配对未做；e2e 与传输测试都在 127.0.0.1、两个隔离 store 上跑。
2. 只读面板只验证了 HTTP 层与 HTML 文本；没有在 iPhone/Safari 实际渲染取证。
3. App 内没有同步页/面板开关；`leapin sync serve` 是当前唯一入口，且是前台进程，无后台自动同步。
4. 配对码无失败退避（6 位 + 5 分钟 + 单次，但局域网内可反复尝试）；`SyncPeer.scopes` 只记录未强制。
5. 跨公网/云端 E2EE 未做；P2 的 scope 是「同一 WiFi 下两台自己的机器」。
6. 路线图 P2 验收里的「iPhone 切节点不影响 Mac」未验证：没有 iOS 客户端，只读面板不能切换节点；
   设备级 override 只验证了本机固定版本、A 不受影响。

### P1 / P3 复核（本轮代码状态，2026-11-09）

- P1 控制面：`control-e2e.sh` 复跑 **22/22**（连续 3 次均通过）、`smoke.sh` 10/10；
  token 401/0600、SSE、select、传输中 diff reload、审计、404/405 全部复验。
- P3 规则索引：release 重建当前源码后
  `.build-verify/release/leapin rules example.com --profile .bench/profiles/rules-100000.surge --measure 2000`
  → rules=100001、**p50 0.001 ms、p95 0.002 ms**（阈值 p95<2ms），匹配到 #100001/100001；
  `leapin rules --diagnose` 与编辑器诊断路径仍由 smoke / Policy 单测覆盖。

### P4+ 设计交付（只设计，未实现）

- 文档：[docs/P4-DESIGN.md](P4-DESIGN.md)（11 章，含现状核查、entitlement 取舍、TUN 数据路径、路由原子回滚、
  网关 + DHCP、Control/SSE/审计扩展、性能预算、风险、分阶段与未实现清单）。
- 事实核查（写入文档前逐条 grep）：仓库内 `*.entitlements` = 0、NE/TUN 代码 = 0、`FakeIPPool.host(for:)` 在 Sources 内 0 调用、
  DNS 监听固定 127.0.0.1、fake-IP 对 AAAA 也回 A 记录、SSE 只有 `event: flow`、审计字段固定。
- 设计结论：P4a 用 packet tunnel + 只服务本地 VIF 的"够用 TCP 栈"，不手工写系统路由（交给 NE settings），
  但回滚必须逐项结果 + UI + 审计；P4b 网关/DHCP 默认关闭且需第二台设备实测。
- 明确未实现：TUN/VIF、NEPacketTunnelProvider、扩展打包、entitlement/公证、路由快照恢复、网关、DHCP、
  `tunnel.*`/`routes.*` action 与 SSE、审计新字段。
- 待拍板（会改 P1 代码，本文未实施）：SSE 帧泛化、审计改 Engine 单写者 + 可选字段。
- 实现前最需要验证：① 付费账号 + development profile 能否真正激活 packet tunnel、扩展能否写 sysctl/pf；
  ② "够用 TCP 栈"与 Fake-IP 反查/DNS 应答核心的断链；③ NE 路由在扩展被杀/断电时是否随接口消失（需 14/15/26 三档实测）。

## 0.6 改名验证：TouchFlow → Leapin（v1.8，2026-11-10）

改名不是换文案，是一次全量重命名 + 一次数据迁移。公开面（模块、CLI、App、bundle、URL scheme、环境变量）
与持久化面（数据目录、钥匙串 service、广告列表、CA）都动了。

- 命名：`LEAPIN` 字标 / `Leapin` 正文 / `leapin` 代码；口号 `One leap. No detour.`；中文名暂未定（「一跃」评估后放弃，见 [docs/BRAND.md](BRAND.md)）。
- 代码：`TouchFlowCore/Policy/Net/Integrations/Control/Sync/Runtime/App` → `Leapin*`；`TF` 命名空间 → `LP`；
  `tfctl` → `leapin`；C target `CTouchFlowProc` → `CLeapinProc`；C 符号 `tf_*` → `leapin_*`；环境变量 `TF_*` → `LEAPIN_*`。
- 构建：`swift build --scratch-path .build-verify`（全新 scratch）→ **0 error / 0 warning**；
  `./scripts/build-app.sh debug` → `dist/Leapin.app`，`CFBundleIdentifier=com.leapin.app`、`CFBundleExecutable=LeapinApp`、ad-hoc 签名。
- 测试：**205 passed / 1 skipped / 0 failures / 0 warnings**（新增 `LeapinRuntimeTests` 4 条迁移测试）。
- 端到端（全部用 `.build-lead/debug/leapin`）：`sync-e2e.sh` **36/36**、`control-e2e.sh` **22/22**、`smoke.sh` **10/10**。
- 数据迁移（真机）：
  · 旧 `~/Library/Application Support/TouchFlow`（5 个非密钥文件）→ `…/Leapin`（同样 5 个）；`leapin profiles` 读回 9 条规则的默认配置。
  · 广告列表 `lists/touchflow-ads.txt` → `lists/leapin-ads.txt`（106 行）；`leapin adblock doubleclick.net` 输出 103 条规则并命中拦截。
  · 设备身份：`ProfileSyncService.loadOrMigrateIdentity` 单测验证「旧 seed → 新 store、deviceID 不变、幂等」；
    真实钥匙串读取未在自动化里触发（可能弹系统授权框），只验证了逻辑路径。
  · CA：本机旧目录没有 `ca/`（从未开启 HTTPS 解密），因此没有可实测的 CA 延续；迁移代码会把 `ca/` 整体复制，
    旧 CA 存在时继续沿用（CN 仍为 `TouchFlow Root CA`，避免用户重装证书），全新安装才生成 `Leapin Root CA`。
    工具未直接读取 .pem 内容。
- 未验证 / 未做：真实 SSH/NAS 钥匙串凭据迁移（无真实凭据可测）；旧数据目录删除（刻意保留以便回滚）；
  工作区目录 `~/TouchFlow` 尚未改名（会话 cwd 限制）；GitHub 公开仓库已推送（2026-11-10，仓库名 Leapin）。

## 0.7 仓库隐私清理（v1.8，2026-11-10）

发布前对 tracked files 与全部 16 个历史提交做了一次隐私审计与清理。

- 初始命中：本机绝对路径、作者身份（姓名 / 本地邮箱 / GitHub noreply）、机型指纹、SSH 示例用户名、
  示例 LAN 地址、文档里的旧 commit id。
- 当前树：路径改为 `~`，机型改为 `Apple silicon Mac`，示例用户名改为 `user`，示例地址改为 TEST-NET `192.0.2.9`，
  旧 commit id 改为「历史提交」；`.gitignore` 增加 `.env*`、`*.pem`、`*.key`、`*.p12`、`*.log`、`secrets.json`。
- 历史：16 个提交全部重写为单一作者 `Leapin Maintainers <maintainers@leapin.dev>`，每个历史树都重新清洗；
  删除 `refs/original`、清空 reflog 并 `git gc --prune=now`。
- 验证：重写后按「本机路径 / 用户名 / 机型 / 示例 LAN 地址」等模式扫描**全部提交** → **0 命中**；
  `git log --all` 只剩中立作者；`git status` 干净；事后全量测试 **205 passed / 1 skipped / 0 warnings**。
- 原始历史备份保留在仓库外的临时目录（含个人信息，确认无误后删除）；公开仓库已推送（2026-11-10）。
- 边界：GitHub 账户/仓库所有者仍是可见的托管层信息；本机 `~/Library/Application Support` 与钥匙串里的运行数据未动。

## 0.8 P3 诊断统一 + RULE-SET 递归（v1.9，2026-11-11）

P3 的「编辑器能报永不命中」在 v1.6 落地时存在三份实现：`RuleEngine.diagnostics()`、Runtime 的
`RuleDiagnosticsScanner`（引擎未启动时的兜底）、App 的 `RuleDiagnosticsScan`（编辑器与草稿预检）。
三者对 PROCESS / IPv6 / rule-set / 取反的判定并不一致，编辑器会与 CLI、控制面给出不同结论。
本轮收敛为一份可测试的分析器，并补上 v1.6 明确未做的 RULE-SET 成员递归。

### 实现

- 新增 `Sources/LeapinPolicy/Rules/RuleDiagnosticsAnalyzer.swift`：`RuleDiagnosticsAnalyzer.analyze(_:ruleSets:)`
  是唯一判定入口；`RuleEngine.diagnostics()` / `diagnostics(_:)` 改为委托它，引擎只保留 `describe()`。
- `ruleSets` 语义：`nil` = 尚未加载（编辑器在引擎启动前），不报 `rule-set-missing`；`[:]` = 已加载但没有该 set，报 missing。
  这样「不知道」不会被伪装成「配错了」。
- RULE-SET 递归：非 negated 外层 set 的成员为空 → `never-match`（reason 明确写「没有可命中的成员规则（文件为空或加载失败）」）；
  全部成员静态不可命中 → `never-match` 并给出成员数；嵌套 set 用 `visited` 防环；未知 / 递归 / negated set 一律保守视为可命中。
  任一成员可命中则外层不报。
- 取反语义修正：`!MATCH` 恒 false，自身报 never-match；反过来，取反的空值 / 非法 CIDR / 编译失败正则 / 空 OR / 空 NOT
  在运行时是恒 true 的 catch-all，旧实现会误报 never-match，本轮改为不报（宁可漏报不误报）。
- Runtime：`LeapinEngine` 缓存最近一次 `RuleSetLoader.load` 的原始成员（start / reload 成功后更新），
  新增 `ruleDiagnostics(for:)`：引擎运行时走 `engine.diagnostics(source)`，未运行时走 analyzer + 缓存；
  v1.6 的 `ControlWiring` scanner 与 App 的 `RuleDiagnosticsScan.swift` 一并删除。
- 编辑器：`RulesView.refreshDiagnostics()` 与 `AddRuleSheet.draftWarning` 都调 `engine.ruleDiagnostics(for:)`，
  新规则按其追加位置取诊断；规则行徽标、侧栏计数、CLI `--diagnose`、控制面 `POST /v1/explain` 里返回的诊断现在同源。

### 可复现验证（2026-11-11 实测）

- 构建（全新 scratch）：`swift build --scratch-path .build-v3` → Build complete，0 error / 0 warning。
- 测试：`swift test --scratch-path .build-v3` → **216 passed / 1 skipped / 0 failures**
  （Core 1 / Policy 86（1 skip，perf gate）/ Net 75 / Integrations 11 / Control 16 / Sync 24 / Runtime 4）；
  新增 `RuleDiagnosticsTests` 11 条（rule-set 全死 / 空 / 有活成员 / 嵌套 / 递归 / negated、nil 与 `[:]` 区别、
  草稿位置、analyzer↔engine 一致、取反空 matcher 不误报）。
- 诊断 e2e：`LEAPIN_BIN=.build-v3/debug/leapin ./scripts/diagnostics-e2e.sh` → **pass=9 fail=0**。
  真实 profile + 落盘 rule-set：live 集合经成员命中 PROXY、空集合与缺失来源各报一次 never-match、后缀遮蔽指到第 4 条、
  无死规则 profile 打印「没有永不命中的规则」。
- 回归：`control-e2e.sh` → 22/22；`smoke.sh`（端口 17891）→ 10/10；均 exit 0。
- 性能（release）：`LEAPIN_PERF=1 swift test -c release --scratch-path .build-v3-release --filter RuleIndexPerf`
  → rules=100001、load=129.3ms、p50=0.003ms、**p95=0.005ms**、p99=0.006ms（阈值 p95<2ms / load<300ms 通过）。

### 未验证 / 限制

1. 编辑器仍未在真实 App 窗口目视取证（同 §0.4 第 1 条）；本轮只验证到编译、单测与 CLI 同源。
2. 诊断只从外层 RULE-SET 给出一条结论，不逐条列出成员内部诊断；成员数已写进 reason，需要逐条排查时仍可对 set 引擎单独调用 `diagnostics(sourceRules:)`。
3. 遮蔽仍只覆盖可证明场景（同 matcher、后缀祖先、CIDR 包含）；regex / geo / keyword 跨 matcher 不判定。
4. `RuleSetLoader` 把下载失败的 source 物化为空集合（既有契约，PolicyTests 固定断言），因此「文件为空」与「加载失败」在诊断里共用一条 reason，文案已同时写明两种情况。
5. JavaScript 脚本沙箱仍未开始（P3 第三项），不在本轮范围。

## 1. 构建

```
swift build                 # Build complete
swift build --build-tests   # Build complete
./scripts/build-app.sh      # → dist/Leapin.app（ad-hoc 签名）
```

产物：`dist/Leapin.app/Contents/MacOS/{LeapinApp,leapin}`、
`Contents/Resources/Leapin_LeapinRuntime.bundle`（内置广告名单/资源）、`AppIcon.icns`。
零 error、零依赖（无 SPM 第三方包，符合本机无 github.com 的约束）。

## 2. 单元/集成测试

```
swift test
```

| 测试 target | 用例数 | 结果 | 耗时 |
| --- | --- | --- | --- |
| LeapinCoreTests | 1 | 0 failures | 0.001s |
| LeapinPolicyTests | 51 | 0 failures | 2.0s |
| LeapinNetTests | 69 | 0 failures | 8.8s |
| LeapinIntegrationsTests | 11 | 0 failures | 0.8s |
| 合计 | **132** | **0 failures** | ~12s |

> v1.9（2026-11-11）全量复跑：**216 passed / 1 skipped / 0 failures**（Core 1 / Policy 86（1 skip）/ Net 75 /
> Integrations 11 / Control 16 / Sync 24 / Runtime 4），详见 §0.8；上表为 v1.1 基线。

新增覆盖（v1.1）：
- `FormatTests`（20 条）：Clash / Surge / 订阅 / rule-set 往返等价、未知协议保留 `rawType`、`$domain` 作用域、诊断字段。
- `AdBlockCosmeticTests`（2 条）：2 万条 cosmetic 规则建索引线性时间；后缀链匹配与例外优先。
- `ExportFormatTests`（5 条）：hosts / ABP / rule-set 导出**只搬 REJECT**（DIRECT 不得被洗成拦截）、不认识的后缀不写成误拦、hosts 每行两字段。

Net 的 69 个用例是真起 `NWListener` 假服务器 / 真 TLS 握手 / 真代理请求；Policy 含 10 000 条规则规模测试与 100k 过滤规则装载（0.61s，预算 1s）；Integrations 含 Vision OCR 真实识别。

> 说明：并行跑测试时若残留 `leapin run` 占用端口/文件，`CaptureTests` 会卡住（CA 断言 + 进程不退出）。清理进程后稳定通过；`scripts/smoke.sh` 现在会因端口占用直接报 `is already in use` 而不是挂起。

## 3. 端到端代理（真实网络）

`scripts/smoke.sh` 启动 `leapin run`、等待 7890 就绪后逐项检查：

```
PASS  http proxy (plain)      # curl -x http://127.0.0.1:7890 http://example.com/ → 200
PASS  http proxy (CONNECT)    # https://example.com/ 经 CONNECT → 200
PASS  socks5h proxy           # --socks5-hostname 127.0.0.1:7890 → 200
PASS  dedicated socks port    # --socks5-hostname 127.0.0.1:7892 → 200
PASS  rule explain            # leapin rules example.com → 命中 MATCH,PROXY + trace
PASS  adblock verdict         # leapin adblock doubleclick.net → 拦截 ||doubleclick.net^
PASS  dns resolve             # leapin dns example.com → 真实 A 记录
```

结果：**7/7 通过**（v1.1 复跑同样 7/7）。

补充实测：
- 广告拦截经代理闭环：`curl -x http://127.0.0.1:7890 http://doubleclick.net/` → **403**（来自 `blocker`）。
- 内置名单自动落盘：`~/Library/Application Support/Leapin/lists/leapin-ads.txt`（多候选路径 + 递归兜底）。
- 本地 DNS 监听 **5354**（TCP+UDP，只绑 127.0.0.1）；`dig @127.0.0.1 -p 5354 example.com` 正常，`doubleclick.net` 返回 NXDOMAIN。
- 端口冲突时第二个实例退出码 1 且报 `proxy port ... is already in use`（不再静默绑定失败后假装在跑）。

## 4. 系统代理（真实修改并回滚）

```
leapin proxy on      # networksetup 写入 HTTP/HTTPS、SOCKS
scutil --proxy      # HTTPEnable=1 / SOCKSPort=7892
leapin proxy off     # 全部归零
```

v1.1 变更：`stop()` 与 App 退出时**先回滚系统代理**再关监听（此前只能手动关）；
系统代理指向 `proxy.listeningPort`（多端口冲突时实际生效的那个），`enable` 写入失败会 `try? disable()` 回滚。

## 5. 性能（scripts/bench.sh，release leapin）

环境：Apple silicon Mac / macOS 27.3 / arm64，数字为本机实测（3 次取最小）。

| 场景 | 结果 |
| --- | --- |
| 规则加载 + 单次 decide（0 / 1k / 10k / 100k 条） | 21 / 26 / 89 / 725 ms（启动基线 21ms） |
| decide 延迟（debug，200 采样） | 1k p50 282µs / p95 336µs；10k 2.88ms / 3.18ms；100k 28.3ms / 29.0ms |
| AdBlock 内置名单加载 + 单次判定 | 19 ms（10 万条列表装载 0.61s） |
| cosmetic 2 万条建索引 | 81 ms（旧实现 O(n²) 会卡死） |
| 100 并发 HTTP 经 mixed | 297 ms 总耗时，p50 2.8 ms，p95 17.5 ms，FD 14→14 |
| DNS 冷 / 热 | 39 ms / 17 ms，缓存一致性 same |
| SIGINT 退出 | 进程退出 ok，端口释放 yes |

仍未做（已写入 docs/audit-runtime.md §7「仍未修」）：`RuleEngine.decide` 仍是 O(规则数)，
10 万规则下单次判定 28 ms；POL-02（后缀反转标签 Trie）需要重排「最小下标优先」的裁决顺序，
属结构性改动，本轮不做。真实家用配置通常 < 2k 条，该档 p50 282µs 不构成瓶颈。

## 6. 稳定性（scripts/stress.sh）

```
3 轮 × 500 并发短连接 + 随机中断：FD 均 14→14（1.4–3.4s 内回落），RSS 28.7 / 31.4 / 36.0 MB，每轮 SIGINT 10s 内退出
端口冲突第二实例：退出码 1，文案含 "already in use"
上游不可达：HTTP 返回 000/502，进程存活
TLS 失败（CONNECT 到已关闭端口）：返回错误，FD 未累积（15→14）
汇总：PASS=22 FAIL=0
```

代码层面（本仓 `Sources/` 非测试代码）：
- `fatalError` / `try!` / `as!`：**NONE**（本轮新增代码同样为零）。
- 上游连接表在 `stop()` 统一关闭；`BytePump` 用 `withTaskCancellationHandler` 保证取消路径关流。
- `terminationStatus` 只在进程真正退出后读取（未退出不读，避免误判成功）。
- NAS 挂载前校验 share 名不越出挂载根；`mount_smbfs` 密码仍会短暂出现在自身 argv（系统限制，已记录）。
- 日志：`Redactor` 预编译正则 + 关键字预筛；日志环形缓冲，不会无限涨。
- UI：流事件 16ms 批量 flush，抓包列表有硬上限与淘汰。

## 7. 行为变更（升级前必读）

1. **ABP URL 锚定规则改为 path-precise**（`Sources/LeapinPolicy/AdBlock/`）
   - 旧：`|https://tracker.test/pixel` 在解析时被降级成「整域拦截」，任何 `tracker.test` 请求都被拦；`$domain=` 作用域被忽略。
   - 新：保留 host + pathPrefix，只有请求 path 命中前缀才拦；`$domain=` / `~domain=` 按 scope 逐条校验。
   - 原因：旧行为会连带拦掉同域 CDN 的正常资源（过拦），且局部规则变成全局规则。
   - 影响：调用方不传 path 时拦截强度下降。已核对调用点——明文 HTTP（`ProxyServer.swift:422` `path: request.target`）、
     MITM（`MITMHandler.swift:178` `path: target.path`）均传了 path；CONNECT / SOCKS5 / DNS 只有 host，语义正确；
     去广告页「拦截测试」是按域名判定（UI 已注明「仅按域名判定，不看路径」）。
2. **导入不再静默丢字段**：无法识别的协议/区块/字段进入 `ImportReport`，导入后 toast 可打开「导入报告」查看逐条诊断并复制。
3. **未知出站协议保留 `rawType`**（vmess/vless/hysteria/hysteria2/tuic/wireguard/snell/unsupported），导出时原样写回。
4. **导出新增 hosts / ABP / Clash rule-set**：只导出策略解析为 REJECT 的规则，DIRECT/PROXY 不会被写成拦截（ExportFormatTests 守着）。

## 8. 入口与交互（v1.1）

- 命令面板 `⌘K`：20+ 项（页签、动作、导出全部 6 种格式、订阅导入），模糊搜索 + `↑/↓/↩/esc`，快捷键提示。
- 键盘：`⌘1…⌘0` 直达 10 个页签、`⌘F` 聚焦当前页搜索、`⌘⇧P` 启停代理、`⌘⇧Y` 系统代理、`⌘O` 导入、`⌘⇧E` 导出。
- 配置页新增「粘贴订阅链接」：直接从剪贴板读取 http(s) 订阅并下载导入（20s 超时、只接受 http/https、失败给出可读原因），导入后同样出报告。
- 配置切换有 loading 态与成功/失败 toast；设置页在配置被外部切换时提示「未保存的修改仍保留」。
- 隐私页审计改为 600ms 合并窗口重算（不再每条 flow 全量重算），健康分阈值统一（80/55），等级与颜色不再错位。
- 抓包页工具栏拆分为「搜索 + 状态筛选」两行（1040 宽窗口不裁切）；chips 单行不换行。
- 导入报告 sheet（580pt）：三态标题、格式/出站/策略组/规则/跳过计数、逐条诊断（kind 徽标 + 行号 + item）、复制报告。

## 9. 明确**未**做端到端验证的部分

| 项目 | 状态 | 原因 / 已有覆盖 |
| --- | --- | --- |
| HTTPS MITM 抓包 + 安装 CA | 未做真机点击验证（CA 生成/叶证书签发/TLS 终结/HAR 由 69 个 Net 用例覆盖） | 需要用户手动把 CA 加入「系统」钥匙串并设为始终信任 |
| SSH 真实远程登录 | 只做了 `ssh -V`、错误连接、askpass 清理测试 | 本机无可用远程 sshd |
| NAS 真实挂载 | 只做纯逻辑测试 | 无真实 SMB 设备 |
| 多设备/局域网共享 (allowLAN) | 未验证 | 需要第二台设备 |
| 长时间稳定性（数小时/大流量） | 部分验证 | 3×500 并发 + 随机中断通过（见 §6），但不等于数小时真实使用 |
| 分流命中真实 App（PROCESS-NAME） | 部分验证 | `leapin rules` 验证域名→策略链路；进程名需真实进程流量 |

## 10. 界面

| 检查 | 结果 |
| --- | --- |
| `swift build --product LeapinApp` | 0 error |
| 逐页截图（10 页） | 全部渲染正常：总览 / 分流规则 / 去广告 / 抓包 / SSH / NAS / 智能学习 / 隐私 / 配置 / 设置 |
| 浅色 / 深色 | 两套配色均检查（深色通过 `LEAPIN_APPEARANCE=dark` 启动验证，标题栏同步） |
| 视觉回归修复 | 主按钮渐变遮字、端口千分位、NAS 输入框图标重叠、抓包双栏无间隔、规则页计数器挤压、抓包工具栏挤爆（拆两行） |
| 控件状态 | macOS 27 下无标签 `.switch` 恒定渲染为关闭态 → 自绘 `LPSwitch` |
| 命令面板 | `⌘K` 20 项、分组、快捷键、`↑/↓/↩/esc` 提示、选中高亮均正常 |
| 深链 | `open 'leapin://section/rules'` 唤醒并切页 |

## 11. 复现

```bash
swift build --build-tests
swift test                 # 122 个用例
./scripts/build-app.sh     # 打 App
./scripts/smoke.sh         # 端到端代理 7 项
./scripts/bench.sh         # 性能基线（独立 .build-bench 与端口）
./scripts/stress.sh        # 3×500 并发 + 端口冲突 + 上游不可达 + TLS 失败
open dist/Leapin.app
```