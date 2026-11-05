# TouchFlow 验收记录（v1，macOS 27.3 / arm64）

本文件只记录**真实跑过**的命令与结果，以及明确未验证的部分。所有结论都可用下方命令复现。

## 1. 构建

```
swift build                 # Build complete
swift build --build-tests   # Build complete
./scripts/build-app.sh      # → dist/TouchFlow.app（ad-hoc 签名）
```

产物：`dist/TouchFlow.app/Contents/MacOS/{TouchFlowApp,tfctl}`、
`Contents/Resources/TouchFlow_TouchFlowRuntime.bundle`（内置广告名单/资源）、`AppIcon.icns`。

## 2. 单元/集成测试

```
swift test
```

| 测试 target | 用例数 | 结果 | 耗时 |
| --- | --- | --- | --- |
| TouchFlowCoreTests | 1 | 0 failures | 0.001s |
| TouchFlowPolicyTests | 14 | 0 failures | 1.9s |
| TouchFlowNetTests | 69 | 0 failures | 9.0s |
| TouchFlowIntegrationsTests | 11 | 0 failures | 0.7s |
| 合计 | **95** | **0 failures** | ~12s |

Net 的 69 个用例是真起 `NWListener` 假服务器 / 真 TLS 握手 / 真代理请求；Policy 含 10 000 条规则规模测试（decide < 5ms）与 100k 过滤规则装载（0.61s，预算 1s）；Integrations 含 Vision OCR 真实识别（生成图片 → 识别出「微信 weixin.qq.com」）。

> 说明：曾在并行跑测试时遇到过 `CaptureTests` 卡住（CA 断言 + 进程不退出）。根因是**残留的 `tfctl run` 进程占用端口/文件**，不是代码缺陷；清理进程后 `swift test` 稳定通过（连续多次）。

## 3. 端到端代理（真实网络）

`scripts/smoke.sh` 会启动 `tfctl run`、等待 7890 就绪，然后逐项检查：

```
PASS  http proxy (plain)      # curl -x http://127.0.0.1:7890 http://example.com/ → 200
PASS  http proxy (CONNECT)    # https://example.com/ 经 CONNECT → 200
PASS  socks5h proxy           # --socks5-hostname 127.0.0.1:7890 → 200
PASS  dedicated socks port    # --socks5-hostname 127.0.0.1:7892 → 200
PASS  rule explain            # tfctl rules example.com → 命中 MATCH,PROXY + trace
PASS  adblock verdict         # tfctl adblock doubleclick.net → 拦截 ||doubleclick.net^
PASS  dns resolve             # tfctl dns example.com → 真实 A 记录
```

结果：**7/7 通过**。

补充实测：

- 广告拦截经代理闭环：`curl -x http://127.0.0.1:7890 http://doubleclick.net/` → **403**（来自 `blocker`），
  `tfctl adblock doubleclick.net` → 规则数 103、命中 `||doubleclick.net^`。
- 内置名单自动落盘：首次启动复制到 `~/Library/Application Support/TouchFlow/lists/touchflow-ads.txt`
  （SwiftPM 资源包实际路径为 `Resources/Resources/blocklists/...`，装载逻辑做了多候选 + 递归兜底）。
- 本地 DNS 监听 **5354**（TCP+UDP，**只绑 127.0.0.1**，避免变成局域网开放解析器；`lsof -iTCP:5354` 可见 `127.0.0.1:5354`）：`dig @127.0.0.1 -p 5354 example.com` 正常返回；
  `dig ... doubleclick.net` 返回 NXDOMAIN（被拦截）。
  原默认 5353 与系统 mDNSResponder 冲突（`bind` 失败、查询超时），已改默认值并对旧配置做加载时迁移。

## 4. 系统代理（真实修改并回滚）

```
tfctl proxy on      # networksetup 写入 HTTP/HTTPS 127.0.0.1:7891、SOCKS 127.0.0.1:7892
scutil --proxy      # HTTPEnable=1 / HTTPPort=7891 / HTTPSPort=7891 / SOCKSPort=7892
curl http://example.com/    # ← 不带 -x，走系统代理 → 200
curl https://example.com/   # → 200
tfctl proxy off     # HTTPEnable=0 / HTTPSEnable=0 / SOCKSEnable=0
tfctl proxy status  # 系统代理：关闭
```

验证完成后系统代理已恢复关闭状态。`SystemProxy` 在写入后会回读 `-getwebproxy` 校验，权限不足会抛
`connectionFailed("... administrator privileges may be required")` 而不是静默成功。

## 5. GUI

`open dist/TouchFlow.app` 后进程存活、窗口正常渲染（截图逐页确认）：
侧栏为 总览 / 分流规则 / 去广告 / 抓包 / SSH / NAS / 智能学习 / 隐私 / 配置 / 设置；
总览显示本地端点（混合 7890、HTTP 7891、SOCKS 7892、DNS 5354）、状态徽标、统计卡、分流解释器、最近连接；
设置页端口/DNS/抓包/MITM/日志表单与已保存配置一致。

## 6. 明确**未**做端到端验证的部分

| 项目 | 状态 | 原因 / 已有覆盖 |
| --- | --- | --- |
| HTTPS MITM 抓包 + 安装 CA | 未做真机点击验证（CA 生成/叶证书签发/TLS 终结/HAR 由 69 个 Net 用例覆盖） | 需要用户手动把 CA 加入“系统”钥匙串并设为始终信任，属于用户授权的系统级操作 |
| SSH 真实远程登录 | 只做了 `ssh -V`、错误连接、askpass 清理测试 | 本机无可用远程 sshd；交互/窗口 resize 为 no-op（pipe 非 pty） |
| NAS 真实挂载 | 只做纯逻辑测试 | 环境无真实 SMB/afp 设备；`mount_smbfs` 密码会短暂出现在自身 argv |
| 多设备/局域网共享 (allowLAN) | 未验证 | 需要第二台设备 |
| 长时间稳定性（数小时/大流量） | 未验证 | 需要真实使用 |
| 分流命中真实 App | 部分验证 | `tfctl rules` 已验证域名→策略链路；进程名（PROCESS-NAME）需真实进程流量 |

## 7. 界面（视觉重构后）

| 检查 | 结果 |
| --- | --- |
| `swift build --product TouchFlowApp` | 0 error |
| 逐页截图（10 页） | 全部渲染正常：总览 / 分流规则 / 去广告 / 抓包 / SSH / NAS / 智能学习 / 隐私 / 配置 / 设置 |
| 浅色 / 深色 | 两套配色均检查（深色通过 `TF_APPEARANCE=dark` 启动验证） |
| 视觉回归修复 | 主按钮渐变遮住文字、端口千分位、NAS 输入框图标重叠、抓包双栏无间隔、规则列表满出血 |
| 控件状态 | macOS 27 下无标签 `.switch` 恒定渲染为关闭态 → 自绘 `TFSwitch`（去广告/总览/设置/顶栏系统代理） |
| 抓包页真实数据 | 经代理请求 plain HTTP 后列表出现 `example.com 200` 与 `doubleclick.net 403 已拦截`，详情页显示请求/响应头 |
| Release 包 | `dist/TouchFlow.app` 8.5MB，启动与页面切换正常 |

界面结构：`Sources/TouchFlowApp/Design/Theme.swift`（令牌/背景/按钮/标题）+ `Views/Shared.swift`（Card/StatTile/Badge/FlowRow）
+ 各页面 View；调试可直接跳页：`defaults write com.touchflow.app startSection -string privacy`。

## 8. 复现

```bash
swift test                 # 95 个用例
./scripts/build-app.sh     # 打 App
./scripts/smoke.sh         # 端到端代理 7 项
open dist/TouchFlow.app
```
