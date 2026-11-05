# TouchFlow 验收记录（v1.2，macOS 27.3 / arm64）

本文件只记录**真实跑过**的命令与结果，以及明确未验证的部分。所有结论都可用下方命令复现。
v1.2 只动视觉与交互（App 层 + 少量共享控件），网络/策略/Runtime 行为未变；第 0 节记录本轮视觉验证。

## 0. 视觉重构验证（v1.2）

- 构建：`swift build --scratch-path .build-app` 与 `./scripts/build-app.sh debug` 均成功，零 error / warning。
- 测试：`swift test --scratch-path .build-app` 全部 suite passed（Core 1 / Policy 41 / Net 69 / Integrations 11）。
- 端到端：`./scripts/smoke.sh` → **pass=7 fail=0**。
- 截图核对（1040×752 与 900×700 两档，浅色 + 深色）：总览 / 分流规则 / 抓包 / 去广告 / SSH / NAS / 智能学习 / 隐私 / 配置 / 设置十页逐页目视；
  取证目录 `/tmp/tffinal2/`（2026-11-05 最新一轮：10 页浅色 + 深色 + 900 宽三套）。
- 本轮修掉的可见缺陷：搜索框整框红描边 → 底部下划线；深色幽灵按钮白药丸（NSColor dynamic provider 在 ButtonStyle 内解析成浅色 → 改 `Color.primary` 语义色）；
  策略色滥用（绿/紫/红同时出现）→ 墨阶；隐私页 0/0/0 给 100 分 → 无样本态；抓包 900 宽 1:1 分栏 → 内容宽 <820 只留列表；总览首屏全 0 → 1 主 4 从 + 最近连接上移 + 双向流量地震仪；导航平铺十页 → 五组按域分组（工作区/代理/观测/工具/系统）；mono 字号 9/9.5/10/11.5 碎档 → 10 / 12 两档。
- 未验证：真机 120Hz 下动画逐帧（只能目视）、VoiceOver 逐页完整走查（只验证了控件标签与 reduce-motion）。

## 1. 构建

```
swift build                 # Build complete
swift build --build-tests   # Build complete
./scripts/build-app.sh      # → dist/TouchFlow.app（ad-hoc 签名）
```

产物：`dist/TouchFlow.app/Contents/MacOS/{TouchFlowApp,tfctl}`、
`Contents/Resources/TouchFlow_TouchFlowRuntime.bundle`（内置广告名单/资源）、`AppIcon.icns`。
零 error、零依赖（无 SPM 第三方包，符合本机无 github.com 的约束）。

## 2. 单元/集成测试

```
swift test
```

| 测试 target | 用例数 | 结果 | 耗时 |
| --- | --- | --- | --- |
| TouchFlowCoreTests | 1 | 0 failures | 0.001s |
| TouchFlowPolicyTests | 41 | 0 failures | 2.0s |
| TouchFlowNetTests | 69 | 0 failures | 8.8s |
| TouchFlowIntegrationsTests | 11 | 0 failures | 0.8s |
| 合计 | **122** | **0 failures** | ~12s |

新增覆盖（v1.1）：
- `FormatTests`（20 条）：Clash / Surge / 订阅 / rule-set 往返等价、未知协议保留 `rawType`、`$domain` 作用域、诊断字段。
- `AdBlockCosmeticTests`（2 条）：2 万条 cosmetic 规则建索引线性时间；后缀链匹配与例外优先。
- `ExportFormatTests`（5 条）：hosts / ABP / rule-set 导出**只搬 REJECT**（DIRECT 不得被洗成拦截）、不认识的后缀不写成误拦、hosts 每行两字段。

Net 的 69 个用例是真起 `NWListener` 假服务器 / 真 TLS 握手 / 真代理请求；Policy 含 10 000 条规则规模测试与 100k 过滤规则装载（0.61s，预算 1s）；Integrations 含 Vision OCR 真实识别。

> 说明：并行跑测试时若残留 `tfctl run` 占用端口/文件，`CaptureTests` 会卡住（CA 断言 + 进程不退出）。清理进程后稳定通过；`scripts/smoke.sh` 现在会因端口占用直接报 `is already in use` 而不是挂起。

## 3. 端到端代理（真实网络）

`scripts/smoke.sh` 启动 `tfctl run`、等待 7890 就绪后逐项检查：

```
PASS  http proxy (plain)      # curl -x http://127.0.0.1:7890 http://example.com/ → 200
PASS  http proxy (CONNECT)    # https://example.com/ 经 CONNECT → 200
PASS  socks5h proxy           # --socks5-hostname 127.0.0.1:7890 → 200
PASS  dedicated socks port    # --socks5-hostname 127.0.0.1:7892 → 200
PASS  rule explain            # tfctl rules example.com → 命中 MATCH,PROXY + trace
PASS  adblock verdict         # tfctl adblock doubleclick.net → 拦截 ||doubleclick.net^
PASS  dns resolve             # tfctl dns example.com → 真实 A 记录
```

结果：**7/7 通过**（v1.1 复跑同样 7/7）。

补充实测：
- 广告拦截经代理闭环：`curl -x http://127.0.0.1:7890 http://doubleclick.net/` → **403**（来自 `blocker`）。
- 内置名单自动落盘：`~/Library/Application Support/TouchFlow/lists/touchflow-ads.txt`（多候选路径 + 递归兜底）。
- 本地 DNS 监听 **5354**（TCP+UDP，只绑 127.0.0.1）；`dig @127.0.0.1 -p 5354 example.com` 正常，`doubleclick.net` 返回 NXDOMAIN。
- 端口冲突时第二个实例退出码 1 且报 `proxy port ... is already in use`（不再静默绑定失败后假装在跑）。

## 4. 系统代理（真实修改并回滚）

```
tfctl proxy on      # networksetup 写入 HTTP/HTTPS、SOCKS
scutil --proxy      # HTTPEnable=1 / SOCKSPort=7892
tfctl proxy off     # 全部归零
```

v1.1 变更：`stop()` 与 App 退出时**先回滚系统代理**再关监听（此前只能手动关）；
系统代理指向 `proxy.listeningPort`（多端口冲突时实际生效的那个），`enable` 写入失败会 `try? disable()` 回滚。

## 5. 性能（scripts/bench.sh，release tfctl）

环境：Apple silicon Mac/ macOS 27.3 / arm64，数字为本机实测（3 次取最小）。

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

1. **ABP URL 锚定规则改为 path-precise**（`Sources/TouchFlowPolicy/AdBlock/`）
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
| 分流命中真实 App（PROCESS-NAME） | 部分验证 | `tfctl rules` 验证域名→策略链路；进程名需真实进程流量 |

## 10. 界面

| 检查 | 结果 |
| --- | --- |
| `swift build --product TouchFlowApp` | 0 error |
| 逐页截图（10 页） | 全部渲染正常：总览 / 分流规则 / 去广告 / 抓包 / SSH / NAS / 智能学习 / 隐私 / 配置 / 设置 |
| 浅色 / 深色 | 两套配色均检查（深色通过 `TF_APPEARANCE=dark` 启动验证，标题栏同步） |
| 视觉回归修复 | 主按钮渐变遮字、端口千分位、NAS 输入框图标重叠、抓包双栏无间隔、规则页计数器挤压、抓包工具栏挤爆（拆两行） |
| 控件状态 | macOS 27 下无标签 `.switch` 恒定渲染为关闭态 → 自绘 `TFSwitch` |
| 命令面板 | `⌘K` 20 项、分组、快捷键、`↑/↓/↩/esc` 提示、选中高亮均正常 |
| 深链 | `open 'touchflow://section/rules'` 唤醒并切页 |

## 11. 复现

```bash
swift build --build-tests
swift test                 # 122 个用例
./scripts/build-app.sh     # 打 App
./scripts/smoke.sh         # 端到端代理 7 项
./scripts/bench.sh         # 性能基线（独立 .build-bench 与端口）
./scripts/stress.sh        # 3×500 并发 + 端口冲突 + 上游不可达 + TLS 失败
open dist/TouchFlow.app
```
