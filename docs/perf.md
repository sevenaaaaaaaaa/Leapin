# Leapin 性能基准（P4）

- 机器：Apple M2 Max / macOS 27.3 / Swift 6.4.2 (swiftlang-6.4.2.1.9)，arm64
- 采集时间：2026-11-05
- 脚本：`scripts/bench.sh`（基准）、`scripts/stress.sh`（稳定性压力）
- 隔离：两者都用独立 scratch（`.build-bench`）与独立端口，不与主窗口的 `.build` 抢 lock：
  - bench：mixed 17890 / http 17891 / socks 17892 / origin 18080 / DNS 15354(独立实例 17899)
  - stress：mixed 17990 / origin 18081

## 复跑命令

```bash
# 首次（含 release 构建 leapin，约 1-2 分钟）
bash scripts/bench.sh
bash scripts/stress.sh

# 已构建过、只想重测数字
LEAPIN_BENCH_SKIP_BUILD=1 bash scripts/bench.sh
LEAPIN_BENCH_SKIP_BUILD=1 bash scripts/stress.sh
```

原始数据落在 `.bench/`（profiles/ timings.txt proxy.log origin.log）、`.build-bench/`（构建产物）。
脚本用 `awk` 生成 Surge 文本 profile（`[General]` + `[Rule]`），因此测的是真实解析→预编译→匹配链路，不是 mock。

## 1. 规则引擎（RuleEngine）

`leapin run --profile <n 条规则>` 从进程启动到 mixed 端口就绪的 wall clock，3 次取最小：

| 规则数 | 总耗时 ms | 启动基线 ms | 净增 ms/万条 |
| --- | --- | --- | --- |
| 0 | 17 | 17 | - |
| 1 000 | 25 | 17 | 80 |
| 10 000 | 88 | 17 | 71 |
| 100 000 | 722 | 17 | 70 |

净增列包含 profile 解析 + RuleEngine 预编译（`prepare`/CIDR/正则）+ 一次 decide，约 7 µs/条。

### 单次 decide 延迟（micro-probe，debug 构建，200 次采样）

| 规则数 | 命中 p50 | 命中 p95 | 未命中 p50 | 未命中 p95 |
| --- | --- | --- | --- | --- |
| 1 000 | 282.5 µs | 336.0 µs | 298.4 µs | 351.3 µs |
| 10 000 | 2 875.1 µs | 3 182.5 µs | 2 911.7 µs | 3 223.8 µs |
| 100 000 | 28 264.6 µs | 28 995.7 µs | 28 499.3 µs | 29 198.6 µs |

结论：`decide` 仍是**严格 O(规则数)**（≈2.8 µs/条，debug；release 约快 2-4 倍但仍线性）。
10 万条规则时单次连接判定 28 ms，直接跑在 Swift 并发协作线程池上，会同时拖慢所有隧道。
本轮 P4 对这条路径只做了 `explain` 的 trace 字符串消除（不再为每条规则拼字符串），**未建索引**。
后续建议：domain/domainSuffix 规则建反转标签 Trie（同 AdBlockEngine 做法），用「命中规则的最小下标」保序；regex/CIDR/process/geoip 规则单独线性扫，两者取最小 index，语义等价。

## 2. AdBlock

| 项 | 数值 |
| --- | --- |
| 内置拦截列表：加载 + 单次判定 | 16 ms |
| 生成 ABP 列表 | 100 000 条 |
| 2 万条 cosmetic 规则：加载 + 建索引 | 81 ms（debug，`AdBlockCosmeticTests`） |
| 2 000 次 cosmetic 查询 | < 1.0 s（同上） |

cosmetic 规则从「`[(domain, selectors)]` 数组 + `firstIndex(where:)` 去重」改为
「`[String: [String]]` 字典 + `Set` 去重 + 后缀链查找」，构建由 O(n²) 降为 O(n)：
20 万次比较级别的 2 万条规则场景，旧实现实测会卡死（>60 s），新实现 81 ms。

## 3. 并发短连接（100 并发 HTTP 经 mixed 端口）

| 指标 | 数值 |
| --- | --- |
| 100 请求总耗时 | 329 ms |
| p50 | 2.98 ms |
| p95 | 10.52 ms |
| FD（前/后） | 14 / 14 |

## 4. DNS

| 指标 | 数值 |
| --- | --- |
| 首次查询（未命中缓存） | 37 ms |
| 缓存命中 | 16 ms |
| 两次查询一致性 | same |

注：本机 DNS 上游偶发不可达，脚本对「空答案」单独标注 `no-answer(upstream?)`，不再误报 differs。

## 5. 稳定性压力（`scripts/stress.sh`）

3 轮 × 500 并发随机中断（`--max-time 0.05~0.80s`，故意制造半开连接），每轮之后检查进程存活、FD 收敛、RSS，再 SIGINT 停止：

| 轮次 | 总耗时 | FD 前→后（收敛耗时） | RSS |
| --- | --- | --- | --- |
| 1 | 2 856 ms | 14 → 14（1 400 ms） | 29 696 KB |
| 2 | 2 237 ms | 14 → 14（1 600 ms） | 32 400 KB |
| 3 | 2 276 ms | 14 → 14（2 200 ms） | 33 568 KB |

断言项（22 项全 PASS，FAIL=0）：

1. 每轮 500 并发后进程存活、FD 回落到 before+20 以内、SIGINT 后 10 s 内退出、端口释放。
2. 端口冲突：同端口起第二个实例必须非 0 退出，日志含 `already in use`。
3. 上游不可达（`[Proxy] Dead = http, 127.0.0.1, 9` + `FINAL,Dead`）：返回 000/502 且进程存活。
4. TLS 失败（`curl https://127.0.0.1:1`）：非 0 退出且失败连接不累积 FD。
5. 结束无残留 `leapin` 进程、端口已释放。

### 稳定性修复对应项

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| `stop()` 不回滚系统代理 → 停代理即断网 | `LeapinEngine.stop()` 先 `rollbackSystemProxyIfNeeded()`，失败保留 `systemProxyActive` 供重试 | 手动 + build |
| 系统代理端口用 `general.httpPort`（可能未监听） | 改用 `proxy.listeningPort`（mixed），并校验 1...65535 | 手动 |
| `SystemProxy.enable` 半开配置 | 6 次写 + 回读包进 do/catch，失败 `try? disable()` 再 rethrow | 代码 + build |
| DNS 端口冲突静默成功 | `DNSServer.start()` 用 ListenerGate 等 `.ready`，失败抛 `DNS port N is already in use`；两 listener 都 cancel | bench / stress 端口冲突项 |
| DNS 起不来拖垮整个代理 | Engine 里 catch 后继续（dnsServer = nil + warn） | stress 端口冲突项 |
| `stop()` 后上游 socket/Task 卡 300 s | `clientUpstreams` 表 + `stop()` 关闭全部上游 | 代码 + stress FD |
| `BytePump` 取消后仍等空闲超时 | `withTaskCancellationHandler` onCancel 关闭两端 | 代码 + stress |
| `CommandRunner` 对运行中 Process 读 `terminationStatus` | 超时未退出时用 `-1` 并记日志，不再取值 | 代码 + build |
| `NASMounter` `share=".."` 逃逸到家目录 | 拒绝 `.`/`..`/`/`，并校验 standardized 父目录 | 代码 + build |
| 日志每行 5 次正则编译 | `Redactor` 预编译 + 关键字预筛 | 代码 + build |
| 日志/抓包数组 `removeFirst` O(n) | `LPLog` 环形缓冲；Engine `trim` 滞后裁剪 | 代码 + build |
| 每事件 2 个 `Task { @MainActor }` | EngineSink 16 ms / 批量 flush（上限 4096） | 代码 + build |

## 6. 已知未修（下一轮）

1. `RuleEngine.decide` 线性扫描（见第 1 节）——10 万规则 28 ms，建议 Trie 索引。
2. `DNSResolver.respond(to:)` 不查缓存、不单飞，DNS 查询直打上游（`resolve` 才走缓存）。
3. `HTTPMessage.HTTPHeaders` 已索引化（`lowered` 镜像数组），但 `HTTPRequestHead.serialized()` 等仍在每次转发时重建头字符串。
4. `MITMHandler` 每条客户端请求都新建上游连接，keep-alive 场景未复用。
5. `CertificateAuthority.identity(for:)` 仍持锁跑 openssl（已有 cache，但首个 host 串行）。
6. `ProfileStore.list()` 在锁内同步读盘 + 逐个 `JSONDecoder`。
