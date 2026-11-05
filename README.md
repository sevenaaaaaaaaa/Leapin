# TouchFlow

融合 Surge / Clash 能力的 macOS 网络工具：规则分流、去广告、抓包、SSH、NAS 快速挂载、从 App 列表或截图学习分流规则，并把隐私保护做进默认行为。

> v1 为 macOS 原生 App（SwiftUI）+ 跨平台核心库（SwiftPM）。iOS 版需要 NetworkExtension 权限，暂未打包。

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
open dist/TouchFlow.app
```

首次使用：

1. 打开 App → 总览 → **启动**。
2. 打开 **系统代理**（自动执行 `networksetup` 设置 HTTP/HTTPS/SOCKS 代理）。
3. 需要抓 HTTPS 时：设置 → 开启 **HTTPS 解密** → 总览点 **安装 CA** → 在“钥匙串访问”中把 `TouchFlow CA` 加入“系统”并设为“始终信任”（这一步必须手动确认，App 不会静默信任根证书）。
4. 不需要时随时关闭系统代理；App 退出不会留下系统代理设置（可在总览/菜单栏关闭）。

## 命令行 tfctl

```bash
BIN=dist/TouchFlow.app/Contents/MacOS/tfctl

$BIN run                       # 前台启动代理
$BIN rules api.spotify.com     # 解释命中哪条规则、走哪个出站
$BIN adblock doubleclick.net   # 检查广告拦截
$BIN dns example.com           # 用当前 DNS 配置解析
$BIN import ./my-clash.yaml    # 导入 Clash / Surge / JSON
$BIN export clash              # 导出 Clash YAML
$BIN proxy on|off|status       # 系统代理
$BIN profiles                  # 列出配置
```

## 目录

```
Sources/TouchFlowCore            模型、协议、YAML 子集、日志脱敏、Keychain
Sources/TouchFlowPolicy          规则解析/分流/策略组/去广告
Sources/TouchFlowNet             代理服务器、出站协议、DNS、MITM、HAR
Sources/TouchFlowIntegrations    SSH、NAS、OCR 学习、系统代理、隐私审计
Sources/TouchFlowRuntime         引擎装配、配置存储、导入导出
Sources/TouchFlowApp             SwiftUI 界面
Sources/tfctl                    命令行
docs/ARCHITECTURE.md             契约与设计
```

## 隐私设计

- 配置文件不保存任何密码；SSH / NAS 密码只在内存或用户明确选择后写入钥匙串。
- 日志、HAR、抓包详情统一经过 `Redactor`：`Authorization` / `Cookie` / `token=` / `user:pass@` 等全部替换为 `<redacted>`。
- 默认 DNS 走 DoH（`https://1.1.1.1/dns-query`，回退 DoT），可切系统 DNS。
- 默认不开 HTTPS 解密；开启后仅对 `mitmHosts` 匹配的站点签发证书，CA 私钥保存在 `~/Library/Application Support/TouchFlow/ca`（0600）。
- 可与 Little Snitch / LuLu（进程级出站）、NextDNS（网络级 DoH）叠加使用，互不冲突。

## 已知限制（v1）

- 不做 TUN/utun 全局接管：只提供本地代理端口 + 系统代理，未走代理的 App 需要手动配置或使用 Proxifier 类工具。
- HTTPS MITM 仅 HTTP/1.1，HTTP/2 站点会回落到 1.1 或直连；不做证书固定（pinning）绕过。
- 不支持 VMess / VLESS / Hysteria / WireGuard；支持 DIRECT / HTTP / SOCKS5 / Shadowsocks(AEAD) / Trojan。
- 抓包不做 pcap 级重组，不解析 WebSocket 帧。
- NAS 挂载使用系统 `mount_smb`，需要 macOS 允许的 SMB 共享与凭据。
- 无自签公证：`dist/TouchFlow.app` 为 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，右键 → 打开。

## 验证情况

真实跑过的构建、测试（95 个用例）、端到端代理（7/7）、系统代理开关与 GUI 截图记录见
[`docs/VERIFICATION.md`](docs/VERIFICATION.md)，其中包括**明确未做端到端验证**的项目（MITM 安装 CA、真实 SSH/NAS 设备等）。

```bash
./scripts/smoke.sh    # 真实网络端到端：明文 / CONNECT / SOCKS5 / 独立端口 / 规则 / 去广告 / DNS
```

## 开发

```bash
swift build                       # 全部 target
swift test                        # 全部测试
swift build --target TouchFlowPolicy   # 单模块
./scripts/build-app.sh debug      # debug 版 App
```

契约见 `docs/ARCHITECTURE.md`；各模块能力与降级说明见 `docs/policy.md`、`docs/net.md`、`docs/integrations.md`。
