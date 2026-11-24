# T-25 · M3 验收报告（模拟器 + 真机步骤）

> 脚本只能验代码层与截图存在。下面写清「模拟器验到了什么、验不了什么、真机上怎么做」。

## 1 模拟器已验（iPhone 17 Pro · iOS 27.0）

| 项 | 结果 |
| --- | --- |
| 首页是「这台手机的网络」，第一屏三块（本机引擎 / 系统使用 / Mac） | 截图 `docs/shots/m3-home.png` |
| 本机引擎自动启动，固定端口 `127.0.0.1:51003` | 首页「地址」行 |
| 自检经本机代理取 example.com | 首页「经本机代理 … 收到 HTTP 200，577 字节」 |
| 「把这台手机的 Wi-Fi 代理指过来」引导（复制地址 + 五步 + 自检 + 回滚） | 截图 `docs/shots/m3-guide.png` |
| 未配对策略页给出「全部直连」与本机自检 | 截图 `docs/shots/m3-policies.png` |
| 未配对诊断页有本机连通性（引擎 / 端口可达 / 自检） | 截图 `docs/shots/m3-diagnostics.png` |
| 未配对连接页有引导入口 | 截图 `docs/shots/m3-connections.png` |
| 系统接管未安装时是说明行，不是开关 | `qa/T-24` C5 |

复现（本机）：

```sh
cd Mobile
xcodebuild -project LeapinMobile.xcodeproj -scheme LeapinMobile -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/m3-dd build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcrun simctl install booted /tmp/m3-dd/Build/Products/Debug-iphonesimulator/Leapin.app
SIMCTL_CHILD_LEAPIN_MOBILE_LOCAL_PROXY=1 xcrun simctl launch booted app.leapin.mobile
```

## 2 模拟器验不了什么（必须真机）

1. **无线局域网里没有「配置代理」这一项**：模拟器跟随宿主网络，没有独立的 Wi-Fi 设置。所以「填 127.0.0.1:51003」这一步只能在真机上做。
2. **系统流量真的经过本机引擎**：模拟器里 `selfCheck` 是自己构造的 URLSession 代理，不等于系统把 Safari 的流量交过来。真机 Safari 打开 example.com 后，连接页应出现该 host。
3. **后台/锁屏时引擎是否存活**：模拟器不模拟 iOS 的后台回收。

## 3 真机步骤（Wi-Fi 代理，不需要付费账号）

1. 用 Xcode 免费账号把 `LeapinMobile` 装到 iPhone（NetworkExtension 装不上，本机代理不受影响）。
2. 打开 App →「状态」→ 确认本机引擎「运行中」、地址 `127.0.0.1:51003`。
3. 点「把这台手机的 Wi-Fi 代理指过来」→ 「复制」。
4. 设置 → 无线局域网 → 当前网络右侧 ⓘ → 拉到底 → 配置代理 → 手动：
   - 服务器：`127.0.0.1`
   - 端口：`51003`
   - 点「存储」。
5. 回到 App → 点它旁边的「自检」→ 应显示「已验证 · 经本机代理 … 收到 HTTP 200」。
6. Safari 打开 example.com → 回 App「连接」页，应看到这条连接（host = example.com，DIRECT）。
7. **回滚**：配置代理改回「关闭」→ 存储；或在 App 里关掉本机引擎。

## 4 已知边界

- 本机代理只监听回环，不接受局域网设备连接（`allowLAN: false`）——这是有意的。
- 本机分流全部 DIRECT：规则与出口来自 Mac 配置，未配对时不假装有规则。
- 系统级接管（NetworkExtension）需要付费开发者账号，M3 明确不做；「系统接管」行在未安装时只说明原因。
