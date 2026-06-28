# QUIC Initial 解密核心 spike 验证笔记(2026-06-28)

功能 ②(QUIC/HTTP-3 可见性)第 0 阶段:在接入 app 前,先把"被动解密 QUIC Initial 包 → 取 SNI/ALPN/版本 + QUIC JA4"的整条 crypto 链在纯模块里验证正确,降低对版本的影响。

## 权威性:RFC 9001 Appendix A 官方向量(自动回归)

QUIC v1 Initial 包用**公开密钥**加密(版本固定 salt + 客户端 DCID 经 HKDF 派生,RFC 9001 §5.2),**无需任何握手机密即可被动解密**。`Tests/MatrixNetDissectionTests/` 用 RFC 9001 Appendix A 的官方样例包(DCID `0x8394c8f03e515708`)逐层回归:

- **HKDF 派生**(`QUICInitialCryptoTests`):从 DCID 派生 client key/iv/hp,断言 == RFC 值 `1f369613dd76d5467730efcbe3b1a22d` / `fa044b2f42a3fd3b46fb255c` / `9f50449e04a0e810283a1e9933adedd2`。
- **头保护**(AES-128-ECB):`AES-ECB(hp, sample d1b1c98d…)` 前 5 字节 == mask `437b9aec36`。
- **端到端解密**(`QUICDecryptTests`):对 Appendix A.2 完整受保护包(1200 字节,`QUICTestVectors`)→ 解析长头 → 派生密钥 → 去头保护(还原首字节 `c3`、pn=2)→ AES-128-GCM 解密(nonce=iv⊕pn,AAD=未保护头)→ 明文起始 `060040f1010000ed`(CRYPTO 帧 + ClientHello)。
- **CRYPTO 帧重组**(`QUICCryptoFramesTests`):按 offset 重排、跳过 PADDING → ClientHello `010000ed…`;乱序分片正确拼接。
- **端到端 dissect**(`QUICDissectorTests`):RFC 包 → `serverName == "example.com"`、`clientFingerprint` 以 `q13d` 开头(QUIC 传输前缀 `q`,复用 ① 的 JA4 核心)。

> 所有 QUIC 常量(salt、HKDF label、AEAD/头保护算法)**逐字对照 RFC 9001**,salt 录入时一个字节写反(`9a`↔`a9`)即被 HKDF 向量当场抓出并改正——印证"对权威向量回归、不凭记忆"。

## 技术要点(实现取舍)
- HKDF + AES-128-GCM 用 **CryptoKit**(`HKDF<SHA256>` / `AES.GCM`);**头保护的 AES-128-ECB CryptoKit 不暴露 → 仅此一处用 CommonCrypto**(`CCCrypt` ECB 单块),封装在 `QUICInitialCrypto.headerProtectionMask`。
- ClientHello 解析**与 TCP 路径共用**:把 `TLSDissector.clientHello(fromHandshake:)` 提炼出来,TCP(TLS record)与 QUIC(CRYPTO 重组)都喂裸 ClientHello 消息,JA4 用 `transport: .quic`(DRY)。
- 只支持 RFC 9001 v1(`0x00000001`);其余/草案版本识别为 QUIC 但不解密(salt 不同),优雅降级。Handshake/1-RTT 用真 TLS 密钥,不可见(同 TLS1.3 盲区,不碰)。

## 真实抓包验证(待集成阶段)
CI/沙箱无法做内核级 UDP 抓包(需特权 helper/真机)。真实 QUIC Initial 的交叉验证将在接入阶段经 app 自身 PKTAP 路径做(访问 HTTP/3 站点,确认解出真实 SNI 与 `q…` JA4),与 JA4 spike 同体例。RFC 9001 Appendix A 为权威回归门,已足以证明 crypto 链正确。
