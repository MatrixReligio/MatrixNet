# 功能 ② 设计:QUIC / HTTP-3 可见性

> 本批(抓包/协议分析)第 2 个子项目。内部设计文档(中文)。
> 目标版本:**1.3.0(build 32)**(① 已发 1.2.0/31;新功能 → MINOR)。

## 1. 目标与价值

被动解析 **QUIC Initial 包**,拿到每条 QUIC/HTTP-3 连接的 **SNI、ALPN、QUIC 版本**,并**按进程归属**;同时复用 ① 的 JA4 核心算出 **QUIC 的 JA4 指纹(传输前缀 `q`)**。这补上 MatrixNet 当前最大的盲区:现有 SNI/域名提取只覆盖 TCP+TLS,而 **HTTP/3 已占约 21% 的请求**(Google 系、YouTube、Instagram 等大量走 QUIC),目前只能靠"UDP 443 端口"瞎猜(`OverviewStats` 里就是个 heuristic 占位符)。竞品(Charles/Proxyman 对 QUIC 抓瞎;Little Snitch 只到连接级;Wireshark 能解但无 per-app)在桌面端无 per-app QUIC 画像。

## 2. 关键技术依据(被动·不解密机密的前提下能拿到什么)

- **QUIC Initial 包用"公开密钥"加密**:RFC 9001 §5.2,初始密钥由 **版本固定 salt + 客户端 DCID** 经 HKDF 派生——salt 是规范常量、DCID 在长头里明文可见,**无需任何握手机密即可解密 Initial 包**。这让我们能读出其中 CRYPTO 帧里的 TLS ClientHello → SNI/ALPN/supported_versions。Handshake/1-RTT 包用真正的 TLS 密钥(不可见,与 TLS 1.3 同盲区,本功能不碰)。
- **权威测试向量 = RFC 9001 Appendix A**:给出一条真实 client Initial 包(DCID `0x8394c8f03e515708`)及期望的 client_initial_secret / key / iv / hp / 解密后载荷。**这是 spike 的回归门**(等同 ① 的 FoxIO 向量)。所有常量(salt、HKDF label "client in"/"quic key"/"quic iv"/"quic hp")实现时**逐字对照 RFC 9001,不凭记忆**。
- **解密步骤**(全部被动):① 解析长头(首字节、version、DCID len+DCID、SCID len+SCID、token len+token、length varint);② `initial_secret = HKDF-Extract(salt, DCID)`,`client_initial_secret = HKDF-Expand-Label(initial_secret, "client in", "", 32)`;③ 派生 key(16)/iv(12)/hp(16);④ **头保护**:取密文 sample 16B,用 hp 密钥 **AES-128-ECB** 出 mask,还原首字节低位得 pn 长度、还原 packet number;⑤ nonce = iv XOR padded pn;⑥ **AES-128-GCM** 解密载荷(AAD=到 pn 末尾的头);⑦ 解析 CRYPTO 帧(type 0x06,offset+length),**按 offset 重组**出 TLS ClientHello;⑧ 复用 `TLSDissector`/`JA4` 的 ClientHello 解析逻辑提取 SNI/ALPN/版本 + JA4(transport=.quic)。
- **crypto 可用性**:HKDF + AES-128-GCM 用 **CryptoKit**(`HKDF<SHA256>` / `AES.GCM`,确定性、可对 RFC 向量回归);**头保护的 AES-128-ECB CryptoKit 不暴露 → 用 CommonCrypto**(`CCCrypt` kCCAlgorithmAES + ECB,单块,系统框架)。仅此一处用 CommonCrypto,封装在一个小函数里。
- **边界**:ECH 普及后 inner ClientHello 加密、SNI 退化(同 ①,优雅降级)。QUIC 版本协商/草案版本 salt 不同(只支持 RFC 9001 v1 `0x00000001`,其余版本识别为 QUIC 但不解密,优雅降级)。连接迁移(CID 轮换)只影响后续包,Initial 在握手首包即可拿到目标信息,不受影响。

## 3. 架构与组件(各单元单测可验,spike-first)

数据流(抓包开启时,UDP/443 或长头判定为 QUIC):
```
PKTAP → PacketDissector(UDP payload 起) → QUICDissector.dissectInitial(bytes)
   → 长头解析 + 公开密钥派生 + 头保护去除 + AES-GCM 解密 + CRYPTO 重组
   → 复用 ClientHello 解析 → (SNI, ALPN, version, JA4-quic)
   → DissectionNode("QUIC" 层,字段:Version/DCID/SNI/ALPN/JA4) + hostnames + tlsClientFingerprint
PacketDissector 已有的 hostnames / tlsClientFingerprint 管道(①建好)→ per-app 归属、富集、持久化(全部复用,零新管道)
```

### 3.1 纯协议核心(MatrixNetDissection,可 `swift test` 独立验证 —— 第 0 阶段 spike)
- **`QUICInitial`**(新):长头解析结果(version, dcid:[UInt8], scid, tokenLength, payloadOffset, length…),纯。
- **`QUICInitialCrypto`**(新):`initialSecrets(dcid:) -> (key,iv,hp)`(HKDF,CryptoKit);`removeHeaderProtection(...)`(AES-ECB via CommonCrypto 出 mask + 还原 pn);`decryptPayload(...)`(AES-GCM, CryptoKit);全部对 **RFC 9001 Appendix A 向量**回归。
- **`QUICCryptoFrames`**(新):从解密载荷扫描 CRYPTO 帧(0x06)、按 offset 重组 ClientHello 字节;忽略 PADDING(0x00)/PING(0x01)/ACK 等;纯。
- **`QUICDissector`**(新):串起上述 → 产出 `DissectionNode` + `serverName` + `alpn` + `clientFingerprint(quic)`。复用 ① 的 `JA4ClientHello` 解析:把重组出的 ClientHello 字节喂给一个**可被 TCP 与 QUIC 共用**的 ClientHello 解析入口(把 `TLSDissector.parseClientHello` 提炼成可复用,DRY),JA4 用 `transport: .quic`。
- **`varint`**:QUIC 变长整数解码(纯,单测)。

### 3.2 接入(复用 ① 已建管道)
- **`PacketDissector.parseApplicationLayer`**:UDP 且(源/目的端口 443 或长头首字节高位=1 且 version 已知)→ `QUICDissector` → 返回 `ApplicationLayer(node, hostnames:[(目的IP, SNI)], fingerprint: JA4-quic)`。**hostnames 与 tlsClientFingerprint 走 ① 已有的 DissectedPacket 透出 + ConnectionAggregator 归属 + FingerprintStore 持久化,零新增管道。**
- **`OverviewStats`**:把"UDP443 启发式 QUIC"替换为真实 QUIC 识别(有 QUIC dissection 才记 QUIC)。
- **UI**:Packets 检查器 QUIC 层自动显示 Version/SNI/ALPN/JA4;连接检查器的 TLS 指纹区(①已建)自动纳入 QUIC 的 JA4(transport q);域名富集让 HTTP/3 连接也显示真实 host(此前缺失)。

## 4. 错误处理与降级
- 非 RFC9001-v1 版本 / 非 Initial(短头 1-RTT)/ 解密失败 / CRYPTO 不完整:不产出 SNI/JA4,仅标记为 QUIC(版本若可读则显示),其余层不受影响(沿用 `try?` 总体不抛风格)。
- 抓包未开:无包→无数据(同 ①,QUIC 也只能来自 PKTAP)。
- CommonCrypto/CryptoKit 均系统框架,恒可用;测试用 RFC 确定性向量。

## 5. 测试策略(TDD)
### 第 0 阶段:解密核心 spike(纯,`swift test`,不动 app、不发版)
- HKDF 派生对 **RFC 9001 Appendix A** 期望 client_initial_secret/key/iv/hp 逐一断言。
- 头保护 mask、pn 还原、AES-GCM 解密对 Appendix A 的真实 Initial 包→期望明文载荷断言。
- CRYPTO 帧重组:乱序/分片 offset 正确拼接;PADDING 跳过。
- varint 边界(1/2/4/8 字节)。
- 端到端:RFC 向量 Initial → 解出 ClientHello → SNI/ALPN/JA4(q…)。
- **真实抓包验证(best-effort)**:用 `tcpdump`/app PKTAP 抓一条真实 QUIC Initial(如访问 google.com 的 HTTP/3),解出 SNI 与 JA4-q,写入 `docs/superpowers/notes/quic-spike.md`。
### 接入阶段(影响版本,spike 绿后)
- `QUICDissector` 集成 PacketDissector:UDP443 QUIC 包 → `DissectedPacket.hostnames` 含 (IP, SNI)、`tlsClientFingerprint` 为 `q…`;非 QUIC UDP 不误判。
- 回归:TCP TLS 的 SNI/JA4(①)不受影响;ClientHello 解析复用后 TCP 路径测试全绿。
- 全程 Swift Testing、零警告、双 linter 全清、8 语言、界面元素核验。

## 6. 交付与发版
spike 绿 + notes → review → 接入 → code-reviewer 清零 → 测试全绿 + 界面核验 → 文档(README ×8 "HTTP/3/QUIC 可见性" bullet、CHANGELOG、NOTICE 若需、DocC 符号注释)→ 版本 1.3.0/32(project.yml 两处 info.properties + settings.base,xcodegen 校验)→ 提交(无 Claude 署名)→ push → `gh workflow run Release -f version=v1.3.0` → appcast(sparkle:version=32)→ 本地 Developer-ID 安装(用已修好的 sign.sh,`TIMESTAMP=--timestamp=none`)。

## 7. 自审清单
- 无 TBD;范围单一(QUIC Initial 被动解析,不碰 Handshake/1-RTT)。
- 复用 ① 管道(DissectedPacket.hostnames/tlsClientFingerprint、JA4 核心、FingerprintStore)——不重复造轮子;ClientHello 解析提炼为 TCP/QUIC 共用(DRY)。
- 所有 QUIC 常量对 RFC 9001 核对;Appendix A 为回归门;AES-ECB 仅头保护一处用 CommonCrypto。
- 命名一致:`QUICInitial`/`QUICInitialCrypto`/`QUICCryptoFrames`/`QUICDissector`/`JA4.Transport.quic`。
