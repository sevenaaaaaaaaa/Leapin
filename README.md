# Leapin

> One leap. No detour.

macOS 网络工作台：总览小组件、六类场景、订阅预检与转换、原生 / Mihomo 内核、规则分流、去广告、抓包、SSH、NAS、Tailscale 家庭资源、公司内网与本地网络书签。

> v1 为 macOS 原生 App（SwiftUI）+ 跨平台核心库（SwiftPM）。iOS 版需要 NetworkExtension 权限，暂未打包。
>
> **v1.8 起由 TouchFlow 更名为 Leapin**；旧数据目录、设备身份与 CA 会自动迁移（见 [docs/BRAND.md](docs/BRAND.md)）。

## 界面

原生 SwiftUI，单窗口 + 菜单栏常驻，浅色/深色自适应。自绘设计系统（`Sources/LeapinApp/Design/Theme.swift`）：
半透明面板 + 细发丝线、墨色阶与朱红强调、等宽数字与网络元数据；侧栏常驻运行状态与端口，
顶栏固定系统代理开关；总览是功能入口与当前配置，实时连接、流量与最近连接放在独立的网络活动页，抓包页保留观测入口。

- **总览**：六类场景、线路与订阅、常用书签和便捷操作；首屏直接进入“分享本地服务”“工具与致谢”“公司内网”，公司小组件可切换配置、打开资源或检查路径；连接明细独立放在网络活动页
- **场景**：综合 / 海外 Agent / 开发 / 娱乐 / 出国 / 私密，可绑定真实配置并持久保存；专用规则由所选配置提供
- **网络活动 / 排障与配置**：流量与连接明细、本地代理与抓包检查、网站 DNS / 直连 GET / 代理 HEAD、日志线索归类、精确域名直连与撤销
- **回家**：从总览绑定一台 Tailscale 设备的 HTTP / HTTPS / SMB 资源，核对设备身份、ping 与服务端口后打开；仅该主机优先直连，不配置出口或子网路由
- **公司内网**：已有任意客户端 / 办公网、系统 VPN、浏览器 SSO、HTTP(S) 或 SOCKS5 专用代理五种接入方式；多公司保存、单公司启用、资源打开与分层检查、团队 JSON 模板预览导入与导出
- **书签**：浏览器导出 HTML / Chromium JSON → 数量与文件夹预览 → 去重合并 → 撤销本次导入；不执行 HTML 或读取浏览器账号
- **分流规则**：规则列表 + 策略组/出站/规则集侧栏，支持搜索与右键删除
- **去广告**：规则统计、引擎开关、命中测试、过滤列表与白名单
- **抓包**：请求列表 / 详情双栏（明文 HTTP 与命中拦截的请求都会记录）、HTTPS 解密开关、HAR 导出；工具栏「观测」打开实时指标 / 流量 / 最近连接 / 解释器
- **SSH**：深色终端面板、密码经 askpass 传入、可选记住密码
- **NAS**：Bonjour 发现 + 手动主机、SMB 挂载与会话内挂载说明
- **智能学习**：粘贴 App 列表或拖入截图 → OCR → 建议规则 → 一键写入
- **隐私**：健康度评分环 + 加固清单 + 跟踪器发现
- **线路与订阅**：粘贴订阅、配置文本或导入文件 → 兼容性报告 → 原生 / Mihomo 预检 → 启用与失败恢复；Mihomo 策略选择、日志与实际代理路径 HEAD 测试
- **分享本地服务**：本机端口 → 访问范围 / 邮箱 → 有效期 → 只读预览 → 显式建立 cloudflared Quick Tunnel；可停止与到期清理，不自动降级成公开访问
- **独立 HTTPS 调试**：mitmdump → Mihomo HTTP 入口；限定域名，目标 App 手动配置代理与调试 CA，可指定上游 CA，保留 TLS 校验；只展示不含正文 / 路径 / 参数 / 认证头的请求元数据
- **工具与致谢**：内置 Mihomo / mitmproxy / cloudflared 目录，发现版本、选择本机可执行文件、跳转原项目作者 / 文档 / 许可证；不捆绑下载或自动更新第三方程序
- **设置**：端口 / DNS / 抓包 / 日志，保存即应用

## 功能

| 能力 | 说明 |
| --- | --- |
| 本地代理 | `127.0.0.1:7890` 混合端口（HTTP CONNECT + SOCKS5 + 普通 HTTP）；另开 `7891`（仅 HTTP）、`7892`（仅 SOCKS5），端口可在设置中改（等价 Clash/Surge 的 mixed + 独立端口） |
| 本地 DNS | `127.0.0.1:5354`（DoH/DoT/UDP 上游、hosts、正负缓存、可选 Fake-IP、广告域名直接 NXDOMAIN） |
| 规则分流 | Clash / Surge 语法；DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / DOMAIN-REGEX / IP-CIDR / GEOIP / PROCESS-NAME / RULE-SET / MATCH；`no-resolve`、策略组 select/url-test/fallback/load-balance |
| 去广告 | ABP 子集（`||domain^`、`@@` 例外、`$third-party`）+ hosts 语法 + 跟踪器名单 + cosmetic 选择器；内置起步名单，可加订阅 |
| 抓包 | HTTP 明文抓取；可选 HTTPS MITM（本地 CA + HTTP/1.1）；一键导出 HAR，敏感头自动脱敏 |
| SSH | 系统 `ssh -tt` 交互式会话；密码走 `SSH_ASKPASS` 临时脚本，可选存钥匙串 |
| NAS | Bonjour 自动发现（`_smb._tcp` 等）；SMB 挂载与 Finder 打开；凭据只进钥匙串 |
| 智能学习 | 粘贴 App 列表 / 拖入截图 → Vision OCR → 应用识别 → 生成分流规则建议，勾选应用 |
| 隐私 | DoH / DoT / Fake-IP DNS、日志与 HAR 脱敏、Keychain、隐私审计评分、系统代理一键开关 |

## 安装与运行

```bash
# 1) 构建 App 与 CLI（无需任何第三方依赖，不需要开发者账号）
./scripts/build-app.sh

# 2) 启动
open dist/Leapin.app
```

首次使用：

1. 打开 App → 总览 → **连接网络**，启动本地服务并接入 macOS 系统代理。仅支持系统代理的 App 会经过 Leapin。
2. 导入已有订阅：总览 → **导入 / 转换订阅**。先检查内核兼容性，再预检和启用；不会在解析阶段覆盖当前配置。Mihomo 需本机已有可执行文件，也可在“支持哪些协议？”中选择文件。
3. 网站检查和规则调整在 **排障与配置**，连接明细在 **网络活动**。当前助手为有限本地任务助手，未接入大模型。
4. 需要抓 HTTPS 时（仅原生模式）：设置 → 开启 **HTTPS 解密** → 点 **安装 CA** → 在“钥匙串访问”中把 `Leapin Root CA` 加入“系统”并设为“始终信任”（这一步必须手动确认，App 不会静默信任根证书）。
5. 不需要时随时关闭系统代理；App 退出不会留下系统代理设置（可在菜单栏/侧栏关闭）。

总览 Dashboard、六类场景、多内核 CLI、订阅转换、Tailscale 回家、书签与插件的目标方案及当前实现差距见 [产品与交互方案 v2](docs/EXPERIENCE-REDESIGN.md)。文档末尾记录已交付的 Dashboard、多内核、家庭资源、书签导入、结构化排障及外部工具接入，以及仍待实现的能力。

## 命令行 leapin

```bash
BIN=dist/Leapin.app/Contents/MacOS/leapin

$BIN run                       # 前台启动代理
$BIN rules api.spotify.com     # 解释命中哪条规则、走哪个出站
$BIN adblock doubleclick.net   # 检查广告拦截
$BIN dns example.com           # 用当前 DNS 配置解析
$BIN import ./my-clash.yaml    # 导入 Clash / Surge / JSON
$BIN export clash              # 导出 Clash YAML
$BIN proxy on|off|status       # 系统代理
$BIN profiles                  # 列出配置
$BIN device                    # 本机设备 ID / Ed25519 指纹
$BIN sync status               # 配置版本历史与生效版本
$BIN sync serve --lan          # 局域网同步服务（打印配对码与只读面板链接）
$BIN sync pair 192.0.2.9:7901 --code 123456   # 首次配对
$BIN sync pull 192.0.2.9:7901                 # 拉取并收敛
$BIN sync panel                # 只读面板链接与令牌（--rotate 轮换）
```

控制面（默认 `127.0.0.1:7900`，token 在 `$LEAPIN_PROFILE_ROOT/control-token`）：

```bash
TOKEN=$(cat "${LEAPIN_PROFILE_ROOT:-$HOME/Library/Application Support/Leapin}/control-token")
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7900/v1/status
curl -sN -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:7900/v1/events?since=0"
```

细节见 [docs/CONTROL-PLANE.md](docs/CONTROL-PLANE.md) 与 [docs/SYNC.md](docs/SYNC.md)。

## 目录

```
Sources/LeapinCore            模型、协议、YAML 子集、日志脱敏、Keychain
Sources/LeapinPolicy          规则解析/分流/策略组/去广告
Sources/LeapinNet             代理服务器、出站协议、DNS、MITM、HAR
Sources/LeapinIntegrations    SSH、NAS、OCR 学习、系统代理、隐私审计
Sources/LeapinControl         控制面 HTTP/SSE/鉴权/审计
Sources/LeapinSync            设备身份、版本存储、局域网同步、只读面板
Sources/LeapinRuntime         引擎装配、配置存储、导入导出
Sources/LeapinApp             SwiftUI 界面
Sources/leapin                    命令行
docs/ARCHITECTURE.md             契约与设计
```

## 隐私设计

- 代理订阅中的节点凭据随本地方案保存，方案和内核来源文件使用 0600 权限；SSH / NAS 密码只在内存或用户明确选择后写入钥匙串。
- 日志、HAR、抓包详情统一经过 `Redactor`：`Authorization` / `Cookie` / `token=` / `user:pass@` 等全部替换为 `<redacted>`。
- 默认 DNS 走 DoH（`https://1.1.1.1/dns-query`，回退 DoT），可切系统 DNS。
- 默认不开 HTTPS 解密；开启后仅对 `mitmHosts` 匹配的站点签发证书，CA 私钥保存在 `~/Library/Application Support/Leapin/ca`（0600）。
- 可与 Little Snitch / LuLu（进程级出站）、NextDNS（网络级 DoH）配合使用，实际共存需检查路由、DNS 与过滤优先级。

## 已知限制（v1）

- 图形 App 提供本地代理端口与系统代理，尚无图形版一键 TUN / utun 全局接管。终端 TUN 的实现与未验收范围见下文；未走代理的 App 需要单独配置。
- HTTPS MITM 仅 HTTP/1.1，HTTP/2 站点会回落到 1.1 或直连；不做证书固定（pinning）绕过。
- 原生内核不支持 VMess / VLESS / Hysteria / WireGuard；可选择受管 Mihomo 执行兼容配置，具体组合需要内核预检与真实节点测试。原生前门保持 TCP；Mihomo 模式新增回环 SOCKS5 UDP 关联转交，App 需显式使用 SOCKS5。TUN 仅有管理员终端会话与图形端预检导出，尚无图形版签名特权服务。
- Mihomo 保留来源 DNS 策略并在内核内部执行；宿主强制 enable 与空 listen，不额外开放 DNS 监听。SOCKS5 已保留目标域名，DNS trace 查询运行中的内核。此模式不编辑原生来源规则；原生抓包仍不解密 Mihomo HTTPS，可使用独立 mitmproxy 调试通道。不能据此宣称全量 Clash 配置兼容。
- SOCKS5 UDP 数据直接进入本机 Mihomo 中继，不经过原生广告过滤、流量计数或请求抓包；允许 LAN 的入口不提供此关联。TUN 创建网卡、路由及真实公网 UDP 出口尚未真机验收，运行前需处理其他全局接管冲突。
- cloudflared / mitmdump 需要用户安装或选择本机可执行文件。Quick Tunnel 不支持 SSE、没有可用性保证；本版未接入命名 Tunnel、Access 策略部署或 Cloudflare One / WARP 管理。分享公网链路尚未端到端测试。
- 独立调试通道目前按域名限定，目标 App 需手动配置 HTTP 代理与调试 CA；不自动接管 App，也不绕过证书固定。请求详情与原生抓包分开，只保存最多 2 MB 的会话元数据，界面展示最后 100 条。
- 六类场景目前实现配置绑定与切换，未自动生成场景优化规则。Tailscale 入口面向一台已在 tailnet 的设备与一个资源，不代办登录、信任、家庭局域网子网或出口节点配置；真实家庭资源尚未端到端验收。
- 公司入口复用已安装客户端、已配置系统 VPN 和既有访问权限，不实现任意厂商 VPN 协议、PAC、NTLM / Kerberos 或代理账号认证。保存配置不代表已连接或登录；公司策略只覆盖 Leapin TCP 前门，不覆盖独立终端 TUN 或 UDP。公司主机交给操作系统解析，不回退到 Leapin 公共 DNS；实际解析去向仍取决于 VPN / 系统设置。真实公司认证与访问策略尚未端到端验证。
- 书签每批限制 8 MB / 5000 条，保留文件夹标签；不导入浏览器密码、历史、账号或自动绑定网络偏好。
- 排障使用本地状态、实际请求和有界日志分类；没有通用 LLM 自主归因或自动修复，也不判定已发生中间人攻击。第三方插件运行时仍待实现。
- 抓包不做 pcap 级重组，不解析 WebSocket 帧。
- NAS 挂载使用系统 `mount_smb`，需要 macOS 允许的 SMB 共享与凭据。
- 无自签公证：`dist/Leapin.app` 为 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，右键 → 打开。
- 同步是局域网明文 HTTP + 手动 `leapin sync pull`：同一 WiFi 下两台自己的机器可用；没有后台自动同步、没有云端 E2EE、没有 iOS 客户端。
- 只读面板只出元数据（版本/指针/设备），不含规则与凭据；令牌在 URL 里，可随时 `sync panel --rotate`。

## 验证情况

最新全量测试 **293 项、0 失败、1 项性能门禁跳过**，App 构建打包成功；公司资源在隔离配置下完成模板导入、保存、首页检查与本地 HTTP 路径验证。
历史控制面 e2e（22/22）、同步 e2e（36/36）、端到端代理（10/10）、系统代理开关与 GUI 验收记录见 [`docs/VERIFICATION.md`](docs/VERIFICATION.md)，
其中包括**明确未做端到端验证**的项目（真实双机 LAN、MITM 安装 CA、真实 SSH/NAS 设备等）。

```bash
./scripts/smoke.sh          # 真实网络端到端：明文 / CONNECT / SOCKS5 / 独立端口 / 规则 / 去广告 / DNS
./scripts/control-e2e.sh    # 控制面：token / SSE / 策略切换 / 传输中 diff reload / 审计
./scripts/sync-e2e.sh       # 双存储同步：配对 / 收敛 / 离线改动 / override / 只读面板
```

## 仓库卫生

- 提交身份统一为 `Leapin Maintainers <maintainers@leapin.dev>`；历史提交的作者/邮箱已重写，不含个人账号。
- 示例地址使用 TEST-NET（`192.0.2.0/24`）；仓库内不含个人路径、主机名、设备标识或真实邮箱。
- 已忽略 `.build*/`、`dist/`、`.bench/`、`.stress/`、`docs/shots/`、`.env*`、`*.pem`、`*.key`、`*.p12`、`*.log`、`secrets.json`；这些目录可能含本机运行数据，不要用 `git add -f` 强加。

## 开发

```bash
swift build                       # 全部 target
swift test                        # 全部测试
swift build --target LeapinPolicy   # 单模块
./scripts/build-app.sh debug      # debug 版 App
```

契约见 `docs/ARCHITECTURE.md`；各模块能力与降级说明见 `docs/policy.md`、`docs/net.md`、`docs/integrations.md`。


## 外部工具与终端 TUN

图形 App 总览首屏提供“分享本地服务”“工具与致谢”“公司内网”三个直接入口，下方保留“HTTPS 调试通道”；命令面板也可进入。工具页显示依赖状态与作者链接；需要原项目工具时，请通过官方安装方式安装，或选择已安装的可执行文件。

Mihomo 方案的运行控制区可“预检并导出 TUN 启动包”。导出不会切换网络，包含私有权限的来源文件和可审阅的启动脚本；终端会话独立于图形 App，停止请用 Ctrl-C / SIGTERM。

```bash
# 只做配置预检，不需要管理员权限，也不创建网卡
./dist/Leapin.app/Contents/MacOS/leapin tun --source source.yaml --check
# 真实 TUN 会话需要管理员；执行前先审阅来源、退出冲突的全局接管
sudo ./dist/Leapin.app/Contents/MacOS/leapin tun --source source.yaml --kernel /path/to/mihomo
```

该终端会话只管理自己启动的内核与临时配置，不安装常驻 root 服务，不把图形 App 以 root 运行，不写 macOS 系统 DNS。真实路由接管、恢复及与其他 VPN 的共存仍须验收。

## 公司内网快速配置

1. 总览 → 公司内网 → 新增，选择实际接入方式。已有客户端可选择任意已安装的 `.app` 与稳定登录入口；系统 VPN 需主动读取并绑定本机已经配置的服务；浏览器方式保留现有网络方案。
2. 添加常用资源，支持 HTTP / HTTPS、单标签内网主机、IP、SMB 与 SSH 地址。专用代理模式只支持 Web 资源，需要明确代理端口且不接受 URL 账号密码。
3. 保存并使用后，从首页选择公司、打开或检查资源。客户端 / VPN 模式对列出的主机使用系统解析与直连；专用代理模式让目标域名交给代理解析。仅添加精确主机规则，不修改来源配置、不创建整段网段路由。
4. 检查只探测系统解析、服务 TCP 端口与 Web 根地址 HEAD，不携带原链接路径、参数、Cookie 或账号，也不跟随认证跳转。收到响应不等于业务登录成功；请在官方客户端或浏览器完成认证。
5. 团队可导出 JSON 模板再由同事导入；导入先预览，不自动连接。本机客户端路径和 VPN 服务标识不导出，须在各设备上绑定；资源完整 URL 与备注会保留，分享前自行审阅。公司文件和导出文件权限为 0600。暂停 / 移除只撤销本地规则，不替用户断开官方 VPN。

专用代理资源通过浏览器打开前会核对 Leapin 系统代理与已知绕过项；自带代理设置的浏览器或其他 App 仍须核对自身设置。多个公司可以保存，但同一时刻只启用一个公司的资源策略。
