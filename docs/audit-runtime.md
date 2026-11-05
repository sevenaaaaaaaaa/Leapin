# 运行时性能与稳定性审计（audit-runtime）

> 审计对象：TouchFlow（SwiftPM，swift-tools 6.0，Swift 5 language mode，Sources 约 14.4k 行）
> 审计方式：纯静态代码取证 + 现有测试/调用点交叉验证；**未修改任何 .swift、未执行 swift build**（避免与主窗口构建抢锁）。
> 行号基于 2026-11-05 12:19 的工作树。硬约束：不新增 SPM 依赖、不改 Package.swift target 结构、禁止 fatalError / try! / 强制解包（测试除外）。
> 覆盖面：Sources/TouchFlowNet（ProxyServer/BytePump/NetSocket/SOCKS5/HTTPMessage/OutboundDialer/ShadowsocksAEAD/DNSResolver/DNSServer-FakeIPPool/MITMHandler/CertificateAuthority/HARExporter/Bytes/TLS）、Sources/TouchFlowPolicy（RuleEngine/PolicyResolver/AdBlockEngine/GeoIPDatabase/RuleSetLoader）、Sources/TouchFlowRuntime（TouchFlowEngine/ProfileStore）、Sources/TouchFlowIntegrations（SSHSession/CommandRunner/SystemProxy/NASMounter）、Sources/TouchFlowApp（Platform/CaptureView/DashboardView 调用点）。

---

## 1. 现状概览

1. **热路径结构**：每条连接 = ProxyServer.accept 建表 + Task（ProxyServer.swift:176-193）→ 一次同步 router.decide（:286/:377）+ 一次或两次同步 blocker.verdict（:294-295）→ 可选 MITM → BytePump.run 起 3 个子 Task 双向泵（BytePump.swift:30-41）。每个请求还会在 TFLog 里做 5 次即时编译正则（Log.swift:60-66）。
2. **同步阻塞桥接点多**：NWListener 的异步 ready 被 DispatchSemaphore 桥成同步 start()（ProxyServer.swift:110-143、704-741）；CommandRunner 在调用线程 usleep 忙等进程退出（CommandRunner.swift:109-112）；CertificateAuthority.identity 在 NSLock 内同步跑两次 openssl（CertificateAuthority.swift:76-87、196-211）。这三处都能把主线程或共享协作线程卡住数秒到数十秒。
3. **无界增长风险**：DNS 缓存无容量上限（DNSResolver.swift:57-91）；CA identity 缓存与 leaf 目录无清理（CertificateAuthority.swift:26、127-135）；代理连接表、clientTasks 无并发上限（ProxyServer.swift:50-56）；抓包/流事件只在 UI 侧按 2000/1000 截断，且 removeFirst 为 O(n)（TouchFlowEngine.swift:280-288）。
4. **退出/失败清理不完整**：stop() 不回滚系统代理（TouchFlowEngine.swift:161-166）；已建立的上游 socket 不在 stop() 的关闭集合内，隧道 Task 要等 300s 空闲超时（ProxyServer.swift:154-172、:37）；DNS 端口冲突只打日志、start() 仍返回成功（FakeIPPool.swift:137-161）。
5. **正面证据**：全仓仅 1 处受控强转（CertificateAuthority.swift:229-233，前置 CFGetTypeID 校验）；无 fatalError / try! / precondition；AdBlock 域名后缀已用反转标签 Trie（AdBlockEngine.swift:30-53）；CommandRunner 双向并发排空管道（CommandRunner.swift:90-98）；SystemProxy.disable 有回读校验（SystemProxy.swift:68-78）。

---

## 2. 差距清单

优先级口径：P0 = 会导致断网/静默失败/数据错误，必须本轮修；P1 = 高并发或启动/退出路径上可复现的卡顿、泄漏、崩溃面；P2 = 性能优化与健壮性改进。工作量：S ≤ 半天，M ≤ 2 天，L > 2 天。

| ID | 证据（文件:行） | 问题（触发条件） | 具体改法 | 影响面 | 优先级 | 工作量 |
|---|---|---|---|---|---|---|
| RT-01 | Sources/TouchFlowRuntime/TouchFlowEngine.swift:161-166 | 开系统代理后点“停止代理”：stop() 只 teardown 监听，不回滚系统代理。系统代理仍指向已关闭的 7891/7892，浏览器全部连接被拒，表现为“停止代理后全网断”。对照 Sources/TouchFlowApp/Platform.swift:72-77 退出时才有回滚。 | stop() 内先 if systemProxyActive { try? SystemProxy.disable(); systemProxyActive = false }，再 teardown；把回滚做成 stop(reason:) 的 defer 保证异常路径也执行；teardown() 保持纯资源语义。 | TouchFlowEngine、tfctl、Dock 菜单、主窗口 | P0 | S |
| DNS-01 | Sources/TouchFlowNet/DNS/FakeIPPool.swift:120-169 | DNS 端口被占用时：NWListener 绑定失败经 stateUpdateHandler 异步到达（:137-141、:150-154），只 TFLog.error，而 :157-161 无条件 running = true、start() 返回成功；另 :146 tcp listener 构造抛错时已启动的 udp listener 未 cancel，监听器泄漏。 | 复用 ProxyServer 的 StartGate 思路：为 udp/tcp 各建一个 continuation，等 .ready 才置 running = true 并返回；.failed 时 cancel 两个 listener 并抛 TouchFlowError（EADDRINUSE 给可读文案）；tcp 构造失败时先 udp.cancel()。 | DNS 服务、Engine 启动、SettingsView 状态 | P0 | S |
| RT-02 | Sources/TouchFlowApp/Platform.swift:72-77 + Sources/TouchFlowIntegrations/System/SystemProxy.swift:47-66 + Sources/TouchFlowIntegrations/Support/CommandRunner.swift:109-112 | 退出时在主线程同步跑 disable（3 次写 + 3 次读，每次最多 10s 忙等）；networksetup 慢或要授权时窗口“退不掉”，用户强杀后系统代理残留，下次启动 refreshSystemProxyStatus 只显示状态、不修复指向死端口的配置。 | 改为 applicationShouldTerminate 返回 .terminateLater + Task 执行 await SystemProxy.disable()，3s 超时后放行退出；用 UserDefaults 持久化 proxyWasEnabled，启动时若为真而引擎未运行则提示一键回滚。 | 退出体验、系统代理残留 | P1 | M |
| RT-03 | Sources/TouchFlowRuntime/TouchFlowEngine.swift:243-256 + :137-149 + Sources/TouchFlowCore/Models.swift:218-222 | toggleSystemProxy 用 httpPort/socksPort 写入系统代理，但引擎只保证 mixedPort 一定监听（:137-139），httpPort/socksPort 是 best-effort（:140-149）。httpPort == 0 时 SystemProxy.enable 直接抛 invalidConfiguration；socksPort == httpPort 时 socks 指向仅 HTTP 的监听，SOCKS 全部握手失败。 | 系统代理统一写 mixedPort（HTTP 与 SOCKS 同一端口，mixed 两者都支持）；若保留专用端口，enable 前断言对应 listener 存在，不存在则回退 mixedPort 并在 UI 说明；SystemProxy.enable 增加“端口可达”预检。 | 系统代理可用性 | P1 | S |
| NET-01 | Sources/TouchFlowNet/Proxy/ProxyServer.swift:154-172 + :345 + Sources/TouchFlowNet/Proxy/BytePump.swift:30-41 | stop() 只 close clientSockets，OutboundDialer 建立的上游 ByteStream 只存在于 tunnel() 局部，停止后两个 pipe Task 仍阻塞在 read()，直到 300s 空闲超时才退出（:37）：上游 socket/FD、Task、PumpState 各泄漏 300s。 | 在 accept/release 生命周期里登记 clientUpstreams[id]，stop() 一并 close；BytePump.run 加 withTaskCancellationHandler { close(left); close(right) }，让 cancel 立即唤醒读阻塞。 | ProxyServer、BytePump、Engine 停止/重启 | P1 | M |
| NET-02 | Sources/TouchFlowNet/Proxy/BytePump.swift:30-41 + ProxyServer.swift:176-193 | 每连接固定 3 个 Task，其中 1 个每 2s 唤醒轮询；500 连接 ≈ 250 次/秒无谓唤醒。ProxyServer 对连接数、并发 Task 数无任何上限，恶意或异常客户端可把任务数推高到数千。 | idle 检测改为读超时（NetSocket.read(timeout:)）或单一 AsyncStream 事件；ProxyServer 增加 maxConnections（默认 4096）用 AsyncSemaphore 限流，超限回 503 并记一条聚合日志。 | 高并发稳定性、CPU 唤醒 | P1 | M |
| NET-03 | Sources/TouchFlowNet/Support/Bytes.swift:199-202、:205-210、:227-231、:283-292 | pushBack 用 data + buffer 每次前置拷贝整个缓冲；drainBuffer/takeLocked 再拷一次；readExactly(32MB) 时 max(count, 16384) 单次大块读叠加多次整块拷贝，最坏 O(n²) memcpy（32MB body 数百 MB 流量）。 | 用 [UInt8] + 读写游标（ring/deque），消费只移动 head 索引，Data 只在交付边界生成；pushBack 改为 deque 前置插入；probeLine/probeUntil 缓存已扫描位置，避免每块全缓冲重扫。 | 大 body、HTTP 转发、SOCKS 兼容、所有读路径 | P1 | M |
| NET-04 | Sources/TouchFlowNet/Support/HTTPMessage.swift:29-54、:62-68 | first/all/contains/remove 每次遍历 items 且对每项 lowercased()（每条目一次 String 分配）；serialized() 用 String += 拼头，头多时 O(n²)。每请求数十次查找（stripHopByHop、capture、MITM 注入）。 | 存储改为 [(lower: String, name: String, value: String)]，插入时算一次小写；查找用 lower 比较；serialized() 用 [String] 收集后 joined 或 reserveCapacity 预估容量。 | HTTP 转发、MITM、HAR、抓包 | P1 | S |
| NET-05 | Sources/TouchFlowNet/Outbound/ShadowsocksAEAD.swift:193-210、:238-251、:280-308 | 读路径从不解析对端 salt、read 与 write 共用同一 nonce 计数：入站首块 AEAD open 必然失败，抛 “shadowsocks: AEAD open failed”，SS 出站“可写不可读”，连接建立后立刻断。 | 读路径独立 nonce 计数器；首块先读 salt 并用 HKDF 派生读 subkey（与写对称）；增加“客户端→服务端”方向的流式回环单测（现有 ShadowsocksTests 只测同进程 encrypt/decrypt）。 | SS 出站全部流量、稳定性 | P1 | M |
| DNS-02 | Sources/TouchFlowNet/DNS/DNSResolver.swift:252-300 | 本地 DNS 服务 respond(to:) 完全不查 cache、不做 single-flight：每个查询都直打上游（:288-298），即使 resolve() 已有缓存与去重（:150-188、:75-80）。10 个页面 ≈ 数百次重复上游查询，首屏延迟与上游限流风险都放大。 | respond(to:) 先按 name+type 走与 resolve 相同的 cache/in-flight 表；命中直接回包；仅 miss 时才转发并把结果写回缓存；blocked/hosts/fakeIP 仍前置特判（保持现有语义顺序）。 | DNS 服务性能、上游限流、离线可用性 | P1 | M |
| DNS-03 | Sources/TouchFlowNet/DNS/DNSResolver.swift:423-489 | 每个 UDP 上游查询新建 NWConnection + 新建 DispatchQueue(label:) + 2 个 Task 的 task group（:423-489）；DoT 每次新建 NWConnection（:347-374）。高 QPS 下连接与队列创建本身就是主要开销。 | 每个 upstream 复用长驻 UDP socket（或 NWConnection 池 + 请求 id 匹配）；DoT/DoH 各复用一条连接/URLSession；请求串行化到每 upstream 一条 actor 队列。 | DNS QPS、延迟 | P1 | L |
| POL-01 | Sources/TouchFlowPolicy/Rules/RuleEngine.swift:60-71、:73-104、:81-83 | decide() 直接调用 explain()：每连接为每条规则插值 trace 字符串（最多 200 行）+ 每条规则新建一个 Set<String>（:82），即使调用方只要一个决定。10 万规则时每连接数万次分配，是首要热路径瓶颈；explain 的 trace 在 decide 中被整块丢弃。 | 拆出无 trace 的 match(_:) -> RuleMatch，decide() 只调它；trace 用 [String]?（nil 时不生成）或懒回调；visitedSets 提到循环外复用（removeAll(keepingCapacity:)）。trace 文案保持不变以兼容测试/UI。 | RuleEngine 全热路径、tfctl、Dashboard 探测 | P1 | M |
| POL-02 | Sources/TouchFlowPolicy/Rules/RuleEngine.swift:81、:117-119 | domainSuffix 每条规则一次 HostNormalizer.matchesSuffix，全表线性扫描；PLAN-v2 P4 要求的“域名后缀反转标签 Trie”只落在 AdBlock（AdBlockEngine.swift:30-53），规则引擎缺失。 | 为 domainSuffix 建反转标签 Trie（复用 AdBlockEngine.TrieNode），domain 用 Dictionary，domainKeyword 至少用 Aho-Corasick 或多级首字符索引；Trie 命中仍要按原始规则顺序裁决，需在节点上存最小 ruleIndex。 | 规则引擎规模上限（100k） | P1 | L |
| POL-03 | Sources/TouchFlowPolicy/AdBlock/AdBlockEngine.swift:231-237、:58-67 | 构造 cosmetic 映射时每个 selector 用 list.firstIndex(where:) 线性查重，整体 O(n²)；10 万条 cosmetic 规则（##.ad-xxx）时启动卡死。现有 testAdBlockPerformance（Tests/TouchFlowPolicyTests/PolicyTests.swift:315-354）只用域名规则，完全覆盖不到该路径。 | 改为 [String: Set<String>] 或 [String: [String]] + Set 去重；或构建期用 IndexSet。补一条 2 万条 cosmetic 的加载测试（加载 < 2s）。 | 启动时间、cosmetic 过滤 | P1 | S |
| POL-04 | Sources/TouchFlowPolicy/AdBlock/AdBlockEngine.swift:123-140、:199-201 | cosmeticSelectors(for:) 对全部 cosmeticExceptions + cosmeticBlocks 线性扫描，每条再算后缀匹配；blockVerdict 命中阻断时每次都调用它。MITM 注入 CSS 走该路径 → 每个被拦请求 O(全部 cosmetic 规则)。 | 预建 domain → selectors 的反转标签 Trie（blocked 与 exceptions 各一棵），查询 O(labels)；exceptions 用同一 Trie 存“取消集合”，命中后再做差集。 | MITM 注入性能、被拦请求延迟 | P1 | M |
| CORE-01 | Sources/TouchFlowCore/Log.swift:60-66、:28-38 | Redactor.redact 每行日志执行 5 次 replacingOccurrences(options: .regularExpression)，每次即时编译正则（无缓存），再写 osLog + 通知 observer；连接密集时每行几十到几百 µs，且都在调用线程（含协作线程池/MainActor）执行。 | 预编译 [NSRegularExpression] 为 static let；先用廉价 contains（authorization、cookie、password=、token=、://…@）预筛，无候选直接返回；buffer 溢出改环形索引（避免 removeFirst O(n)）。补 redaction 快照测试防行为漂移。 | 全仓日志点、CPU、主线程 | P1 | S |
| CA-01 | Sources/TouchFlowNet/Capture/CertificateAuthority.swift:76-87、:196-211、:251-279 | identity(for:) 在 NSLock 内同步生成叶证书：2 次 openssl Process（每次 rsa:2048 密钥生成），期间所有其他 host 的 MITM 握手排队；run() 先 readDataToEndOfFile(stdout) 再读 stderr 再 waitUntilExit，stderr 写满管道会死锁，且无超时，openssl 挂起将永久占锁。 | 锁外生成 + per-host in-flight Task 去重（cache 命中快路径仍持锁）；run() 用 readabilityHandler 并发排空两个管道，waitUntilExit 外包 10s 超时（超时 terminate + SIGKILL）；错误带 stderr tail。 | MITM 首次握手、并发新 host | P1 | M |
| CA-02 | Sources/TouchFlowNet/Capture/CertificateAuthority.swift:44-46、:243-249、:127-135 | CA 目录与私钥用默认权限创建（未显式 0700/0600，atomic write 继承 umask，通常 0644）；ca-private.pem 同机其他用户可读，p12Password 由该私钥派生（:66-73），等于叶证书私钥也可导出。leaf 每 host 一目录、从不清理，长期使用 inode/磁盘单调增长。 | 目录 attributes: [.posixPermissions: 0o700]，私钥文件写后 setAttributes(0o600)，复用已有目录时也 chmod 修正；leaf 目录加 LRU 上限（如 2000）或启动时清理 30 天未用；identityCache 加容量上限。 | 本机安全、磁盘增长 | P1 | S |
| RT-04 | Sources/TouchFlowRuntime/TouchFlowEngine.swift:272-302、:280-288、:122 | 每条 FlowEvent / CapturedRequest 都 Task { @MainActor … }，EngineSink 再包一层（:297/:300）→ 每事件 2 个 Task 分配 + MainActor 排队；opened/closed 顺序无保证；@Published 每 append 触发全量 UI 刷新；溢出用 removeFirst(n) 每事件 O(n) 搬移；sink.reset() 是空实现（:122），重启后 flows/captures/stats 不清零。 | Sink 改为同步写入环形缓冲（或单个 AsyncStream 消费者 Task 批量 flush，16ms 合并一次 UI 更新）；用 RingBuffer 或头指针裁剪替代 removeFirst；实现 reset()；stats.connections 以“当前活动”而非累加展示。 | 抓包/流量页性能、重启状态 | P1 | M |
| RT-05 | Sources/TouchFlowRuntime/TouchFlowEngine.swift:89-99 + Sources/TouchFlowPolicy/Rules/RuleSetLoader.swift:9-34 + Sources/TouchFlowNet/Proxy/ProxyServer.swift:128 | start() 在 MainActor 上 await 规则集（串行、每个远程源 15s）+ 同步 AdBlockEngine.load（磁盘+解析，10 万条可达秒级）→ 启动期 UI 一直 .starting 且不可交互；ProxyServer.start 还同步 semaphore.wait(5s)，最坏再卡 5s。 | 规则/AdBlock 加载移到非隔离 Task.detached（或 RuleSetLoader 内部 TaskGroup 并行），进度回 MainActor；ProxyServer.start 改 async（withCheckedContinuation 包 listener ready，替代 StartGate）；start 全流程可取消。 | 启动时间、UI 响应 | P1 | M |
| RT-06 | Sources/TouchFlowRuntime/TouchFlowEngine.swift:182-187、:200-215、:319-331 | stop() 后立即 start()：stop() 只 listener.cancel() 不等待真正取消，新监听可能撞 EADDRINUSE（尤其切配置/重启代理时）→ 偶发“启动失败”，主窗口表现为切配置后代理没起来。 | ProxyServer.stop() 改 async 并等待 .cancelled（continuation）或轮询直到 boundPort 清空；Engine 改 await stop(); await start()；对 EADDRINUSE 做一次 100ms 退避重试。 | 切配置/重启、tfctl | P1 | M |
| RT-07 | Sources/TouchFlowNet/Capture/HARExporter.swift:13-62、:256-260 + Sources/TouchFlowApp/Views/CaptureView.swift:254-261 | HAR 导出在 UI 线程同步执行：全量 entries → [[String:Any]] → JSONSerialization(.prettyPrinted,.sortedKeys)；每条 entry 新建 ISO8601DateFormatter（:256-260）；1000 条 × 每 body 1MB 上限时内存峰值 GB 级 + 主线程秒级冻结。 | 导出移 Task.detached；ISO8601DateFormatter 提为 static let；用流式写（FileHandle 逐 entry 序列化）或分块 JSON 组装；CaptureView 加 .disabled + 进度状态；导出前对 body 总量设上限（如 200MB）并提示。 | 抓包导出体验、内存 | P1 | M |
| INT-01 | Sources/TouchFlowIntegrations/Support/CommandRunner.swift:109-112 + Sources/TouchFlowIntegrations/System/SystemProxy.swift:36-66 | CommandRunner 在调用线程 usleep(10_000) 忙等进程退出（默认 10s，NAS 20s）；SystemProxy.enable 一次调用串行 6 次写 + 3 次 status（每次内部再 spawn 3 个 networksetup）→ 最坏 9×10s 全部压在 MainActor（TouchFlowEngine.swift:243-256 同步调用），UI 完全无响应。 | CommandRunner 增加 async API（terminationHandler + continuation），sync 版本只在专用串行队列内部等待；SystemProxy 改 async 并在 Task.detached 执行；enable 合并为一次脚本化调用（或并发三组 set），status 只回读一次。 | 系统代理开关、退出、UI 卡死 | P1 | M |
| INT-02 | Sources/TouchFlowIntegrations/Support/CommandRunner.swift:114-133 | 超时后 terminate → 0.5s → SIGKILL，若再等 3s 仍未退出，:133 读取 process.terminationStatus；对仍在运行的 Process 取该属性，Foundation 会抛 ObjC 异常（Swift 不可捕获）→ 进程崩溃。触发条件：被 SIGSTOP/内核态阻塞/权限挂起的 networksetup、mount_smbfs。 | 只在 !process.isRunning 后读 terminationStatus；否则返回 .timeout 错误（携带 pid 供诊断）；或改用 terminationHandler 记录 status，主线程永不直接读取。 | 崩溃面（罕见但致命） | P1 | S |
| INT-03 | Sources/TouchFlowIntegrations/NAS/NASMounter.swift:121-133 | 挂载点仅把 / 换成 -：share = “..” → 路径解析到 $HOME，mount_smbfs 可能把 SMB 卷覆盖到家目录；未拒绝空串、.、..。 | 校验 share 非空、非 ./..、不含 .. 段；URL(fileURLWithPath:).standardized.path 后断言前缀等于 mountRoot；失败抛可读错误。 | 用户家目录数据安全 | P1 | S |
| INT-04 | Sources/TouchFlowIntegrations/SSH/SSHSession.swift:49-74、:200-210 | teardown 在锁外 terminate 后 usleep 忙等 0.5s（deinit 可能在任意线程/主线程触发）；write 在 actor 内含同步 handle.write(contentsOf:)，stdin 管道满时阻塞整个 actor（后续 disconnect 排队）。 | teardown 用 terminationHandler 或把等待放到专用队列，绝不在 deinit 里忙等；write 改为非隔离方法投递到串行队列并带背压超时。 | SSH 会话、退出卡顿 | P1 | S |
| INT-05 | Sources/TouchFlowIntegrations/SSH/SSHSession.swift:228 + Sources/TouchFlowApp/Views/SSHView.swift:196-219 | 退出/关闭窗口时没有全局“终止所有子进程”的登记表：SSH 仅在 view onDisappear 或 deinit 才 teardown；应用退出时若 View 仍在层级中，ssh 子进程可能以孤儿形式残留（NAS 挂载同理，见 NASMounter.swift:95-99 挂载成功不回滚）。 | 增加 SessionRegistry（actor）登记所有 SSHSession 与 NAS mount，Engine.stop/App 退出时统一 await terminateAll()；NAS mount 失败或退出时尝试 unmount。 | 进程/挂载残留 | P1 | M |
| DNS-04 | Sources/TouchFlowNet/DNS/DNSResolver.swift:57-91、:190-192 | 缓存 [String: DNSCacheEntry] 无容量上限、无后台过期清扫（只在访问时删当前 key）；flushCache() 用裸 Task 异步清（:190-192），返回后缓存可能仍在，测试易竞态。 | 加 LRU 上限（如 4096，NSCache 或手写双向链表）；周期任务（60s）清扫过期；flushCache 改 async 并 await 清理完成。 | 长跑内存、测试稳定性 | P2 | S |
| NET-07 | Sources/TouchFlowNet/Outbound/OutboundDialer.swift:39-52 | openTCP 逐个地址串行拨号，每地址最多 12s 超时：解析出 N 个 A/AAAA 记录且前几个不可达时，最坏 N×12s，用户侧表现为“卡住很久才失败”。 | Happy Eyeballs：前 2 个地址并行（IPv6/IPv4 各一），250ms 无进展再开下一个；整体加总超时（如 15s）；失败聚合错误信息。 | 出站连接延迟、失败体验 | P2 | M |
| NET-08 | Sources/TouchFlowNet/Capture/MITMHandler.swift:174-281、:307-319 | MITM 每个请求都 openUpstream() 新建上游连接（:206-216），同一 keep-alive 客户端多请求不复用；非 direct 出站被静默绕过（:307-319 只 warn），用户配置的代理在 MITM 下失效。 | per-connection 上游 keep-alive 复用（同 host:port 且响应允许 keep-alive）；非 direct 走 dialer.connect(via:)（MITM 客户端到上游本就支持 HTTP CONNECT），不支持时明确报错而非静默直连。 | MITM 性能、代理语义正确性 | P2 | L |
| NET-09 | Sources/TouchFlowNet/Capture/MITMHandler.swift:323-336 | injectCosmeticStyle 用 String(decoding: html, as: UTF8) 整体解码再编码：GBK/Shift-JIS 页面会被替换字符破坏；32MB body 产生约 2 倍内存峰值。 | 仅当 content-type charset 为 UTF-8 且解码成功时注入；注入用字节级插入（在 </head> 的 Data range 处拼接），避免全量 String 往返；超大 body 跳过注入。 | MITM 内容正确性、内存 | P2 | M |
| NET-10 | Sources/TouchFlowNet/Support/TLS.swift:72-207 | LocalTLSServer 每个 MITM 连接新建一个 NWListener（:92-103，端口 .any）+ 一个 DispatchQueue（:152）；高并发 HTTPS 时监听器与线程数线性膨胀。 | 池化 listener（如 8 个复用，每个可接受多连接）或用 NWProtocolTLS 在既有 NWConnection 上做 server 侧终结（更彻底）；队列改为共享串行队列。 | MITM 并发能力 | P2 | L |
| NET-11 | Sources/TouchFlowNet/DNS/FakeIPPool.swift:42-52 | 分配表 allocations 耗尽后 removeFirst() 回收最旧，O(n)；容量默认约 addressCount-2（198.18.0.0/15 ≈ 13 万），长时间运行可达。 | 用环形缓冲 + 游标（O(1) 回收）；映射可选持久化到 Application Support（重启不丢，避免应用缓存指向旧 fake IP）。 | 长时间运行性能 | P2 | S |
| NET-12 | Sources/TouchFlowNet/Proxy/ProxyServer.swift:294-295、:503-506 | CONNECT 路径对同一 host 连续调用两次 blocker.verdict(...)（第二次只为取 reason），每次都要做 keyword 线性扫描 + Trie 查询；captureBody 对每个请求复制 256KB 前缀。 | 只调一次并存结果；captureBody 返回 Data.SubSequence/切片或直接标记截断长度，由 HAR 序列化时再拷贝。 | 每连接 CPU、抓包内存 | P2 | S |
| RT-08 | Sources/TouchFlowRuntime/ProfileStore.swift:41-51、:75-99 | list() 在 NSLock 内同步读取并解码每个 profile JSON（每次 new JSONDecoder）；activeProfileID getter 每次都 Data(contentsOf:)；UI 每次 engine.profiles 都全量扫盘，配置多时卡顿且与 save（不持锁，:53-60）存在读写竞态。 | 内存缓存（id → ProfileMeta，mtime 失效）；IO 移出锁（先取 URL 列表，锁外解码，锁内合并）；activeProfileID 用 UserDefaults + 内存副本；save 纳入同一把锁或改用原子写入 + 版本号。 | 设置页响应、数据一致性 | P2 | M |
| INT-06 | Sources/TouchFlowNet/Outbound/ShadowsocksAEAD.swift:216-236 | write 未加锁就修改 saltWritten/nonce（类型标注 @unchecked Sendable）；当前 BytePump 单写者侥幸安全，一旦上层并发写（如 MITM 复用/重试）就会串 nonce 导致对端解密失败。 | 盐与 nonce 状态用 NSLock 保护（与读路径分离），或把 encode 放进 actor；补并发写单测。 | SS 正确性 | P2 | S |


---

## 3. 建议的实施顺序

原则：先止血（用户可感知的断网/静默失败）→ 再拆热路径（不改行为的性能改造）→ 最后做生命周期与结构重构。每批次结束都必须 `swift build` 零 error、`swift test` 全绿，并跑一次 bench 与 docs/perf.md 基线对比后再进下一批。

| 批次 | 内容 | 并行度 | 前置 | 完成判据 |
|---|---|---|---|---|
| 0 基线 | 落地 scripts/bench.sh、scripts/stress.sh（见第 5 节，本条只提交脚本与基线数据，不动 Sources）；补 4 条缺口测试：2 万条 cosmetic 加载、DNS respond 路径二次查询（上游不可达仍命中）、ProxyServer.stop 后上游 socket/Task 归零（注入可观测 dialer）、FakeIPPool 端口冲突必须 throw；基线写入 docs/perf.md | 全部可并行（只新增 scripts/ 与 Tests/ 文件） | 无 | 基线指标齐全；4 条新测试先红后绿（红=当前缺陷可复现） |
| 1 P0 止血 | RT-01 → RT-03 → DNS-01 | 串行（RT-01/RT-03 同属 TouchFlowEngine 的系统代理状态机；DNS-01 复用 ProxyServer.swift:704-741 的 StartGate 思路，先抽公共 ReadyGate 再落 DNS） | 批次 0 的 FakeIPPool 测试 | 开关系统代理不再断网；系统代理指向真实在听的端口；DNS 端口冲突时 start 抛可读错误且不泄漏 listener |
| 2 热路径 | 2a POL-01 → POL-02（RuleEngine.swift）；2b POL-03 → POL-04（AdBlockEngine.swift）；2c CORE-01（Log.swift）；2d NET-03 → NET-04（Bytes.swift + HTTPMessage.swift） | 四路并行，文件级不重叠 | 批次 0 的 bench 基线 | decide@100k p50 ≤1.0ms；AdBlock 20k cosmetic 加载 ≤2s、query p99 ≤50µs；日志 ≥50k 行/s；32MB body 路径拷贝量下降（Instruments/自建计数） |
| 3 生命周期 | NET-01 → NET-02 → RT-05 → RT-06 → RT-04 | 串行（NET-01 的登记表是 NET-02 释放钩子的前提；RT-05/RT-06 改同一组 start/stop API；RT-04 依赖 sink 生命周期稳定） | 批次 1 | stop 后 FD 差 ≤5；500 并发 p95 <800ms；连续切配置 20 次零 EADDRINUSE |
| 4 抓包与集成 | 4a CA-01 → CA-02 → RT-07（CertificateAuthority.swift、HARExporter.swift、CaptureView）；4b NET-09 → NET-08 → NET-10（MITMHandler.swift、TLS.swift，必须在 4a 合入后做，否则上游复用与握手延迟测不准）；4c INT-01 → INT-02 → INT-03 → INT-04 → INT-05 → RT-02（CommandRunner、SystemProxy、NASMounter、SSHSession、Platform） | 4a 与 4c 并行，4b 依赖 4a | 批次 1 与批次 3（stop 语义） | MITM 100 并发首次握手 p95 <1.5s；HAR 1 万条导出 RSS <500MB 且主线程不冻结；系统代理开关 p95 <1.5s；退出不再残留代理 |
| 5 长尾 | DNS-03、DNS-04、NET-07、NET-11、NET-12、RT-08、INT-06 | 可并行（各自单文件为主） | 无（与批次 2/3 不冲突） | 对应 bench 项与单测；DNS QPS 与缓存内存达标 |

关键串行依赖（不可并行，否则会互相打架）：

1. RT-01 → RT-03 → DNS-01：系统代理写入端口与“监听是否真的起来”是同一个状态判断，分开改会各写一套。
2. NET-01 → NET-02 → RT-05 → RT-06 → RT-04：上游 socket 登记表 → 连接上限 → async start → await stop → sink 批量刷新，后一步都建立在前一步的关闭语义上。
3. CA-01 → CA-02 → RT-07 → NET-08 → NET-09 → NET-10：CA 生成移出锁是 MITM 并发与上游复用的前提；HAR 导出线程化要跟 CA 目录权限一并改（同一目录层级）。
4. INT-01 → INT-02 → RT-02：CommandRunner 的 async 化是 SystemProxy 不卡主线程、退出可超时的前提。

可安全并行的组合：批次 2 的四条；批次 4 的 4a 与 4c；批次 5 全部。

---

## 4. 风险与回归点

### 4.1 必须重跑的测试（逐文件，行号为当前工作树）

| 测试文件 | 用例（行号） | 关联改动 |
|---|---|---|
| Tests/TouchFlowPolicyTests/PolicyTests.swift | testRuleOrderAndExplain:112、testLogicalExpressions:84、testCIDRAndNoResolve:139、testProcessNameAndGeoIP:168、testPolicyGroupResolution:190 | POL-01、POL-02（trace 文案与规则优先级契约） |
| 同上 | testAdBlockVerdictsAndCosmetics:268、testAdBlockPerformance:315（100k 域名规则 / load<1.0s / query<50µs） | POL-03、POL-04 |
| 同上 | testRuleEngineScale:392（10k 规则 / decide<5ms）、testRuleSetLoader:429 | POL-01/02、RT-05 |
| Tests/TouchFlowNetTests/ProxyServerTests.swift | testURLSessionHTTPThroughProxy:53、testHTTPConnectTunnelEchoesBytes:94、testSOCKS5HandshakeToEchoServer:142、testBlockerRejectsHTTPConnectWith403:166、testRouterRejectOutboundIsNotDialed:184 | NET-01、NET-03、NET-04、NET-12、RT-03 |
| 同上 | testPortInUseProducesReadableError:203、testStopIsGracefulAndRestartable:220、testMalformedRequestIsAnsweredOrClosedWithoutCrashing:239、testAllowLANPeerCanConnect:259 | RT-06、NET-02、NET-01 |
| Tests/TouchFlowNetTests/DNSTests.swift | testHostsHitSkipsNetworkEntirely:110、testBlockerProducesNXDOMAIN:132、testCacheServesSecondLookupWithoutQuerying:175、testCacheExpiresAfterTTL:192、testFlushCacheForcesNewQuery:205、testNegativeAnswerIsCached:225、testConcurrentLookupsAreDeduplicated:257 | DNS-02、DNS-04 |
| 同上 | testDNSServerAnswersUDPQueryThroughResolver:280、testDNSServerServesHostsAndBlocksFromConfig:298、testDNSServerAllocatesFakeIPsInFakeIPMode:317、testDNSServerRejectsInvalidPort:339、testFakeIPPoolAllocatesSequentiallyAndReverses:354 | DNS-01、DNS-03、NET-11 |
| Tests/TouchFlowNetTests/CaptureTests.swift | testCertificateAuthorityMintsCAAndLeafIdentity:16、testCertificateAuthorityHandlesIPHosts:51、testCertificateAuthorityReusesCAAndCachesLeaves:60 | CA-01、CA-02 |
| 同上 | testHARExportShapeAndRedaction:81、testLargeBodiesAreRedactedWithLinearScan:148、testHARExportKeepsSecretsWhenRedactionDisabled:175、testHARExportTruncatesBodiesLargerThanOneMegabyte:188、testHARExportMarksBlockedRequests:212 | RT-07、CORE-01 |
| 同上 | testLocalTLSServerCompletesHandshakeWithCAIdentity:231、testMITMTerminatesTLSInjectsCosmeticAndCaptures:258、testMITMIsNotUsedForUnmatchedHosts:332 | NET-08、NET-09、NET-10 |
| Tests/TouchFlowNetTests/ShadowsocksTests.swift | testAEADSealOpenRoundTripAndTamperDetection:65、testStreamFormatIsSaltThenLengthThenPayload:80、testStreamRoundTripAcrossChunkBoundary:105、testEmptyAndBoundarySizes:121、testDecryptRejectsTruncatedStream:137、testDecryptWithWrongPasswordFails:146 | NET-05、INT-06（现有用例都在同进程内，必须补“服务端解密客户端流”的方向） |
| Tests/TouchFlowIntegrationsTests/PlaceholderTests.swift | testSystemProxyParsingAndStatusDoesNotCrash:181、testSSHBinarySmoke:222、testSSHSessionReportsFailureWithoutCrashing:230 | INT-01、INT-02、INT-03、INT-04、RT-02 |
| Tests/TouchFlowNetTests/OutboundDialerTests.swift、TrojanTests.swift、Tests/TouchFlowCoreTests/SmokeTests.swift | 全文件 | NET-07 改拨号策略后全跑 |

### 4.2 调用点（改签名会牵连的入口）

1. Sources/tfctl/main.swift:98-110：rules 直接打印 explain 的 trace 与 decide 的出站名，POL-01 拆分 match/explain 后必须保留 explain() 公共签名。
2. Sources/TouchFlowApp/Views/DashboardView.swift:278：同步调 engine.explain()，POL-01/02 之后若改成 async 会破坏这里，建议保留同步快路径。
3. Sources/TouchFlowApp/Views/CaptureView.swift:254-261：UI 线程 try engine.exportHAR()，RT-07 改异步导出时此处的错误提示与禁用态要一起改。
4. Sources/TouchFlowApp/Platform.swift:72-77 与 Sources/TouchFlowApp/TouchFlowApp.swift:148：退出回滚与启动状态刷新，RT-02/RT-01 会同时改这两处。
5. Sources/TouchFlowRuntime/TouchFlowEngine.swift:182-187、:200-215、:212-215、:319-331：四个 stop→start 点，RT-06 改成 await 后这四处都要加 await 并处理错误。

### 4.3 语义风险（容易“改了但悄悄坏掉”的行为）

1. **explain 的 trace 是契约**：PolicyTests:112 断言命中行文案与顺序，tfctl:104-109 直接展示给用户；POL-01 重构必须逐字保留，并先补 trace 快照测试。
2. **RT-01 不能无条件 disable**：用户可能自己开了别的代理，stop() 里必须先读 SystemProxy.status()，仅当 host/port 与引擎配置一致才回滚，否则只清 systemProxyActive 标志。
3. **NET-01 必须保留半关闭**：BytePump.swift:76-79 的 closeWrite 传播是 CONNECT 隧道单边 EOF 的基础（testHTTPConnectTunnelEchoesBytes:94 依赖），改成 cancel 时不能顺手把两个方向都关死。
4. **CA-02 的 chmod 必须幂等**：CaptureTests:60 断言复用同一 CA 与缓存叶证书；对已存在目录/文件改权限不能触发重签，也不能改动已缓存 identity。
5. **RT-07 保持纯函数**：CaptureTests:81/148/175/188/212 直接比对 exportHAR 的输出字符串；若改流式写，需要保留一个内存版入口，否则测试与调试都会失锚。
6. **RT-04 的 reset 语义**：清空 flows/captures 后 stats 需要区分“本次会话累计”与“当前活动连接”，Traffic 与 Dashboard 两个视图的展示口径要一起改。
7. **DNS-02 与 flush/去重的交互**：DNSTests:205（flush 后必须重新查询）与 :257（并发去重）也覆盖 respond 路径；respond 走缓存后要保证 flush 同时清 respond 的缓存视图，否则本地 DNS 会回旧值。
8. **NET-02 限流不能误伤**：testAllowLANPeerCanConnect:259 与 testMalformedRequestIsAnsweredOrClosedWithoutCrashing:239 依赖“能连上并得到可读响应”；限流只拒新连接（503），绝不主动关闭已建立连接。

### 4.4 性能与稳定性回归门槛（建议纳入本地 CI 或发版前手测）

| 指标 | 采集方式 | 回归阈值 |
|---|---|---|
| decide@100k 规则 p50 | bench A（tfctl rules 循环） | >1.2ms 判失败 |
| AdBlock query p99（100k 域名规则） | bench B | >75µs 判失败 |
| DNS 缓存命中 p50 | bench C | >2ms 判失败 |
| 1 万条抓包导出峰值 RSS | bench D | >400MB 判失败 |
| 500 并发短连接错误率 | stress | >1% 判失败 |
| stop 后 FD 差 | stress | >8 判失败 |

发版前手测清单（无法脚本化的部分）：开/关系统代理后本机能上网；连续切配置 20 次；退出后 `networksetup -getwebproxy Wi-Fi` 不再指向本机端口；MITM 首次新域名握手 <2s；SS 节点能下载一个 10MB 文件；断网后恢复网络无需重启应用。


---

## 5. 基准与压力脚本设计

约束：只用 macOS 自带工具（swift、awk、perl、curl、dig、lsof、ps、networksetup、python3）；**构建用独立 scratch path**（`--scratch-path .build-bench`），确保与主窗口的 `.build` 互不抢锁；基准脚本只读源码、不改任何 .swift。两个脚本落地于批次 0，输出追加到 docs/perf.md，并作为每次改动前后的对比依据。

### 5.1 scripts/bench.sh（基准）

```bash
#!/usr/bin/env bash
# TouchFlow 热路径基准。用法: scripts/bench.sh [baseline|rebuild] [docs/perf.md]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
MODE="$1"; [ -n "$MODE" ] || MODE=baseline
OUT="$2";  [ -n "$OUT" ]  || OUT=docs/perf.md
SCRATCH="$ROOT/.build-bench"          # 独立 scratch，绝不与主窗口共用 .build
TFCTL="$SCRATCH/release/tfctl"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0
note() { printf '%s\n' "$*"; }
judge() { # 名称 实测 阈值 单位
  local n="$1" v="$2" l="$3" u="$4"
  if awk -v v="$v" -v l="$l" 'BEGIN{exit !(v<=l)}'; then
    note "PASS $n = $v$u (<= $l$u)"
  else
    note "FAIL $n = $v$u (> $l$u)"; fail=1
  fi
}
if [ "$MODE" = rebuild ] || [ ! -x "$TFCTL" ]; then
  swift build -c release --scratch-path "$SCRATCH" --product tfctl
fi

# ---- A. 规则规模：decide 端到端延迟（扣掉进程启动开销）----
gen_rules() { # $1=条数 $2=输出
  awk -v n="$1" 'BEGIN{
    print "[Rule]"
    for (i=0;i<n;i++)    printf "DOMAIN-SUFFIX,site%06d.example.com,DIRECT\n", i
    for (i=0;i<n/10;i++) printf "DOMAIN,kw%06d.example.com,REJECT\n", i
    print "FINAL,DIRECT"
  }' > "$2"
}
startup=0
for i in 1 2 3 4 5; do
  t=$( { /usr/bin/time -p "$TFCTL" help >/dev/null; } 2>&1 | awk '/^real/{print $2*1000}' )
  startup=$(awk -v a="$startup" -v b="$t" 'BEGIN{print (a==0?b:(a+b)/2)}')
done
note "tfctl 空载启动 ≈ $startup ms"
# 注意：tfctl 子命令与参数顺序以 `"$TFCTL" help` 的实际输出为准（命令表见 Sources/tfctl/main.swift:19-41）
for n in 1000 10000 100000; do
  gen_rules "$n" "$WORK/r$n.surge"
  t=$( { /usr/bin/time -p "$TFCTL" rules "$WORK/r$n.surge" site000001.example.com >/dev/null; } 2>&1 | awk '/^real/{print $2*1000}' )
  eff=$(awk -v a="$t" -v b="$startup" 'BEGIN{printf "%.2f", a-b}')
  note "A decide@$n = $eff ms"
  [ "$n" = 100000 ] && judge "decide@100k" "$eff" 1.0 ms
  [ "$n" = 10000 ]  && judge "decide@10k"  "$eff" 0.2 ms
done

# ---- B. AdBlock：现有 100k 域名规则基准（已断言 load<1.0s / query<50µs）----
if swift test -c release --scratch-path "$SCRATCH" --filter 'testAdBlockPerformance' 2>&1 | tee "$WORK/ab.log" | grep -q "Executed"; then
  note "B AdBlock 100k 域名规则基准通过（细节见 $WORK/ab.log）"
else
  note "B FAIL: testAdBlockPerformance 未通过"; fail=1
fi

# ---- C. DNS：缓存命中延迟与上游查询次数 ----
# C1 计数桩：本地 UDP 15353，记录收到的查询数（用来证明“第二次走缓存”）
cat > "$WORK/stub.py" <<'PY'
import socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 15353))
n = 0
while True:
    data, addr = s.recvfrom(4096); n += 1
    open(sys.argv[1], "w").write(str(n))
    tid, q = data[0:2], data[12:]
    i = 0
    while q[i] != 0: i += q[i] + 1
    qend = i + 5
    ans = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 300, 4) + bytes([1, 2, 3, 4])
    hdr = tid + b"\x81\x80" + struct.pack("!HHHH", 1, 1, 0, 0)
    s.sendto(hdr + q[:qend] + ans, addr)
PY
python3 "$WORK/stub.py" "$WORK/dnscount" & STUB=$!; sleep 0.5
# C2 起引擎（DNS 监听 127.0.0.1:5354，上游指向桩；profile 形状见 Sources/TouchFlowCore/Models.swift:165-184）
"$TFCTL" run "$WORK/dns.surge" & ENGINE=$!; sleep 1.5
t0=$(perl -MTime::HiRes=time -e 'print time')
dig +short +time=2 +tries=1 @127.0.0.1 -p 5354 cache-probe.example.com >/dev/null
t1=$(perl -MTime::HiRes=time -e 'print time')
dig +short +time=2 +tries=1 @127.0.0.1 -p 5354 cache-probe.example.com >/dev/null
t2=$(perl -MTime::HiRes=time -e 'print time')
miss=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f",(b-a)*1000}')
hit=$(awk  -v a="$t1" -v b="$t2" 'BEGIN{printf "%.1f",(b-a)*1000}')
nq=$(cat "$WORK/dnscount" 2>/dev/null || echo 0)
note "C DNS 首次 $miss ms / 命中 $hit ms / 上游查询数 $nq"
judge "DNS 缓存命中" "$hit" 2.0 ms
[ "$nq" = "1" ] || { note "FAIL DNS 命中仍打上游（当前实现必现）"; fail=1; }
kill "$ENGINE" "$STUB" 2>/dev/null || true; wait 2>/dev/null || true

# ---- D. 抓包：200 次请求后进程 RSS ----
"$TFCTL" run "$WORK/main.surge" & ENGINE=$!; sleep 1.5
for i in $(seq 1 200); do curl -s -o /dev/null --max-time 3 -x http://127.0.0.1:7890 "http://127.0.0.1:1/x$i" || true; done
rss=$(ps -o rss= -p "$ENGINE" | awk '{print int($1/1024)}')
note "D 引擎 RSS = $rss MB（200 次请求后）"
judge "RSS" "$rss" 300 MB
kill -INT "$ENGINE" 2>/dev/null || true; wait 2>/dev/null || true

# ---- E. 100 并发短连接：p95 延迟与成功率 ----
"$TFCTL" run "$WORK/main.surge" & ENGINE=$!; sleep 1.5
seq 1 100 | xargs -P100 -I{} curl -s -o /dev/null -w "%{time_total} %{http_code}\n" \
  --max-time 5 -x http://127.0.0.1:7890 http://127.0.0.1:8080/ > "$WORK/conc.txt" || true
ok=$(awk '$2==200' "$WORK/conc.txt" | wc -l | tr -d ' ')
p95=$(awk '{print $1}' "$WORK/conc.txt" | sort -n | awk '{a[NR]=$1} END{ if(NR==0) print 0; else print a[int(NR*0.95)+1] }')
note "E 并发 100：成功 $ok/100，p95 $p95 s"
judge "并发 p95" "$p95" 0.8 s
[ "$ok" -ge 95 ] || { note "E FAIL 成功率 <95%"; fail=1; }

# ---- F. stop() 后是否残留 ----
before=$(lsof -p "$ENGINE" 2>/dev/null | wc -l | tr -d ' ')
kill -INT "$ENGINE" 2>/dev/null || true; sleep 2
alive=$(ps -p "$ENGINE" >/dev/null 2>&1 && echo yes || echo no)
note "F stop 前 FD=$before，停止后进程存活=$alive"
[ "$alive" = no ] || { note "F FAIL 停止后进程仍在"; fail=1; }

# ---- 报告 ----
{
  echo
  echo "## bench $(date '+%Y-%m-%d %H:%M') ($(sw_vers -productVersion), $(sysctl -n hw.ncpu) cores)"
  echo
  echo "| 项 | 阈值 | 结论 |"
  echo "|---|---|---|"
  echo "| decide@100k | 1.0ms | 见上方 PASS/FAIL |"
  echo "| AdBlock 100k | load<1.0s, query<50µs | 见上方 PASS/FAIL |"
  echo "| DNS 命中 | 2ms 且上游查询数=1 | 见上方 PASS/FAIL |"
  echo "| 200 请求 RSS | 300MB | 见上方 PASS/FAIL |"
  echo "| 100 并发 p95 | 0.8s | 见上方 PASS/FAIL |"
} >> "$OUT"
note "结果已追加到 $OUT"; exit "$fail"
```

说明：A 用“空载启动扣除”把进程启动开销从端到端时延里剥掉（tfctl 子命令参数以 `tfctl help` 为准）；B 复用已有 XCTest 断言（PolicyTests.swift:315、:392），不重复造测量框架；C 的 UDP 计数桩是关键——只有断言“第二次查询时上游计数仍为 1”才能证明 respond 走了缓存，当前实现必然大于 1（DNS-02 的复现条件）；D/E/F 覆盖 PLAN-v2 P4/P5 的抓包内存、并发延迟与停止后 FD 回落。

### 5.2 scripts/stress.sh（压力与故障注入）

```bash
#!/usr/bin/env bash
# TouchFlow 稳定性压测：3 轮 × 500 并发随机中断 + 端口冲突/上游不可达/TLS 失败/退出清理
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SCRATCH="$ROOT/.build-bench"; TFCTL="$SCRATCH/release/tfctl"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
[ -x "$TFCTL" ] || swift build -c release --scratch-path "$SCRATCH" --product tfctl
fails=0
ok()  { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails+1)); }

# 1) 3 轮 × 500 并发，随机 --max-time 制造半开连接与中断
for round in 1 2 3; do
  "$TFCTL" run "$WORK/main.surge" & ENGINE=$!
  sleep 1.5
  seq 1 500 | xargs -P500 -I{} sh -c '
    t=$(awk -v s="{}" "BEGIN{srand(s); printf \"%.2f\", 0.2+rand()*2}")
    curl -s -o /dev/null --max-time "$t" -x http://127.0.0.1:7890 http://127.0.0.1:8080/ || true
  ' > "$WORK/round$round.txt" 2>&1
  alive=$(ps -p "$ENGINE" >/dev/null 2>&1 && echo yes || echo no)
  fds=$(lsof -p "$ENGINE" 2>/dev/null | wc -l | tr -d ' ')
  rss=$(ps -o rss= -p "$ENGINE" 2>/dev/null | awk '{print int($1/1024)}')
  rss_txt="$rss"; [ -n "$rss_txt" ] || rss_txt="?"
  echo "round$round rss=$rss_txt MB fd=$fds"
  [ "$alive" = yes ] && ok "round$round 引擎存活 (fd=$fds)" || bad "round$round 引擎崩溃"
  kill -INT "$ENGINE" 2>/dev/null; wait "$ENGINE" 2>/dev/null
done

# 2) 端口冲突：7890 被占时必须非 0 退出且错误可读
nc -l 127.0.0.1 7890 >/dev/null 2>&1 & BLOCK=$!; sleep 0.5
out=$("$TFCTL" run "$WORK/main.surge" 2>&1); rc=$?
kill "$BLOCK" 2>/dev/null
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "in use"; then
  ok "端口冲突可读错误 (rc=$rc)"
else
  bad "端口冲突未报错 (rc=$rc): $(printf '%s' "$out" | tail -2)"
fi

# 3) DNS 端口冲突：5354 被占时同样必须失败（当前会静默成功 → DNS-01 回归项）
nc -ul 127.0.0.1 5354 >/dev/null 2>&1 & BLOCK=$!; sleep 0.5
out=$("$TFCTL" run "$WORK/main.surge" 2>&1); rc=$?
kill "$BLOCK" 2>/dev/null
[ "$rc" -ne 0 ] && ok "DNS 端口冲突失败" || bad "DNS 端口冲突静默成功 (rc=0)"

# 4) 上游不可达：必须得到可读失败而不是挂死
"$TFCTL" run "$WORK/dead-upstream.surge" & ENGINE=$!; sleep 1.5
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -x http://127.0.0.1:7890 http://example.invalid/ || true)
case "$code" in 000|502|503|504) ok "上游不可达返回 $code" ;; *) bad "上游不可达返回 $code" ;; esac
ps -p "$ENGINE" >/dev/null && ok "上游不可达后引擎存活" || bad "上游不可达导致引擎退出"
kill -INT "$ENGINE" 2>/dev/null; wait "$ENGINE" 2>/dev/null

# 5) TLS/证书失败：握手失败后进程不得崩溃
"$TFCTL" run "$WORK/bad-tls.surge" & ENGINE=$!
sleep 1.5
curl -s -o /dev/null --max-time 5 -k https://127.0.0.1:1/ || true
ps -p "$ENGINE" >/dev/null && ok "TLS 失败后引擎存活" || bad "TLS 失败导致引擎崩溃"
kill -INT "$ENGINE" 2>/dev/null; wait "$ENGINE" 2>/dev/null

# 6) 退出清理：系统代理回滚 + 无残留子进程
"$TFCTL" run "$WORK/main.surge" & ENGINE=$!; sleep 1.5
curl -s -o /dev/null --max-time 3 -x http://127.0.0.1:7890 http://127.0.0.1:8080/ || true
kill -INT "$ENGINE" 2>/dev/null; wait "$ENGINE" 2>/dev/null
sleep 1
if ps -ax -o pid=,comm= | grep -E "networksetup|mount_smbfs" | grep -v grep; then
  bad "存在残留子进程"
else
  ok "无残留子进程"
fi
networksetup -getwebproxy Wi-Fi 2>/dev/null | grep -q "127.0.0.1" && bad "系统代理未回滚" || ok "系统代理已回滚"

# 7) 失败时附采样，便于定位
if [ "$fails" -ne 0 ]; then
  echo "--- 失败，采集线程与内存快照 ---"
  ps -M $$ | head -20
fi
echo "总计失败项: $fails"; exit "$fails"
```

说明：第 2/3 项是 PLAN-v2 P5“端口冲突必须有可读错误”的直接验证（ProxyServer.swift:135-138 已满足，FakeIPPool.swift:137-161 不满足，脚本会红）；第 4/5 项对应“上游不可达 / TLS 失败”；第 6 项覆盖系统代理回滚与子进程残留。所有失败项都打印可复制的判据，可直接作为 CI 断言。

---

## 6. 前 8 条最高价值发现（同步发送给 lead）

| # | 证据（文件:行） | 结论 | 优先级 |
|---|---|---|---|
| 1 | Sources/TouchFlowRuntime/TouchFlowEngine.swift:161-166 | stop() 不回滚系统代理，停止代理即全网断（只有退出路径 Platform.swift:72-77 才回滚） | P0 |
| 2 | Sources/TouchFlowNet/DNS/FakeIPPool.swift:120-169 | DNS 端口冲突只打日志、start() 仍返回成功；tcp 构造失败还会泄漏已启动的 udp listener | P0 |
| 3 | Sources/TouchFlowNet/Proxy/ProxyServer.swift:154-172 | 上游 socket 不在 stop() 的关闭集合内，隧道 Task 要等 300s 空闲超时（:37），停止后 FD/Task 长时间泄漏 | P1 |
| 4 | Sources/TouchFlowPolicy/Rules/RuleEngine.swift:60-104 | decide() 复用 explain()：O(全部规则) + 每规则一条 trace 字符串（上限 200 行）+ 每规则新建 Set | P1 |
| 5 | Sources/TouchFlowPolicy/AdBlock/AdBlockEngine.swift:231-237、:123-140 | cosmetic 构建 O(n²)（firstIndex 线性查重），且每个被拦请求全表线性扫 cosmetic 规则 | P1 |
| 6 | Sources/TouchFlowNet/Capture/CertificateAuthority.swift:76-87、:251-279 | 持 NSLock 同步跑两次 openssl（新 host 握手全部串行化）；run() 无超时且 stderr 管道可死锁；CA 私钥未显式 0600 | P1 |
| 7 | Sources/TouchFlowNet/Outbound/ShadowsocksAEAD.swift:193-210、:238-251 | 读路径不消费对端 salt、读写共用同一 nonce → SS 入站首块必 AEAD 失败，出站不可用 | P1 |
| 8 | Sources/TouchFlowIntegrations/Support/CommandRunner.swift:109-112、:114-133 | 调用线程 usleep 忙等（SystemProxy 一次 enable 最坏 9×10s 压在主线程）；超时后对仍在运行的 Process 读 terminationStatus 会抛 ObjC 异常 | P1 |


## 7. 修复进度（P5 稳定性 + P4 性能实施轮）

本节记录本轮实际落码情况，**以本节状态为准**（覆盖第 2 节表中的初始状态）。
验证命令：`swift build --build-tests --scratch-path .build-runtime` 全绿；`swift test --scratch-path .build-runtime` 共 41/11/21/11/9/11/5/69 个用例 **0 failures**（TEST_STATUS=0）。
基准数字见 `docs/perf.md`。

| ID | 状态 | 落点 | 说明 |
| --- | --- | --- | --- |
| RT-01 | 已修 | Sources/TouchFlowRuntime/TouchFlowEngine.swift `stop()` + 新增 `rollbackSystemProxyIfNeeded()` | 停止代理先回滚系统代理；回滚失败保留 `systemProxyActive` 并记 error 供 UI 重试，成功才继续 teardown |
| RT-03 | 已修 | 同上 `enableSystemProxy()` | 系统代理统一写 `proxy.listeningPort`（mixed），并校验 1...65535；不再写可能未监听的 http/socks 端口 |
| DNS-01 | 已修 | Sources/TouchFlowNet/DNS/FakeIPPool.swift `DNSServer.start()` + 新增 `ListenerGate`/`startError`/`isAddressInUse` | udp/tcp 都等 `.ready` 才置 `running = true`；失败/超时（5s）取消两个 listener 并抛可读错误（含 "already in use"）；tcp 构造失败先 `udp.cancel()` |
| DNS（附带） | 已修 | FakeIPPool.swift `allowLocalEndpointReuse = true` + TouchFlowEngine.swift:106-117 | 重启/切配置的同端口 EADDRINUSE 缓解；DNS 起不来只 warn，mixed 代理继续可用 |
| NET-01 | 已修 | Sources/TouchFlowNet/Proxy/ProxyServer.swift（`clientUpstreams`/`registerUpstream`/`releaseUpstream`，`stop()` 关闭全部上游）+ BytePump.swift `withTaskCancellationHandler` | 停止时上游 socket 立即关闭，不再等 300s 空闲超时；cancel 即唤醒读阻塞 |
| NET-04 | 已修 | Sources/TouchFlowNet/Proxy/HTTPMessage.swift `HTTPHeaders` + 三个 `serialized()` | 增加 `lowered` 小写镜像数组，查找 O(n) 但不再逐项 `lowercased()` 分配；`serialized()` 改 `[String] + joined()`，消除 O(n²) 拼接 |
| POL-01 | 已修 | Sources/TouchFlowPolicy/Rules/RuleEngine.swift `match(_:)` / `decide()` / `explain()` | `decide` 不再生成 trace 字符串；`visitedSets` 提到循环外复用。trace 文案保持原样（PolicyTests:112 断言通过） |
| POL-03 | 已修 | Sources/TouchFlowPolicy/AdBlock/AdBlockEngine.swift | cosmetic 存储改 `[String: [String]]` + `Set` 去重；删除 `appendSelector` 的 `firstIndex(where:)`。新增 Tests/TouchFlowPolicyTests/AdBlockCosmeticTests.swift（2 万条 81 ms，原 O(n²) 会卡死） |
| POL-04 | 已修 | 同上 `cosmeticSelectors(for:)` + `suffixKeys(of:)` | 按后缀链取键并集，例外集合优先；查询 O(labels) 而非全表线性 |
| AdBlock path | 已修 | Sources/TouchFlowCore/Protocols.swift（`verdict(for:path:thirdParty:)` + 默认实现）、ProxyServer.swift:422、MITMHandler.swift:178、TouchFlowEngine.swift `adblockVerdict` | 对齐 path-precise 语义：CONNECT/SOCKS5/DNS 仍 host-only（语义正确） |
| CORE-01 | 已修 | Sources/TouchFlowCore/Log.swift | `Redactor` 正则 `static let` 预编译 + 关键字预筛（无命中直接返回）；日志缓冲改环形数组，`log()` 与 `snapshot()` 均 O(1)/O(n) 线性无搬移 |
| RT-04 | 已修 | Sources/TouchFlowRuntime/TouchFlowEngine.swift `EngineSink`/`applyBuffered`/`trim`/`resetRecordings()` | 每事件入队（无 Task），16 ms 或 4096 条批量 flush 到 MainActor；flows/captures/logs 滞后裁剪；`sink.reset()` 现在真正清空 flows/captures/stats |
| INT-02 | 已修 | Sources/TouchFlowIntegrations/Support/CommandRunner.swift `run()` 尾部 | 只在 `!process.isRunning` 时读 `terminationStatus`，否则 `-1` + error 日志，消除对运行中 Process 取值抛 ObjC 异常 |
| INT-03 | 已修 | Sources/TouchFlowIntegrations/NAS/NASMounter.swift `makeMountPoint(share:)` | 拒绝空/`.`/`..`/含 `..` 段；`standardizedFileURL` 后校验父目录等于挂载根，错误文案 "escapes the mount root" |
| RT-06 | 部分缓解 | FakeIPPool `allowLocalEndpointReuse` + DNS 失败不阻塞启动 | stop→start 的 DNS 端口竞态已消；`ProxyServer.stop()` 仍不等 `.cancelled`，切配置的 mixed 端口竞态未彻底解决 |

### 仍未修（下一轮，按优先级）

1. POL-02：RuleEngine 无后缀 Trie —— 实测 `decide` 线性：1k 282 µs / 10k 2.88 ms / 100k 28.3 ms（debug p50，见 docs/perf.md）。
2. DNS-02：`DNSResolver.respond(to:)` 不查缓存、不单飞，本地 DNS 服务每个查询直打上游。
3. CA-01 / CA-02：`identity(for:)` 仍持锁跑 openssl；openssl 管道无超时；CA 目录/私钥权限与 leaf 目录清理。
4. INT-01 / INT-04：CommandRunner 仍线程内 usleep 忙等；SSHSession teardown 忙等；SystemProxy 一次 enable 最坏 9 次阻塞 spawn 仍在 MainActor 调用链上。
5. RT-02 / RT-05 / RT-07：退出时同步 disable、启动期同步加载规则/AdBlock、HAR 在 UI 线程全量序列化。
6. NET-02 / NET-03 / NET-05 / NET-07 ~ NET-12、DNS-03 / DNS-04、RT-08、INT-05 / INT-06：连接数上限、Bytes 缓冲 O(n²)、SS 读路径 salt/nonce、Happy Eyeballs、MITM 上游复用/编码、LocalTLSServer 每连接 listener、FakeIP 分配 O(n)、ProfileStore 锁内 IO 等。

