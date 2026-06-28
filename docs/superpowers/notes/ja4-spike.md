# JA4 协议核心 spike 验证笔记(2026-06-28)

功能 ① 的第 0 阶段:在接入 app 之前,先把 JA4 计算与 ClientHello 解析在纯模块里验证正确,降低对 app 版本的影响。

## 验证 1:算法权威性(FoxIO 规范向量,自动回归)

`Tests/MatrixNetDissectionTests/JA4Tests.swift` 对 FoxIO `technical_details/JA4.md` 的官方 worked example 做逐段回归:

- 输入:TCP/TLS1.3、有 SNI、15 ciphers、16 extensions、ALPN `h2`,以及规范给出的 cipher / extension / signature_algorithms 列表。
- 期望(权威基准):`t13d1516h2_8daaf6152771_e5627efa2ab1`。
- 结果:`JA4.string(...)` 逐字符相符;`rawB`/`rawC` 的哈希前中间串也单独断言(GREASE 剔除、升序排序、JA4_c 剔除 SNI+ALPN 且 sig_algs 不排序、计数 cap 99、SNI `d`/`i`、ALPN 首尾/`00`/`99`)。

> 这是算法正确性的**权威门**——SHA256 接线、排序、GREASE、计数规则全部据此验证。

## 验证 2:解析器在真实 wire 字节上的鲁棒性(openssl 实抓)

由于 CI/沙箱无法做内核级抓包(PKTAP 需特权 helper、真机),用 `openssl s_client -msg` 抓一条真实 ClientHello 做交叉验证:

```bash
echo | openssl s_client -connect cloudflare.com:443 -alpn h2,http/1.1 -msg -tls1_3
# 取 ">>> TLS 1.3, Handshake [...], ClientHello" 后的 handshake 字节(01 00 05 c9 ...,共 1485=0x05CD 字节)
# 重建 TLS record:[0x16,0x03,0x01] + u16(0x05CD) + handshake,喂给 TLSDissector.dissect
```

- openssl 版本:OpenSSL 3.6.2(homebrew)。
- 计算结果:**`serverName = cloudflare.com`**,**`JA4 = t13d0311h2_55b375c5d22e_3217d83565aa`**。
- JA4_a 逐字段手工交叉验证(全部与 hex 中可见字段吻合):
  - `t` = TCP
  - `13` = TLS 1.3(取自 supported_versions 扩展 `00 2b … 03 04`,而非 legacy record version 0x0303 —— 验证了"版本取 supported_versions 最大值"这条规则)
  - `d` = 有 SNI(`cloudflare.com`)
  - `03` = 3 个 cipher(`1302,1303,1301`,openssl 不发 GREASE cipher)
  - `11` = 17 个扩展
  - `h2` = 首个 ALPN 值

> 这验证了解析器能从**真实**字节正确抽取 SNI / 版本(走 supported_versions)/ cipher 数 / ALPN。b/c 段是已被验证 1 证明正确的 SHA256 计算。

## 结论

- 算法(对 FoxIO 权威向量)与解析器(对真实 ClientHello)均验证通过 → **可安全接入 app(第 1–4 阶段)**。
- 已知边界(设计已涵盖,非缺陷):
  - JA4 的 b/c 哈希会随客户端 TLS 库版本演进而变化——这正是指纹的本质,识别表需周期维护。
  - ECH 普及后 inner ClientHello 加密,JA4 的 SNI 段会退化为 `i`、区分度下降;当前采用率极低,优雅降级。
  - ALPN 非 ASCII 字节按 FoxIO 参考实现 `ja4.py` 输出 `99`(与 JA4.md 散文的 hex 描述不同,真实 ALPN 永远是可打印 ASCII,常见路径无歧义)。
- 临时 spike 测试(读取 scratchpad 抓包文件)已删除;权威回归留在 `JA4Tests.swift`(`JA4ParseTests.swift` 另用手工构造的真实 wire 格式 ClientHello 夹具回归解析器,含 GREASE/supported_versions/ALPN/sig_algs)。
