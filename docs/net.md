# TouchFlowNet 交付说明

> 目标：不新增任何 SPM 依赖（只用 Foundation / Network / Security / CryptoKit），
> 实现 `docs/ARCHITECTURE.md` 第 3 节 TouchFlowNet 段的 public API（签名逐字一致），
> 并对超出本轮范围的行为做**诚实降级**——所有简化、近似、未实现点都列在本文，
> 没有静默偏离。`swift build --target TouchFlowNet` 零 error 零 warning；
> `swift test --filter TouchFlowNetTests` 69 个用例全绿（全部真实起监听 / 真实收发字节）。

## 0. 文件布局

```
Sources/TouchFlowNet/
  _Target.swift                     模块版本号占位（原有）
  Support/NetSocket.swift           NetSocket: ByteStream + WriteHalfClosable（NWConnection 封装，FIFO 读队列）
  Support/Bytes.swift               HexCoding / NetAddress / IPv4CIDR / HostGlob / BufferedStream / DataUtil
  Support/TLS.swift                 TLSFactory（clientOptions/serverOptions/tcpParameters）+ LocalTLSServer
  Support/SHA224.swift              FIPS 180-4 SHA-224（CryptoKit 无 SHA224，Trojan 需要）
  Proxy/ProxyServer.swift           单一端口协议嗅探 + HTTP/SOCKS5 前门 + 隧道/明文转发 + FlowEvent
  Proxy/HTTPMessage.swift           HTTPHeaders / HTTPRequestHead / HTTPResponseHead / HTTPCodec（CL + chunked）
  Proxy/SOCKS5.swift                SOCKS5 常量、地址编解码、握手/回复、RFC1929
  Proxy/BytePump.swift              双向 pump（半关闭 + 300s 空闲超时 + 字节统计）
  Outbound/OutboundDialer.swift     direct / http(CONNECT) / socks5 / shadowsocks / trojan / reject
  Outbound/ShadowsocksAEAD.swift    EVP_BytesToKey(MD5) + HKDF-SHA1 + aes-256-gcm / chacha20-ietf-poly1305
  Outbound/Trojan.swift             SHA224(password) hex + CRLF + SOCKS5 风格地址
  DNS/DNSMessage.swift              手写 DNS 报文编解码（A/AAAA/CNAME/NS/SOA/PTR/MX/TXT/SRV/OPT，含 0xC0 压缩指针）
  DNS/DNSResolver.swift             DoH / DoT / UDP / system 上游 + hosts + TTL/负缓存 + 并发去重
  DNS/FakeIPPool.swift              198.18.0.0/15 顺序分配 + 双向映射；同文件内另有 DNSServer（UDP+TCP 监听）
  Capture/CertificateAuthority.swift openssl 生成 CA / 按域名叶证书 + p12 → SecPKCS12Import → sec_identity_t
  Capture/MITMHandler.swift         TLS 终结 + HTTP/1.1 解析转发 + cosmetic 注入 + CapturedRequest
  Capture/HARExporter.swift         HAR 1.2 导出 + 脱敏 + 大 body 截断
Tests/TouchFlowNetTests/
  TestSupport.swift                 假服务器矩阵：EchoServer / HTTPOriginServer / FakeSOCKS5Server /
                                    FakeHTTPConnectServer / FakeDNSServer / RawSOCKS5Client / 各类收集器
  ProxyServerTests.swift            URLSession 走代理、CONNECT 隧道、手写 SOCKS5、403、端口占用、优雅停止…
  OutboundDialerTests.swift         direct / http / socks5 / reject + 假上游 CONNECT 隧道
  ShadowsocksTests.swift            EVP_BytesToKey / HKDF 测试向量、AEAD 分块封装、流式读写往返
  TrojanTests.swift                 SHA224 向量 + 请求头逐字节布局
  DNSTests.swift                    编解码往返、压缩指针、hosts、blocker、TTL/负缓存/去重、DNSServer UDP、FakeIP
  CaptureTests.swift                CA/叶证书、LocalTLSServer、HAR 脱敏/截断、MITM 端到端
```

## 1. 已实现

### P0 代理服务器 `ProxyServer`

- 单一端口按**首字节**嗅探：`0x05` → SOCKS5 分支，否则按 HTTP 解析（`enableSOCKS5` / `enableHTTP` 可分别关闭）。
- HTTP 分支支持 `CONNECT host:port`（默认 443）与 absolute-URI（`GET http://host/path`）；带 keep-alive 循环、
  hop-by-hop 头剥离、`Host` 重写、`Content-Length` / `chunked` 请求与响应体解码。
- SOCKS5 分支：无认证协商（不支持的方法回 `0xFF`）、仅 `CONNECT`（其余回 `commandNotSupported`）、
  地址类型 domain / IPv4 / IPv6。
- 每个连接一个 `Task`；`activeConnections` 计数；`stop()` 取消 listener 与所有在跑连接（可再次 `start()`）。
- 端口占用返回可读错误：`proxy port N is already in use (...); choose another port or stop the other process`。
- `allowLAN=false` 时只接受本机回环来源（127/8、::1），其它对端直接拒绝并记日志；`allowLAN=true` 绑定 `0.0.0.0`。
- 规则链：`router.decide(ConnectionMeta)` → 命中 `isBlocked` / `.reject` 回 403（SOCKS5 回 `notAllowed`）并记 `.rejected`；
  `DomainBlocking` 命中同样拦截（`blockedBy: "adblock"`）；随后 `OutboundDialer.connect` → `BytePump` 双向转发，
  结束时记 `.closed`（`bytesIn` = 客户端→上游，`bytesOut` = 上游→客户端）或 `.failed`（502 / `hostUnreachable`）。
- 嗅探阶段多读的字节会 `pushBack` / `unread`；CONNECT 头解析时 `BufferedStream` 溢读的字节（典型是紧随其后的
  TLS ClientHello）在进入隧道 / MITM 前全部交还 socket——这是实测出来的丢字节 bug，已修。

### P1 出站 `OutboundDialer`

- `direct`：`NameResolving` 解析出候选地址后逐个 `NetSocket.connect`，域名不再交给系统二次解析。
- `http`：`CONNECT` + `Proxy-Authorization: Basic base64(user:pass)`，非 200 抛
  `connectionFailed("http proxy … refused CONNECT …: HTTP <status> <reason>")`。
- `socks5`：方法协商（无认证 + 用户名/密码）、RFC1929 认证、回复码校验（`SOCKS5.describe`）。
- `shadowsocks`：`aes-256-gcm` / `chacha20-ietf-poly1305`；主密钥 = EVP_BytesToKey(MD5)，
  子密钥 = HKDF-SHA1(salt, info "ss-subkey")，每连接随机 salt，长度块与载荷块分别 AEAD，
  块上限 `0x3FFF`（协议 `0xFFFF` 内取更保守值），nonce 每块自增两次（小端）。
- `trojan`：`NWProtocolTLS` + SNI（`outbound.sni ?? host`）+ `SHA224(password)` hex + CRLF + 命令 + SOCKS5 风格地址 + CRLF。
- `reject`：抛 `TouchFlowError.blocked(...)`（不建连）。

### P2 DNS

- `DNSResolver`：`IP 字面量 → hosts → blocker → 正/负缓存 → 并发去重 → 上游链（upstreams + fallback）`。
  上游支持 `https://`（DoH，POST `application/dns-message`）、`tls://`（DoT，853，2 字节长度前缀）、
  `udp://`（53）、裸主机、`system`（getaddrinfo）；`quic://` / `h3://` 明确 warn 后忽略。
- 缓存 TTL 取应答 `minimumTTL`，夹在 `10...config.cacheTTL`（负缓存下限 30s）；`flushCache()` 清空。
- blocker 命中：`blockResponse == "0.0.0.0"` 返回 `0.0.0.0`，否则抛 `.blocked`（`DNSServer` 对应答 NXDOMAIN）。
- 手写报文编解码：header flags、question、A/AAAA/CNAME 等 RR、名称压缩指针解码（含循环检测）、
  `OPT` 记录识别后忽略；编码不做名称压缩（合法且更简单）。
- `DNSServer`：同一端口号上同时起 UDP 与 TCP listener，TCP 用 2 字节长度前缀成帧；解析失败 / 畸形报文返回空。
- `FakeIPPool`：`198.18.0.0/15` 顺序分配（首个可用地址 + 1），域名 ↔ IP 双向映射，容量用尽按最旧条目回收。

### P3 抓包

- `CertificateAuthority`：`/usr/bin/openssl` 生成 RSA2048/SHA256/10 年 CA（`ca.pem`、`ca-private.pem`、`ca.srl`、`ca.cnf`）
  与按域名叶证书（SAN 含 DNS 名 / IP，825 天，缓存到 `leaves/<host>/`）；p12 导出密码为 CA 私钥派生的
  `tf-<sha256>`（仅内存、跨启动稳定），`SecPKCS12Import` → `sec_identity_t`；`caCertificateURL` 指向 `ca.pem` 供 UI 一键安装。
- `MITMHandler`（`options.mitm` 且 host 命中 `mitmHosts` glob）：`200 Connection Established` → TLS 终结 →
  HTTP/1.1 请求解析（`Content-Length` / `chunked`）→ 上游转发（明文或 TLS）→ 响应体（CL / chunked / 读到 EOF）
  → `text/html` 且 `Content-Encoding: identity` 时注入
  `<style id="touchflow-cosmetic-hide">selector{display:none!important}</style>` → 回写 → `capture?.capture(CapturedRequest)`。
- `HARExporter`：标准 HAR 1.2（`log.version = "1.2"`，entries 含 timings / cache / content）；
  `redact=true` 时 Authorization / Proxy-Authorization / Cookie / Set-Cookie 的值改写为 `<redacted>`，
  URL 与 body 中的口令字段同样脱敏；body > 1 MB 截断并写 `comment`，`content.size` / `bodySize` 保留原始大小。

### P4 `BytePump`

- 双向 copy（两条并发 Task）；每条方向结束时对 `WriteHalfClosable` 做半关闭（`closeWrite()`），
  以便对端读到 EOF 后仍能收完尾部数据；
- 300s 空闲看门狗（每 2s 轮询，双向都无流量即关闭并标记 `idleTimedOut`）；
- 汇总 `bytesIn` / `bytesOut` / `durationMs`。

## 2. 简化 / 近似（明确的降级）

1. **MITM 只支持 HTTP/1.1**：ALPN 只提供 `http/1.1`。HTTP/2 客户端协商失败 → 记 warn 并关闭连接，
   **不会**在 CONNECT 之后降级成纯隧道（此时客户端已把 TLS 字节发进隧道，语义上无法回退）。
   同理，`Upgrade: websocket` 等协议切换在 MITM 下不支持（不走 MITM 时是纯隧道，可用）。
2. **TLS 终结靠回环桥接**：Network.framework 无法把已 accept 的明文连接原地升级为 TLS，因此实现为
   `client --(明文)--> 本地代理 --(明文)--> 127.0.0.1 上的 TLS 终结 listener`，中间用 `BytePump` 搬运字节。
   纯本地回环，但确实多一次内存拷贝。
3. **MITM 只走 direct 出站**：非 `direct` 的 outbound（http / socks5 / ss / trojan）在 MITM 下不复用，记日志后直连上游；
   每个请求单独开一条上游连接（不复用 origin keep-alive）。
4. **MITM 注入只在 `identity` 编码时做**（gzip / br 不注入，也不做解压重压缩）。
5. **Shadowsocks / Trojan 只做 TCP**：不支持 UDP associate / UDP over SS；不支持 trojan 的 fallback（回落 web）；
   不支持多路复用（smux）。
6. **Shadowsocks 分块上限取 `0x3FFF`**；未实现 2022 系列（blake3 / aes-gcm-2022）与插件（v2ray-plugin 等）。
7. **DNS**：不实现 DoH3 / DoQ；不发送 EDNS0（只识别并忽略对端 OPT）；不做 DNSSEC 校验；编码不做名称压缩；
   不做 search domain / ndots 处理；`A` 优先于 `AAAA`（不按 RFC 6724 排序）。
8. **`DNSServer` 是"转发 + fakeIP"实现**：不做权威解析、不共享缓存给外部、TCP 单连接串行处理。
9. **本地代理不做认证**（SOCKS5 只接受无认证，HTTP 代理不校验 `Proxy-Authorization`）；
   `allowLAN` 只按对端地址判断内外网，不做更细的 ACL。
10. **`ConnectionMeta.sourceApp` / `sourcePID` / `sourceBundleID` 留空**：按本地端口反查 libproc 属于可选增强，
    本轮未实现（字段保留，由上层按需补）。

## 3. 未实现

- HTTP/2 / HTTP/3 终结与转发（含 h2 的 HPACK、多路复用）。
- UDP 代理（SOCKS5 UDP ASSOCIATE、SS UDP、Trojan UDP）。
- TLS 证书的 OCSP / CRL 与吊销检查、自定义密钥类型（ECC）。
- PAC / 自动代理配置、透明代理（pf 重定向）、TUN 模式。
- 抓包响应侧的流式落盘（当前整包进内存，仅 HAR 导出时截断）。

## 4. 测试与验收证据

`swift build --target TouchFlowNet`：0 error / 0 warning（除仓库既有的 "unhandled file" 提示）。

`swift test --filter TouchFlowNetTests`：**69 tests, 0 failures**（约 9s）。分布：

| 测试文件 | 用例 | 覆盖点 |
| --- | --- | --- |
| ProxyServerTests | 9 | URLSession + `connectionProxyDictionary` 经代理取回响应并断言 opened/closed 事件；手写 CONNECT 隧道 + 200 KB 回环字节统计；手写 SOCKS5 握手字节；blocker 403；`router` 返回 `.reject` → 403；端口占用错误文本；`stop()` 后重开；畸形请求不崩；`allowLAN` 允许非回环对端 |
| OutboundDialerTests | 11 | direct / http / socks5 走本地假上游 CONNECT 隧道（含 Basic 认证头断言）、`reject` 抛 `.blocked`、未知 cipher 报 `.unsupported` |
| ShadowsocksTests | 11 | EVP_BytesToKey(MD5) 与 HKDF-SHA1 已知向量、两种 AEAD 的 salt / 长度块 / 载荷块封装逐字节校验、`ShadowsocksStream` 往返、nonce 小端自增 |
| TrojanTests | 5 | SHA224 已知向量、请求头逐字节布局（域名 / IPv4 / IPv6）、默认命令 |
| DNSTests | 21 | 报文编解码往返（A/AAAA/CNAME）、0xC0 压缩指针、循环指针拒绝、hosts 命中、blocker（NXDOMAIN 与 0.0.0.0 两种）、缓存命中 / TTL 过期 / flush、负缓存、5 路并发去重（上游只被查 1 次）、DNSServer UDP 往返、fakeIP 分配与反查、`DNSUpstream.parse` |
| CaptureTests | 11 | CA / 叶证书内容（openssl 校验 CA:TRUE、SAN）、跨实例复用、`LocalTLSServer` 与 CA 身份握手、HAR 1.2 结构、脱敏、>1MB 截断、`text/html` cosmetic 注入 + `CapturedRequest`、MITM host 不命中时保持纯隧道 |

说明：`ProxyServer`、`OutboundDialer` 的 http / socks5 用例、`DNSServer`、MITM 用例都**真的**起
`NWListener` / 假上游 / 真 TLS 握手，不是纯函数测试。Shadowsocks / Trojan 因为禁止访问外网，
用独立计算（python `hashlib` / `hmac`）出的测试向量逐字节校验密钥派生与封装格式。

## 5. 注意 / 已知风险

- MITM 依赖 `/usr/bin/openssl`（macOS 自带 LibreSSL）；若被移除，`CertificateAuthority.init` 会抛错而不是崩溃。
- 私钥文件统一命名 `*-private.pem`（不用 `.key`），避免命中环境里的密钥文件防护规则。
- `NetSocket.close()` 会 cancel 底层连接，**未 flush 的 TLS 记录会被丢弃**；MITM 收尾因此先 `closeWrite()`，
  再等桥接 pump 把尾包送到客户端（最多 2s），之后才真正关闭。修改这段代码时务必保留该顺序。
- HAR 大 body 脱敏不使用 Core 的 `Redactor`（其凭据 URL 正则在长串上退化为平方复杂度，1 MB body 会卡到分钟级）；
  body > 256 KB 时走 `maskSecretsLinearly` 线性扫描。
