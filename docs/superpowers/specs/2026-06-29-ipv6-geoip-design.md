# IPv6 GeoIP 设计 spec

> 状态:已批准(用户既定目标——消除"国家/地区"因 IPv6 无法定位导致的 undercount,已知限制)
> 日期:2026-06-29

## 背景与问题

MatrixNet 的整条地理定位链路(世界地图、Overview "国家/地区" KPI、连接行国旗、威胁国别)都汇聚到同一个入口:

```
GeoIP.country(for: IPAddress) -> String?   // 2 字母 ISO 3166-1 alpha-2
```

`GeoIPDatabase.country(for:)` 当前**仅支持 IPv4**:它取 `address.unmappedIPv4.bytes`,若不是 4 字节直接 `return nil`。`GeoIPConvert` 转换器也**显式跳过** CSV 中的 IPv6 行(含 `:` 的行)。

后果:任何走 IPv6 的目的地都定位失败 → 地图无路径、"国家/地区" KPI 偏低(undercount)、连接行无国旗。在 IPv6 普及的网络(Apple 服务、CDN、运营商 IPv6)下,这部分流量占比可观。

DB-IP Country Lite 数据集(CC-BY-4.0,已用于 IPv4)同一个 CSV 里就带 IPv6 范围:本月数据 **355,814 条 IPv4 + 345,875 条 IPv6**,几乎对等。所以数据现成,只是没被解析和查询。

## 目标

- `GeoIPDatabase.country(for:)` 对真实 IPv6 地址返回正确 ISO 国家码。
- 转换器把 CSV 的 IPv6 范围一并打进 `geoip.dat`。
- 地图 / KPI / 国旗 / 威胁国别**无需改动**即自动恢复 IPv6 定位(它们都只调用 `country(for:)`)。
- 二进制格式升级保持**前后向兼容**:旧版 app 仍能读新文件的 IPv4 段;新版 app 仍能读旧的 v4-only 文件。

## 非目标

- 不引入第二份数据源,仍用 DB-IP Country Lite。
- 不做 IPv6 子网聚合/前缀压缩优化(YAGNI;15MB 量级对桌面 app 资源与后台月更下载可接受)。
- 不改 `IPAddress` 模型(已有 `.v6(high:low:)` 表示,直接复用)。

## 架构

地理链路单一入口不变,改动集中在两个单元:

1. **`GeoIPDatabase`(MatrixNetGeoIP)** —— 查询核心:新增 IPv6 范围表 + IPv6 二分查找;解析 format v2。
2. **`GeoIPConvert`(Tools)** —— 数据构建:解析 IPv6 行,追加写入 v2 section。

下游(`GlobeView`、`OverviewStats`、`ConnectionInspector`、`ConnectionsView`、`AppModel`)零改动。

### 二进制格式 v2(追加式,前后向兼容)

当前 v1 布局(每条 IPv4 记录 10 字节):

```
[v4count: UInt32 BE]
[ start4(BE) | end4(BE) | cc[2] ] × v4count
```

v2 在 v1 的**完整布局之后追加** IPv6 段(每条 34 字节):

```
[v4count: UInt32 BE]
[ start4(BE)  | end4(BE)  | cc[2] ] × v4count      ← 与 v1 逐字节相同
[v6count: UInt32 BE]                                ← 新增
[ start16(BE) | end16(BE) | cc[2] ] × v6count       ← 新增
```

**为什么追加式兼容**:

- *旧 app 读 v2 文件*:旧 loader 读 `v4count`,断言 `bytes.count >= 4 + v4count*10`(文件更大 → 通过),只消费 `v4count` 条 IPv4 记录,**忽略尾部** IPv6 段。→ 旧 app 保留完整 IPv4 功能 + 后台自更新仍可用(`geoip-latest` 即将被月更 cron 重建为 v2,旧 app 照常读 IPv4 前缀)。
- *新 app 读旧 v1 文件*:读完 IPv4 表后 `offset == bytes.count`,无 v6 段 → v6 表为空,退化为纯 IPv4 查询(等价旧行为)。
- *新 app 读 v2 文件*:读完 IPv4 表后 `bytes.count >= offset + 4`,继续读 `v6count` 与 IPv6 记录。

无 magic / version 字节,靠"IPv4 段长度自描述 + 尾部存在性"区分,**零破坏**。

### IPv6 查询

`country(for:)` 先 `unmappedIPv4` 归一(把 `::ffff:a.b.c.d` 折成 IPv4),再按族分派:

- `.v4(value)`:沿用现有 IPv4 `UInt32` 二分查找。
- `.v6(high, low)`:在 IPv6 表上对 `(high, low)` 做**字典序**二分(先比 high,再比 low),命中后同样过滤占位码(ZZ/XX/??)。

IPv6 表按 `(start.high, start.low)` 升序存储;比较用 `(UInt64, UInt64)` 字典序,无需 `UInt128`,与 `IPAddress.v6(high:low:)` 的 big-endian 打包一致。

### `isEmpty` 语义

`isEmpty` 改为"**两表皆空**"才为真:

- 合法的 v4-only 旧文件(v6 空)仍 `!isEmpty` → `isValidDatabase` 通过(自更新不会误拒旧文件)。
- 一个非空 v6(理论上)同样视为有效。

## 数据流(不变)

```
ClientHello/连接 → IPAddress → GeoIP.country(for:) → ISO 码
                                      ↓
        ┌─────────────┬──────────────┼───────────────┬───────────────┐
   GlobeView     OverviewStats   ConnectionRow    ThreatCountries   flag()
   (地图路径)    (国家/地区 KPI)   (国旗)          (威胁国别)        (emoji)
```

IPv6 定位修复后,这些消费点**全部自动恢复**,因为它们只依赖 `country(for:)` 的返回。

## 容量评估

- IPv6 段 ≈ 345,875 × 34 B ≈ **11.8 MB**;叠加现有 ~3.5 MB IPv4 → `geoip.dat` ≈ **15.3 MB**。
- bundle 资源 + 月更后台下载,均可接受。`release.sh` 的 `>= 1MB` 守卫继续成立(且更稳)。

## 错误处理

- 截断/损坏:`GeoIPDatabase(data:)` 任一段长度断言失败即 `return nil`(整体拒绝,同 v1)。
- 转换器:无法 `inet_pton(AF_INET6)` 的 IPv6 行跳过(同 IPv4 行的容错)。
- 占位码 ZZ/XX/??:IPv6 命中后同样返回 nil(`::/8` 等保留段在数据里标 ZZ)。

## 测试策略(TDD)

**Phase 0 纯核心 spike**(`swift test` 独立可跑,不动 app,不发版):

- format v2 round-trip:构造含 IPv4+IPv6 两段的字节,解析后双族都能查中。
- IPv6 查找:已知向量(如 `2001:4860:4860::8888` → Google;`2606:4700::` 段 → Cloudflare;按数据集真实国别断言其 ISO 码或用合成范围断言)。
- 字典序边界:`(high,low)` 跨 high 边界、low 回绕、范围端点闭区间。
- 向后兼容:v1(无尾部)文件 → IPv4 仍中、IPv6 返回 nil。
- 向前兼容:旧 loader 逻辑读 v2 仅取 IPv4(用一段单测固定 IPv4 段偏移不变)。
- IPv6 占位码 ZZ → nil。
- `isEmpty`:两段皆空才 true。
- 截断 IPv6 段 → 拒绝。

**Phase 1**:转换器对真实 CSV 产出 v2,本地断言 IPv6 计数与文件大小。

**Phase 3**:全量 `swift test`、双 linter 清、签名 smoke 截图核验地图出现 IPv6 国家、DMG 数据集核验。

## 影响文件

- 改:`Sources/MatrixNetGeoIP/GeoIPDatabase.swift`(v2 解析 + IPv6 表 + IPv6 查找 + isEmpty)
- 改:`Tools/GeoIPConvert/main.swift`(IPv6 解析 + 追加段)
- 改:`Sources/MatrixNetGeoIP/GeoIPUpdatePolicy.swift` 注释/无逻辑变更(isValidDatabase 经 isEmpty 间接生效)
- 改:`Tests/MatrixNetGeoIPTests/GeoIPDatabaseTests.swift`(IPv6 用例)
- 改:`scripts/build-geoip.sh` 注释(不再"IPv4-only")
- 改:文档 `README*`、`CHANGELOG.md`、`NOTICE`(如需)、DocC(英文)
- 版本:`project.yml` 1.6.0/37 → 1.7.0/38(MINOR=feature)

## 全局约束(继承既有)

- 开源文档/公开代码/DocC 英文;用户沟通 + 内部 spec/plan 中文。
- Swift 6 strict concurrency;Swift Testing TDD;零告警(swiftlint --strict + swiftformat --lint 清)。
- 与代理/过滤软件零冲突(纯被动)。
- 8 语言(本特性无新 UI 文案 → 大概率无 xcstrings 改动)。
- SemVer:MINOR=feature;CFBundleVersion 单调递增。
- CI 为权威公证路径;commit 不带 Claude 署名(`Jim Ho <jim.ho@matrixreligio.com>`)。
- 每阶段 review 前全量回归(含构建产物/bundle 数据集校验)。
- 本地构建用 `scripts/smoke.sh`(Developer-ID 正签),不跑 adhoc。
