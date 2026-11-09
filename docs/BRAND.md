# 品牌：LEAPIN · 一跃

> One leap. No detour. —— 一跃即达，不必绕路。

## 1. 名字

- **英文**：`Leapin`（正文）、`LEAPIN`（字标）、`leapin`（代码 / CLI / 域名）。
- **中文**：`一跃`（正式名）；图标与印章用单字 `跃`。
- **读音**：/ˈliːpɪn/，两个音节；"Leap in" 也正好是首次启动的 CTA。
- **为什么**：leap 是动作而不是状态；`in` 给动作一个落点。合起来是“跃进来 / 接入”。`One Leap` 是承诺，不是名字——它是通用短语，做商标显著性弱，所以放在口号位。

## 2. 用法

| 场景 | 写法 |
| --- | --- |
| 字标 | `LEAPIN` |
| 正文 | `Leapin` |
| 代码 / CLI / 域名 | `leapin` |
| 中文名 | `一跃`（正式）/ `跃`（图标、短称） |
| 口号 | `One leap. No detour.` / `一跃即达，不必绕路。` |

禁写：`LeapIn`、`Leap In`、`Leapin'`、`leapIn`。统一成上面四种写法，避免同一个品牌出现四种拼法。

## 3. 视觉与动效

- **主图形**：一个朱红点从 A 跃到 B，中间**不画轨迹**；留白就是“瞬间”。
- **辅助图形**：一条绕远的弧线绷直成弦（把绕行拉直），用于规则链、重载、直连这类“变直”的状态。
- **色彩**：纸 `#EDE7DB` / 墨 `#0A0A0B` / 朱红 `#C63A12`（浅色）、`#FF7A4D`（深色）。不做蓝紫渐变、光晕、粒子。
- **动效**：A 点消失 → B 点出现（同帧，不做飞行轨迹）；弧线变弦只用于状态切换，不做装饰性 hover。

## 4. 名称占用（2026-11-10 查）

- npm `leapin` 未占用。
- GitHub 用户名 `@leapin` 已被个人占用；组织句柄可用 `leapin-app`，个人账号下的仓库名 `Leapin` 可用。
- `leapin.com` / `.app` / `.io` 已被使用；`leapin.dev` 的 RDAP 返回 404，**很可能可注册，需在注册商确认**。
- 商标未查。Leapin 是常见英文短语（"leap in"），9/42 类的显著性检索要在正式发布前做；中文“一跃”和图形标可以独立撑识别。

## 5. 改名（v1.8，TouchFlow → Leapin）

| 项 | 旧 | 新 |
| --- | --- | --- |
| 包 / 模块 | `TouchFlow*` | `Leapin*`（`LeapinCore` … `LeapinSync`） |
| CLI | `tfctl` | `leapin` |
| App | `TouchFlow.app` | `Leapin.app` |
| Bundle ID | `com.touchflow.app` | `com.leapin.app` |
| 数据目录 | `~/Library/Application Support/TouchFlow` | `…/Leapin`（首次启动复制一次，旧目录保留） |
| 设备身份 | `com.touchflow.device` | `com.leapin.device`（自动迁移，配对不丢） |
| 凭据 | `com.touchflow.credentials` | `com.leapin.credentials`（读取回退旧 service 并写回） |
| URL scheme | `touchflow://` | `leapin://` |
| 环境变量 | `TF_*` | `LEAPIN_*` |

**CA 兼容**：若旧目录存在 `ca/`，随数据目录一起复制并继续沿用（CN 仍是 `TouchFlow Root CA`），避免用户重装证书；全新安装才生成 `Leapin Root CA`。要品牌一致，可删除 `Leapin/ca` 后在设置里重新安装 CA（需要手动信任一次）。本机旧目录没有 `ca/`（从未开启 HTTPS 解密），所以这条只做了代码路径核对。

**未验证**：真实钥匙串里的 SSH / NAS 凭据迁移（本机没有可测的真实凭据）；旧 CA 的延续（本机没有旧 CA）。