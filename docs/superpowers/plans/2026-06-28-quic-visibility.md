# QUIC / HTTP-3 Visibility — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (or subagent-driven-development). Steps use `- [ ]`. Spike-first: Phase 0 is a pure `swift test` core validated against RFC 9001 Appendix A; no app target, no release, until green.

**Goal:** Passively parse QUIC Initial packets to surface SNI / ALPN / QUIC version per app and a QUIC JA4 fingerprint, fixing the "UDP 443 = QUIC" guess. Ship as 1.3.0 (build 32).

**Architecture:** A pure QUIC-Initial decryption core in `MatrixNetDissection` (HKDF + AES-128-GCM via CryptoKit; AES-128-ECB header protection via CommonCrypto), reusing feature ①'s ClientHello parser + JA4 core with `transport: .quic`. It plugs into the existing `DissectedPacket.hostnames` / `.tlsClientFingerprint` pipeline — zero new attribution/persistence plumbing.

**Tech Stack:** Swift 6, Swift Testing, CryptoKit (HKDF<SHA256>, AES.GCM), CommonCrypto (AES-ECB single block), existing dissection.

## Global Constraints
Same as ① (Apache-2.0; English public docs/DocC, Chinese internal; Swift 6 strict; zero warnings; swiftlint --strict + swiftformat --lint clean; no Claude authorship; one SharedModelContainer; 8-language localization; version source = project.yml two info.properties + settings.base; **all QUIC constants verbatim from RFC 9001, never guessed**). JA4 only (no JA4S/X). QUIC data only exists with packet capture (no NStat fallback).

## RFC 9001 Appendix A reference vectors (the Phase 0 gate — verbatim)
- QUIC v1 initial salt: `38762cf7f55934b34d179ae6a4c80cadccbb7f0a`
- Sample client DCID: `8394c8f03e515708`
- `initial_secret = HKDF-Extract(salt, dcid)` → begins `7db5df06e7a69e432496adedb0085192…`
- `client_initial_secret = HKDF-Expand-Label(initial_secret,"client in","",32)` → begins `c00cf151ca5be075ed0ebfb5c80323c4…`
- `key = HKDF-Expand-Label(cis,"quic key","",16) = 1f369613dd76d5467730efcbe3b1a22d`
- `iv  = HKDF-Expand-Label(cis,"quic iv","",12)  = fa044b2f42a3fd3b46fb255c`
- `hp  = HKDF-Expand-Label(cis,"quic hp","",16)  = 9f50449e04a0e810283a1e9933adedd2`
- Header protection: `sample = d1b1c98dd7689fb8ec11d242b123dc9b`; `mask = AES-ECB(hp, sample) → 437b9aec36…`; unprotected first byte `c3` (pn len 4), pn = `00000002`; unprotected header = `c000000001088394c8f03e5157080000449e7b9aec34`.
- Decrypted CRYPTO frame (ClientHello) begins `060040f1010000ed0303…` and contains SNI `example.com` (`6578616d706c652e636f6d`), ALPN `alpn`, supported_versions TLS1.3 (`002b000302 0304`).
- AEAD = AES-128-GCM; header protection cipher = AES-128-ECB.
- HKDF-Expand-Label per RFC 8446 §7.1: label = `"tls13 " + label`, struct = uint16(length) + uint8(labelLen) + label + uint8(0).

## File Structure
| File | Responsibility |
| --- | --- |
| `Sources/MatrixNetDissection/QUICVarint.swift` (Create) | QUIC variable-length integer decode. |
| `Sources/MatrixNetDissection/QUICInitial.swift` (Create) | Long-header parse → version, DCID, SCID, token, length, pnOffset. |
| `Sources/MatrixNetDissection/QUICInitialCrypto.swift` (Create) | HKDF key/iv/hp derivation; AES-ECB header-protection mask (CommonCrypto); AES-GCM payload decrypt (CryptoKit). |
| `Sources/MatrixNetDissection/HKDFExpandLabel.swift` (Create) | TLS1.3 HKDF-Expand-Label helper (shared). |
| `Sources/MatrixNetDissection/QUICCryptoFrames.swift` (Create) | Scan/reassemble CRYPTO frames (0x06) → ClientHello bytes; skip PADDING/PING/ACK. |
| `Sources/MatrixNetDissection/QUICDissector.swift` (Create) | Orchestrate → DissectionNode + serverName + alpn + JA4(quic). |
| `Sources/MatrixNetDissection/TLSDissector.swift` (Modify) | Extract `parseClientHello` into a reusable entry callable by QUIC (DRY). |
| `Sources/MatrixNetDissection/PacketDissector.swift` (Modify) | UDP+QUIC → QUICDissector; return hostnames + fingerprint via existing `ApplicationLayer`. |
| `Sources/MatrixNetModel/OverviewStats.swift` (Modify) | Replace UDP-443 QUIC heuristic with real QUIC detection. |
| `App/Sources/*` (Modify) | QUIC layer fields show in Packets inspector; connection inspector JA4 section already covers `q…`. |
| `docs/superpowers/notes/quic-spike.md` (Create) | Real-capture validation notes. |
| Localization + README ×8 + CHANGELOG + NOTICE + DocC (Modify) | New strings + HTTP/3 feature docs. |

---

# Phase 0 — QUIC Initial decryption core (spike, pure `swift test`, no app, no release)

### Task 0.1: QUIC varint
- [ ] Failing test `QUICVarintTests`: decode 1/2/4/8-byte forms (`0x25`→37; `0x7bbd`→15293; etc. per RFC 9000 A.1), returns (value, bytesConsumed).
- [ ] Run → fail. Implement `QUICVarint.decode(_:at:) -> (UInt64, Int)?` (top 2 bits = length 1/2/4/8). Run → pass. Commit.

### Task 0.2: HKDF-Expand-Label
- [ ] Failing test `HKDFExpandLabelTests`: derive `key`/`iv`/`hp` from `client_initial_secret` (Appendix A) and assert == `1f369613…`/`fa044b2f…`/`9f50449e…`. Also `client_initial_secret` from `initial_secret` via label `client in`.
- [ ] Run → fail. Implement `HKDFExpandLabel.derive(secret:label:length:) -> [UInt8]` using `HKDF<SHA256>.expand(pseudoRandomKey:info:outputByteCount:)` with the RFC 8446 info struct (`"tls13 "+label`). Run → pass. Commit.

### Task 0.3: Initial secret derivation (HKDF-Extract)
- [ ] Failing test: `QUICInitialCrypto.initialSecrets(dcid: 0x8394c8f03e515708)` → key/iv/hp == Appendix A values.
- [ ] Run → fail. Implement: `HKDF<SHA256>.extract(inputKeyMaterial: dcid, salt: quicV1Salt)` → `client_initial_secret` (label `client in`) → key/iv/hp. Run → pass. Commit.

### Task 0.4: Header protection (AES-128-ECB via CommonCrypto)
- [ ] Failing test: `QUICInitialCrypto.headerProtectionMask(hp: 9f50449e…, sample: d1b1c98d…)` first 5 bytes == `437b9aec36`.
- [ ] Run → fail. Implement AES-128-ECB single-block via `CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, …)` on the 16-byte sample; mask = first 5 bytes. Run → pass. Commit. (Only place CommonCrypto is used; wrap in one function.)

### Task 0.5: Long-header parse
- [ ] Failing test `QUICInitialTests`: parse the Appendix A unprotected header `c000000001088394c8f03e5157080000449e…` → version `0x00000001`, dcid `8394c8f03e515708`, isInitial true, pnOffset correct.
- [ ] Run → fail. Implement `QUICInitial.parse(_:) -> QUICInitial?` (first byte high bit + type bits; version; DCID/SCID len+bytes; token varint+bytes; length varint; pnOffset). Run → pass. Commit.

### Task 0.6: AES-GCM payload decrypt + end-to-end
- [ ] Add the full Appendix A.2 protected client Initial packet as a hex fixture (`QUICTestVectors.swift` in tests, extracted from RFC 9001).
- [ ] Failing test: full pipeline — parse header → derive keys → remove header protection (recover pn=2) → AES-GCM decrypt (nonce = iv XOR pn; AAD = header through pn) → plaintext begins `060040f1010000ed…`.
- [ ] Run → fail. Implement `decryptPayload(...)` using `AES.GCM.open` with reconstructed nonce + AAD (note: GCM tag is last 16 bytes of the protected payload). Run → pass. Commit.

### Task 0.7: CRYPTO frame reassembly + ClientHello extraction
- [ ] Failing test `QUICCryptoFramesTests`: from the decrypted plaintext, reassemble CRYPTO (0x06) frames (skip 0x00 PADDING) → ClientHello bytes; feed to the reusable ClientHello parser → SNI `example.com`, first ALPN `alpn`, JA4 starts `q13d`.
- [ ] Run → fail. Implement `QUICCryptoFrames.reassemble(_:) -> [UInt8]?` (collect (offset,length,data), sort by offset, concat contiguous). Refactor `TLSDissector.parseClientHello` into a reusable `ClientHelloParser` callable by both TCP and QUIC. Run → pass. Commit.

### Task 0.8: QUICDissector + real-capture spike notes
- [ ] Failing test: `QUICDissector.dissect(initialPacketBytes, destination:)` → node shortName "QUIC", serverName example.com, clientFingerprint `q13d…`.
- [ ] Implement orchestration. Run → pass. Commit.
- [ ] Capture a real QUIC Initial (`tcpdump -i any -w` while loading an HTTP/3 site, or app PKTAP), decrypt, confirm SNI + `q…` JA4; write `docs/superpowers/notes/quic-spike.md`. Commit.

**Phase 0 gate:** `swift test --filter MatrixNetDissectionTests` green incl. all RFC vectors; lint clean; no app touched. Review before Phase 1.

---

# Phase 1 — Integrate into the dissector
### Task 1.1: PacketDissector UDP→QUIC
- [ ] Failing test `PacketDissectorQUICTests`: a UDP/443 datagram carrying the Appendix A Initial → `DissectedPacket.hostnames` contains (destIP, example.com), `.tlsClientFingerprint` starts `q`, protocolPath ends "QUIC".
- [ ] Run → fail. In `parseApplicationLayer`, for UDP with (port 443 or QUIC long-header initial), call `QUICDissector` and return `ApplicationLayer(node, hostnames, fingerprint)`. Run → pass. Commit.
### Task 1.2: OverviewStats real QUIC
- [ ] Update protocol-mix to count QUIC only when a QUIC layer was dissected (not bare UDP-443). Test + commit.

---

# Phase 2 — App, docs, release 1.3.0
### Task 2.1: UI verification
- [ ] Build app (`xcodegen generate && xcodebuild … build`). QUIC layer fields (Version/SNI/ALPN/JA4) appear in Packets inspector; connection inspector JA4 section shows `q…` for HTTP/3 apps; HTTP/3 connections now show real host. Launch-smoke (Release, Developer-ID signed via fixed sign.sh) — no crash, UI renders. Commit any fixes.
### Task 2.2: Localization + docs + version + release
- [ ] Add any new UI strings to the catalog with all 7 translations; `python3 scripts/check-localizations.py` passes.
- [ ] README ×8 bullet ("HTTP/3 / QUIC visibility — passive SNI/ALPN/version + per-app JA4, no decryption"); CHANGELOG `## [1.3.0]`; DocC symbol comments; NOTICE (QUIC handled via system crypto — no new third-party).
- [ ] project.yml two info.properties + settings.base → 1.3.0 / 32; `xcodegen generate`; verify plist.
- [ ] `swift test` + `swiftlint --strict` + `swiftformat --lint` + localization all green; **界面元素核验通过**.
- [ ] Commit (no Claude authorship), push, `gh workflow run Release -f version=v1.3.0`, verify appcast sparkle:version=32, local Developer-ID install.

**Phase 2 gate:** all tests green, zero warnings, 8 languages, CI notarized release + appcast correct, local install confirmed.

## Self-Review
- Spec coverage: Initial decrypt (0.1–0.6), CRYPTO/ClientHello (0.7), QUIC JA4 reuse (0.7–0.8), integration via existing pipeline (1.1), heuristic replacement (1.2), UI/docs/release (2.x). ✓
- DRY: ClientHello parser + JA4 core reused across TCP/QUIC; attribution/persistence pipeline reused from ①. ✓
- No guessing: every QUIC constant cited from RFC 9001 Appendix A; Appendix A is the regression gate. ✓
- Names consistent: QUICVarint/QUICInitial/QUICInitialCrypto/HKDFExpandLabel/QUICCryptoFrames/QUICDissector/ClientHelloParser/JA4.Transport.quic. ✓
