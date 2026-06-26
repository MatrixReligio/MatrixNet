# 捕获层 spike 实测笔记（内部 · 中文）

> 2026-06-26 在 macOS 26.5.1 (25F80, arm64) 实测。所有结论来自真机运行 `Tools/nstat-spike/`，非文档臆测。

## NStat（NetworkStatistics）— 架构 A′ 地基，已验证 ✅

**结论：非 root（uid=501）、非沙箱进程，可拿到全系统每条连接的 PID + 进程名 + 5 元组 + 字节/包计数。** 无需 entitlement、无 TCC 弹窗。与正在运行的代理软件（实测看到 `LoonTunnelProvider` 的连接）零冲突共存。

### 真实导出符号（dlsym 探测 13/16 存在）
存在：`NStatManagerCreate`、`NStatManagerDestroy`、`NStatManagerAddAllTCP`、`NStatManagerAddAllUDP`、`NStatManagerAddAllTCPWithFilter`、`NStatManagerAddAllUDPWithFilter`、`NStatManagerSetFlags`、`NStatSourceSetDescriptionBlock`、`NStatSourceSetCountsBlock`、`NStatSourceSetRemovedBlock`、`NStatSourceSetEventsBlock`、`NStatManagerQueryAllSourcesDescriptions`、`NStatSourceQueryDescription`。
不存在（计划曾臆测，已废弃）：`NStatManagerSetInterfaceTrafficDescriptionBlock`、`NStatManagerSetProviderStateChangeBlock`、`NStatManagerSetInterfaceQueryBlock`。

### 调用法（spike 已跑通）
```
manager = NStatManagerCreate(kCFAllocatorDefault, dispatch_queue, addedBlock: (NStatSource)->Void)
NStatManagerAddAllTCP(manager); NStatManagerAddAllUDP(manager)
// addedBlock 内：对每个新 source 调
NStatSourceSetDescriptionBlock(source, (CFDictionary)->Void)   // 连接元数据
NStatSourceSetCountsBlock(source, (CFDictionary)->Void)        // 字节/包增量刷新
NStatSourceSetRemovedBlock(source, ()->Void)                   // 连接关闭
```
- 回调在传入的 dispatch queue 上。FFI 用 `dlsym` + `unsafeBitCast` 到 `@convention(c)` 函数指针；block 参数用 `@convention(block)`；queue 传 `OpaquePointer(Unmanaged.passUnretained(queue).toOpaque())`。

### description 字典真实 key（实测）
- PID：**`processID`**（Int）；另有 `epid`/`eupid`/`uniqueProcessID`。进程名：**`processName`**（String）。
- 协议：**`provider`** = "TCP" / "UDP"。
- 地址：**`localAddress`** / **`remoteAddress`** = CFData（sockaddr）。v4 为 16 字节：`[sa_len=0x10][sa_family=0x02][port BE 2B][IPv4 4B][pad 8B]`；v6 family=0x1e(30) 为 28 字节 sockaddr_in6。
  - 实例：remote `100201bbb73c0f18...` → fam 0x02, port 0x01bb=443, addr b7.3c.0f.18。
- 字节：`rxBytes`/`txBytes`；包：`rxPackets`/`txPackets`；状态：`TCPState`("Closed" 等)；接口 index：`interface`；`ifWiFi`/`ifCellular` 等标志。

### counts 字典（NStatSourceSetCountsBlock）
携带 rx/tx bytes/packets 的最新累计值（用于增量刷新连接计数）。

## 待真机验证（root）
- PKTAP：以 `bsd/net/pktap.h` 为准，验证"单个 pktap 会话即覆盖 en0+utun*，每包带 pth_ifname+pth_pid"（review M7：双抓很可能多余）。
- 公证（review H1）：`AuthKey_F6M57PP394` 需确认是否 Team Key；notarytool 必须 Team Key + issuer UUID（Individual Key 不被 Notary API 接受）。

## 对计划的影响
- H2 已排除 → 架构 A′ 成立，可放心实现 `NetworkStatisticsMonitor`。
- 真实 key 已知 → 绑定按实测写。
- 采纳 review M1：优先做垂直切片（NStat 监控 + Store + 最小 UI）。
