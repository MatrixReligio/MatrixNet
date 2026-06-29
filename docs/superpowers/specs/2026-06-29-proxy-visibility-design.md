# 代理真实可见性(Proxy-Aware True Destination & Bytes)设计

- **设计日期**: 2026-06-29
- **目标版本**: 1.8.0(MINOR — 新功能)
- **状态**: 设计(待 spec review)
- **关联**: [[matrixnet-project]]、`docs/superpowers/notes/capture-spike.md`、功能 ③ ECH/SNI 降级

## 1. 背景与问题

当本机运行 **TUN 模式本地代理**(Loon / 旧版 Surge / Clash,含 **fake-IP 模式**)时,MatrixNet 当前表现:

- 经代理的连接 **dst 显示为合成 fake-IP**、**每连接上/下字节恒为 0**;
- Overview 的 "via proxy" 按**连接数**算(注释已承认是因为内核每连接字节为 0 的退而求其次);
- Map / "国家地区" KPI 把 fake-IP 当真实 IP 喂 GeoIP,**算出错误国家**;
- 用户实感:"流量排行 / 历史全是 0 B,目的地是怪 IP"。

这削弱了产品的核心卖点(被动 + per-app 准确),且正中 Loon/Surge 这批重度用户。

## 2. 真机事实基础(决定本设计,2026-06-29 实测)

环境:Loon TUN/增强 + AdGuard 叠栈。命令:`sudo tcpdump -n -i 'pktap,all' -k '(tcp[tcpflags] & tcp-syn != 0) and (tcp[tcpflags] & tcp-ack == 0) and port 443'`。

1. **utun 出向腿带【真实发起 app】的 PID**(命门,已过):
   - `(utun10, proc com.apple.Safari:1778, out) 198.19.0.1.52750 > 198.0.0.60.443`
   - `(utun10, proc Claude:24179, out) 198.19.0.1.49956 > 198.0.0.16.443`
   - `(utun10, proc 企业微信:1376 / curl:96901 / DingTalk:42116, out) ...`
   - **修正**:静态读码时曾假设"utun 上的包是代理 PID";真机推翻——内核在 utun 出向方向已归到原始 app。归属无需重建。
2. **utun 上的 dst 是合成 fake-IP**:src 恒为 TUN 网关 `198.19.0.1`,dst 是 `198.0.x.x` 池(代理 fake-IP 分配)。**真实目的 IP 不在内层包里** → 真实目的地只能靠 **TLS SNI / DNS 映射**,读内层 IP 无意义。
3. **真实公网 IP 只在 en0 的代理腿**,且走远程节点时那是**出口节点**,不是真服务器:
   - `(en0, proc LoonTunnelProvid:14428, out) 172.30.200.128.50112 > 103.51.63.129.443`
4. **真服务器的真实 geo**:走远程节点时,DNS 解析发生在远端代理,**真服务器 IP 这台机器根本不经手** → 纯被动不可得(物理事实)。
5. **叠栈现实**:`com.adguard.mac:2804` 也在 utun10 上 → 真实环境会有两层 NE 栈,设计须容忍。

## 3. 根因(具体、可修)

- **NStat 层**:utun 路由的 app 连接字节不进任何物理桶 → 每连接 0;有字节的只是代理自身到上游的短命连接。
- **包级字节没缝回**:utun 包的 src 是网关 `198.19.0.1`(非 app 真实本地址),其 5-tuple 与 NStat 连接的 5-tuple **对不上**,`packetBytesByConn` 缝不回那条 0 字节连接。**这是关联键 bug,不是架构问题**。
- **指标层**:`proxyShare` 按连接数;fake-IP 被当真实 IP 做 GeoIP。

## 4. 范围

**In scope**
- utun(fake-IP / real-IP TUN)与 lo0(HTTP/SOCKS)形态下,还原经代理连接的 **真实域名 + 真实上/下字节 + 发起 app**。
- 修复 `packetBytesByConn` 缝合键;`proxyShare` 改**按字节**;fake-IP 段不喂 GeoIP。
- **可选主动域名解析**(默认关闭、隐私页明示)补全 Map/"国家地区" geo。

**Out of scope(诚实声明)**
- 经远程节点流量的**真服务器 IP / 真实 geo 的被动获取**——物理不可行;仅可经"可选主动解析"近似(且本机解析结果可能与代理节点不同)。
- **Surge 5.8+ 纯 NEPacketTunnelProvider 隧道**:未实测,可能是抓包盲区 → 检测到则**降级标注**("代理可见性不可用 · NE 接管"),不静默出错。
- **ECH 开启**后的域名:SNI 失明 → 依赖功能 ③ 的 DNS 兜底;ECH+DoH 同开则诚实标"未知"。

## 5. 设计抉择(已定)

**代理流量 geo:主动解析【默认开启】(用户 2026-06-29 改定,覆盖原"默认关")**
- 主动解析默认 ON:仅对**经代理且被动拿不到真实 geo** 的流自动 `域名 → 真实 IP → GeoIP → 国家`,UI 以 `*` 标注"主动解析得出"。设置可一键关闭;首启明确告知。
- 关闭时回退纯被动:域名/字节/app 仍全给,geo 标 "经代理 · 未知"(或出口节点国家,见 §6.6)。

**默认开启的两个诚实后果(必须处理,不得隐瞒)**
1. **破"100% passive / talks to no server"公开宣称**:默认就会发起 DNS 查询。**文案决定(用户 2026-06-29 拍板:仅代理场景说明)**:解析只在"用代理 + geo 未知"时触发,**非代理用户仍 100% 被动**;故 README/隐私页**保留被动招牌**,仅新增一句真实说明,如:"使用本地代理时,GeoIP 解析默认会发起 DNS 查询以补全国家,可在设置关闭。" badge 不动。
2. **fake-IP 回环 → 只有 DoH 可行(待 demo 验证)**:TUN 拦截**一切出站 DNS,含发往 1.1.1.1 的明文 UDP/53**,一律返回 fake IP;故 `getaddrinfo`/明文 DNS 都拿不到真实 IP。**唯一可能成功的是 DoH**(HTTPS、加密,代理只能转发、改不了密文里的解析结果),且须用 **IP 字面量端点**(`https://1.1.1.1/dns-query`)避免 bootstrap 解析被劫持。此假设**必须先做小 demo 真机验证再采用**(见 §10);demo 不通过则 §6.6 主动 geo 整块放弃并向用户汇报。更明确的外发行为,默认开使其自动化,须首启与隐私页讲清。

## 6. 架构与单元(主要落在 MatrixNetCapture + MatrixNetModel,纯核心可测)

1. **FakeIPClassifier(纯函数,Model)**:判定 dst 是否落在合成代理地址段(`198.18.0.0/15` 及可配置池;CGNAT `100.64.0.0/10` 可选)。供 §6.5 GeoIP 守卫与"L3 被代理"判定使用。
2. **TunneledFlowCorrelator(纯函数,Capture)**:消费 PKTAP 包流;对 utun(DLT=rawIP)包按 `(出向腿 app PID, fake 5-tuple)` 归流,**双向累加包长 = 真实字节**;这是代理下的权威 per-app/per-flow 字节源。
3. **缝合(关联修复)**:把 NStat 的"fake dst、0 字节、app PID"连接按 `(app PID + fake dst IP:port)`(**非** app 真实本地址)缝到 §6.2 的 utun 流,替换展示 dst→域名、字节→真实值。
4. **域名解析(复用现有 dissector)**:ClientHello **SNI 为主**;建 `fakeIP↔域名` 表(从观察到的代理 DNS 应答:app 向代理 resolver 查域名得 fake IP)作非 TLS 流兜底。
5. **指标/GeoIP 守卫(消费端)**:`OverviewStats.proxyShare()` 改**按字节**;GeoIP / Map / Countries 对 §6.1 命中的 fake-IP **跳过查询**(不再算错国家),代理流 geo 默认"经代理 · 未知"。
6. **主动 geo 解析(新,默认 ON)**:仅对"代理流且 geo 未知"的域名,**仅经 DoH(IP 字面量端点,如 `https://1.1.1.1/dns-query`;明文 DNS 会被 TUN 劫持成 fake IP,不可用;见 §5 后果2 与 §10 demo 闸门)** 解析 → IP → GeoIP;限流 + 缓存。结果标 `*`。**须把自身发起的解析查询排除出抓包统计**(否则自噪声/反馈环)。设置开关(默认开)+ 首启告知 + 隐私页/README 诚实文案 + 8 语言串。
   - 6.6 备选展示:对走远程节点的流,可额外标"经 〈出口节点国家〉节点"(出口节点 geo 被动可得,但**明确区别于真服务器 geo**)。
7. **去重(防双算)**:en0 上代理进程(`LoonTunnelProvider` 等)的上游腿标记为 `relay`,**不计入 per-app 字节总量**(真实 app 已在 utun 侧计入)。

## 7. 测试策略(TDD,纯核心,用 §2 真机地址做向量)

- `FakeIPClassifier`:`198.19.0.1`/`198.0.0.60` 命中;真实公网 IP 不命中;边界。
- `TunneledFlowCorrelator`:给定合成 PKTAP 流(出向 `proc=Safari` + 网关 src + fake dst + 携 SNI 的 ClientHello),产出 `(app, 域名, 字节)`。
- 缝合:NStat conn(fake dst, 0B, PID) + utun 流 → 合并记录含域名 + 真实字节。
- `proxyShare` 按字节。
- GeoIP 守卫:fake-IP → 无国家。
- 主动解析:默认开 → 对未知-geo 域名触发(注入 mock resolver 断言调用 + 结果标 `*`);关 → 零调用;**自身解析查询不进抓包统计**。
- 去重:en0 relay 腿不进 per-app 总量。

## 8. 分阶段(spike 优先,符合既有方法论)

- **Phase 0(纯核心 spike)**:`FakeIPClassifier` + `TunneledFlowCorrelator` + 缝合逻辑,用 §2 真机向量做 fixtures;`swift test` 可独立跑、**不动 app、不发版**。code-reviewer gate。
- **Phase 1(接入)**:修 `ConnectionAggregator` 缝合键;`proxyShare` 按字节;GeoIP/Map fake-IP 守卫;en0 relay 去重。
- **Phase 2(可选解析)**:opt-in resolver + 设置开关 + 隐私页文案 + 8 语言串。
- **Phase 3(全量回归 + 发版)**:测试 + bundle 验证 + 真机(Loon)核对(签名 smoke,无 TCC 弹窗)+ 8 语言文档(README/CHANGELOG/NOTICE/DocC)+ CI 公证 + appcast/DMG 验收 + 记忆更新。

## 9. 与其他在研功能的关系

- 功能 ③(ECH/SNI 降级)的 **DNS 兜底**与本功能的 `fakeIP↔域名` 映射共享同一关联层 → 建议 ③ 紧接本功能。
- 路线图其余:① 进程身份可信度、② JA4+ 补全、④ 被动 beacon+DGA。

## 10. 待验证假设(demo 先行,不可行即汇报)

用户(资深网络专家)要求:凡"待确认"的底层行为,**先写最小 demo 真机验证,通过才采用;不可行立即汇报**(见 [[demo-first-verify-assumptions]])。本功能需先验证:

- **假设 A(已验证 ✅,2026-06-29)→ Phase 2 采用**:Loon TUN 下 `doh-probe.swift` 实测:`getaddrinfo("www.cloudflare.com")` → `198.0.0.142`(fake,被劫持);**DoH `https://1.1.1.1/dns-query` → `104.16.123.96 / 104.16.124.96`(真实)**。证实只有 DoH(HTTPS 加密、IP 字面量端点)能在 TUN 下拿真实 IP;明文 DNS 不可用。**采用方案**:URLSession 请求 `https://1.1.1.1/dns-query`,`accept: application/dns-json`,取 Answer 中 type==1(A)记录。
- **假设 B(决定缝合键)**:NStat 对代理连接报的 source 是网关 `198.19.0.1` 还是 app 真实本地址(Plan Task 1.0 真机校核)。
- **假设 C(已验证 ✅)**:utun 出向腿带真实 app PID(spec §2 真机抓包已证)。
