# 功能 D/E:pcap 进程注释 + 用量 CSV/JSON 导出 — 设计文档

> 状态:定稿(自主模式)。语言:本文件中文;面向用户/开源字符串、注释、DocC 用英文。这是 4 个高价值功能的最后一项。

## 1. 目标
- **D(桥接)**:让导出的 pcapng **每个包带进程名 + PID**(写成 pcapng `opt_comment`),Wireshark 4.x 能显示——"在这里抓、拿去 Wireshark 分析",且我们的导出**自带 App 归属**(Wireshark 本身要到 4.6 才会读 PKTAP)。
- **E(报表)**:用量页一键导出当前时间段为 **CSV / JSON**,供对账、报销、审计。

## 2. 现状(已探查)
- pcap 导出**已存在**:`PacketsView.exportPcap()` → `NSSavePanel` → `PcapNGWriter`,但写的是裸包、**无注释**。
- `PcapNGWriter.packet(_:)` 的 EPB(Enhanced Packet Block)**当前不写任何 options**(data 后直接 trailing length)。
- `CapturedRecord{timestampMicros, originalLength, data}` 无 comment 字段。
- `PacketRow` 有 `processName`、`pid`,exportPcap 可取。
- 用量:`AppModel.usageRows(for:)` 返回 `[UsageRow{periodStart,app,host,country,bytesIn,bytesOut}]`;UsageView 已有 period。无任何导出。

## 3. 设计

### 3.1 D — pcapng 包注释(MatrixNetPcap,改)
- `CapturedRecord` 增可选 `comment: String?`(默认 nil,旧调用兼容)。
- `PcapNGWriter.packet(_:)`:当 `comment` 非空,在 padded data 之后、trailing length 之前写 **EPB options**:
  - `opt_comment`(code 1):`u16(1) u16(byteLen) <utf8 bytes> pad32`。
  - `opt_endofopt`(code 0):`u16(0) u16(0)`。
  - 重算 `totalLength` = 32 + paddedData + optionsLen(含 endofopt 4 字节)。无 comment 时与现状逐字节一致(不写 options)。
- `PcapNGReader`:若已解析 EPB,**可选**增解析 opt_comment 回 `CapturedRecord.comment`(便于 round-trip 测试);若 reader 不解析 options,测试改为校验写出字节包含注释 + 长度自洽。
- `PacketsView.exportPcap()`:每包 `comment = "\(packet.processName) (pid \(packet.pid))"`(pid>0 时;否则仅进程名;空则 nil)传入 `CapturedRecord`。

### 3.2 E — 用量 CSV/JSON 导出(MatrixNetModel 纯编码器 + UI)
- `UsageExport.swift`(MatrixNetModel,纯):
  - `static func csv(_ rows: [UsageRow]) -> String`:表头 `app,country,host,bytes_in,bytes_out,period_start`;字段做 CSV 转义(含逗号/引号/换行的值用双引号包裹、内部引号翻倍);`period_start` 用 ISO-8601(`ISO8601DateFormatter`,UTC,稳定可测)。行按 app 再按总字节排序(稳定输出)。
  - `static func json(_ rows: [UsageRow]) -> String`:`Codable` DTO 数组(app/country/host/bytesIn/bytesOut/periodStart ISO-8601),`JSONEncoder`(`.sortedKeys` + `.prettyPrinted`)。
  - 纯、确定性、TDD(固定 rows + 固定日期断言精确字符串/字段)。
- `UsageView`:工具栏/顶部加"Export"菜单(CSV / JSON),`NSSavePanel`(`usage-<period>.csv|json`),写入 `UsageExport.csv/json(rows)`。空数据禁用。

## 4. 错误处理与边界
- CSV 注入防护:本期不加 `=`/`+`/`-`/`@` 前缀转义(用量字段是应用名/域名/国家码/数字,风险低);仅做标准 CSV 引号转义。若日后导出用户可控文本再加固。
- pcap 注释 UTF-8 编码;长进程名不截断(pcapng option 长度 u16,足够)。
- 写文件失败 `try?` 静默(用户取消 NSSavePanel 即返回);不崩溃。
- 大量用量行:CSV/JSON 在内存拼接,行数有界(时间段 × Top-N),可接受。

## 5. 测试(TDD)
- `PcapNGWriterTests`(MatrixNetPcap):
  - 无 comment → 字节与现状一致(EPB 长度 = 32+paddedData)。
  - 有 comment → EPB 含 opt_comment(code 1)+ 注释字节 + opt_endofopt(0,0),且 block totalLength 头尾一致、4 字节对齐。
  - (若 reader 解析 options)写后读回 `comment` 相等。
- `UsageExportTests`(MatrixNetModel):
  - csv 表头 + 一行精确匹配(含 ISO 日期);含逗号/引号的 host 正确转义;空 rows → 仅表头。
  - json 解析回 DTO 字段正确;空 rows → `[]`。
- UI 不单测。

## 6. 本地化与开源文档
- 新 UI 字符串:"Export"(可能已存在)、"CSV"、"JSON"(品牌词/格式名,可与英文同源——但仍加入目录避免回退)、菜单项/SavePanel 提示如需。→ 8 语言;check-localizations 通过。
- README:更新数据包导出条目提"带进程注释的 pcapng";新增用量"CSV/JSON 导出"提及(8 语言)。CHANGELOG 0.1.25。

## 7. 发版:0.1.25 / build 26,流程同前。

## 8. 阶段 review 关:设计→[review]→计划→[review]→实现→[code-reviewer]→测试→[review]→文档/本地化→[review]→发版→[appcast+本地验证]。
