# 功能 ④ 设计:per-app 加密 DNS 检测("你的 DNS 泄露给网络/ISP 了吗")

> 本批第 4 个子项目。内部设计文档(中文)。目标版本:**1.5.0(build 35)**。

## 1. 目标与价值

被动判定每个连接/每个应用的 **DNS 传输方式与隐私态势**:DNS 查询是**明文**(网络/ISP 可见、可篡改)还是**加密**(DoT/DoQ/DoH),以及加密时用的是哪个解析器。回答用户最关心的隐私问题:"哪些 App 还在用明文 DNS?我的 DNS 是不是真的加密了?"

- **明文 DNS**:UDP/TCP 53 端口 → 查询内容对本地网络、Wi-Fi 热点、ISP 完全可见,可被监听/投毒。
- **DoT(DNS over TLS)**:TCP 853 → 加密。
- **DoQ(DNS over QUIC)**:UDP 853 → 加密。
- **DoH(DNS over HTTPS)**:443 端口且目标主机名命中已知 DoH 解析器(如 `cloudflare-dns.com`、`dns.google`)→ 加密,藏在普通 HTTPS 里。
- **mDNS/LLMNR**(5353/UDP 等):本地链路多播,不出网,单独标注为"本地发现",不计入"明文泄露"。

竞品空白:没有 macOS 工具给出 **per-app 的 DNS 加密态势**。NextDNS/防火墙厂商用"已知 DoH 主机名清单"识别 DoH,但都不按进程归属、不在一个面板里告诉你"Safari 用 DoH、某后台进程仍走明文 53"。这是直接面向大众隐私痛点、且数据已在手的功能。

## 2. 范围与边界(关键区别于 ①②③)

- **非 capture-only**:分类只需 **5-tuple(协议+目标端口)+ 目标主机名(已由 SNI/DNS 富化进 `Connection.remoteHostname`)**,这些在**常规 NStat 被动监控**下就有。所以本功能**不需要开抓包即可工作**,是本批第一个"始终在线"的分析能力。
- **DoH 判定依赖主机名**:DoH 与普通 HTTPS 在线路上无法区分,唯一被动信号是"目标是已知 DoH 解析器主机名"。因此 DoH 检测 = 443 端口 + `remoteHostname` 命中**已知 DoH 提供方清单**(后缀匹配)。无主机名时不臆测 DoH(避免把去 1.1.1.1:443 的普通流量误判)。
- 本版用**内置静态 DoH 提供方清单**(策划的主流解析器域名)。自更新数据集(同 Threat/GeoIP 模式)留作后续增强,不阻塞本版。
- 不做主动探测;纯被动;零网络声明、零冲突。

## 3. 架构与组件(纯核心 spike-first,复用现有富化)

数据流(常规监控即生效):
```
NStat/抓包 → Connection{fiveTuple, remoteHostname}(remoteHostname 已由 SNI/DNS 富化)
   → DNSEncryptionClassifier.classify(proto:, port:, hostname:) -> DNSTransport
   → per-connection 在连接检查器显示;per-app 归并隐私态势(AppModel)→ 可选 Overview KPI
```

### 3.1 纯核心(MatrixNetModel,`swift test` 独立验证)
- **`enum DNSTransport: Sendable, Equatable`**:`.plaintext`、`.dot`、`.doq`、`.doh(resolver: String?)`、`.localDiscovery`(mDNS/LLMNR)、`.none`(非 DNS 流量)。附 `isEncrypted: Bool`、`displayLabel`/本地化 key。
- **`enum DNSEncryptionClassifier`**:
  - `static func classify(proto: TransportProtocol, port: UInt16, hostname: String?) -> DNSTransport`。
    - port 53 → `.plaintext`(UDP 或 TCP)。
    - port 853 + TCP → `.dot`;port 853 + UDP → `.doq`。
    - port 5353 → `.localDiscovery`(mDNS);LLMNR 5355 同。
    - port 443 + hostname 命中 DoH 清单 → `.doh(resolver: 命中的提供方名)`。
    - 其余 → `.none`。
  - `static func knownDoHProvider(_ hostname: String) -> String?`:对内置清单做**大小写无关的后缀匹配**(如 `*.cloudflare-dns.com`、`dns.google`、`*.dns.nextdns.io`),返回友好提供方名(Cloudflare/Google/Quad9/NextDNS/OpenDNS/AdGuard/…)或 nil。清单为模型内静态表(seed),便于 TDD。
- **`struct AppDNSPosture: Sendable, Equatable`**(归并结果):`{app, transports: Set<DNSTransport>, usesPlaintext: Bool, usesEncrypted: Bool}`,供 per-app 隐私态势展示。

### 3.2 归属与快照
- 分类是**无状态纯函数**,可在 `AppModel` 发布连接快照时按连接计算(无需聚合器新状态),也可在连接检查器即时调用。per-app 归并:`AppModel` 遍历当前连接,按 displayName 汇总 `DNSTransport` 集合 → `AppDNSPosture`。无新增持久化(隐私态势是实时视图)。

### 3.3 UI
- **连接检查器**:对判定为 DNS 的连接(`transport != .none`)新增一行 **"DNS"**,显示分类:`Plaintext DNS`(警示色)/`DNS over TLS`/`DNS over QUIC`/`DNS over HTTPS (Cloudflare)`/`Local discovery (mDNS)`。明文用 advisory/warning 配色 + 简短提示"visible to your network"。
- **连接列表**(可选,低风险):对 DNS 连接在 Remote 列加一个小锁/解锁图标(加密=锁,明文=警示),`help` 提示。本版可只做检查器,列表图标视实现成本决定。
- (可选)Overview 不强加 KPI 本版,聚焦连接级 + 检查器,避免概览 churn。

## 4. 错误处理与降级
- 无 `remoteHostname` 的 443 连接 → 不判 DoH(返回 `.none`),不误报。
- 53/853 仅凭端口即可判定,不依赖主机名。
- 分类是纯函数、总返回有意义值,无抛错。

## 5. 测试策略(TDD)
### 第 0 阶段:DNSEncryptionClassifier 纯核心 spike(`swift test`,不动 app)
- 53/UDP、53/TCP → `.plaintext`。
- 853/TCP → `.dot`;853/UDP → `.doq`。
- 443 + `cloudflare-dns.com` → `.doh("Cloudflare")`;443 + `dns.google` → `.doh("Google")`;443 + `example.com` → `.none`;443 + nil → `.none`。
- 5353 → `.localDiscovery`。
- 其他端口 → `.none`。
- `knownDoHProvider`:后缀/大小写/子域匹配(`mozilla.cloudflare-dns.com` 命中 Cloudflare;`DNS.GOOGLE` 命中 Google)。
- `AppDNSPosture` 归并:同一 app 既有 53 又有 DoH → `usesPlaintext && usesEncrypted`。
### 接入阶段(影响版本)
- `AppModel` per-app 归并 + `dnsPosture(for:)`/`dnsTransport(for connection:)`;连接检查器 "DNS" 行 + 空态/配色;回归不受影响。
- 全程 Swift Testing、零警告、双 linter、8 语言、界面核验(用 `scripts/smoke.sh` 正签后启动,避免 TCC 弹窗)。

## 6. 交付与发版
spike 绿 + review → 接入 → code-reviewer 清零 → 测试全绿 + 界面核验(smoke.sh 签名构建)→ 文档(README ×8 "per-app 加密 DNS 检测" bullet、CHANGELOG、新 UI 串 8 语言;DoH 清单若引用外部来源则 NOTICE 标注)→ 版本 1.5.0/35 → 提交(无 Claude 署名)→ push → Release(`gh workflow run release.yml -f version=v1.5.0`)→ appcast(sparkle:version=35)→ 本地 Developer-ID 安装。

## 7. 自审清单
- 无 TBD;范围单一(被动 DNS 传输分类 + per-app 态势)。自更新 DoH 清单明确留作后续。
- 复用:`remoteHostname` 富化、连接快照、Threat/GeoIP 式静态清单;分类为纯函数无新持久化。
- **非 capture-only** 已明确(本批首个常驻能力);命名一致:`DNSTransport`/`DNSEncryptionClassifier`/`classify`/`knownDoHProvider`/`AppDNSPosture`/`dnsPosture(for:)`/`dnsTransport(for:)`。
- 界面核验改用 `scripts/smoke.sh`(Developer-ID 正签)以杜绝 TCC 弹窗。
