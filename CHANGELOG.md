# Changelog

All notable changes to MatrixNet are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Status:** Phase 1 is in active development. Nothing has been released yet, so
> everything below lives under **Unreleased**. Until version `1.0.0`, public
> interfaces and behavior may change without notice.

## [Unreleased]

### Added
- **Connection monitoring** — system-wide, per-app live connection tracking via
  the kernel `NetworkStatistics` mechanism: process attribution, 5-tuple, remote
  host/IP, byte and packet counters, and connection lifecycle. Requires no
  privilege or special authorization. *(in progress)*
- **Deep packet capture** — raw, per-packet capture via PKTAP/BPF where each
  packet carries its originating PID, performed by a minimal, capture-only
  privileged helper registered through `SMAppService`. Captures the physical
  interface and active tunnels (`en0` + `utun*`) when a VPN is present.
  *(in progress)*
- **Protocol dissection** — parsers for Ethernet, IPv4, IPv6, TCP, UDP, ICMP,
  DNS, TLS (handshake / SNI / certificate), and HTTP/1.1, with Follow Stream
  reassembly. Built test-first and hardened against malformed input.
  *(in progress)*
- **Per-app attribution and correlation** — fuses the connection and packet
  sources by 5-tuple and PID so every captured packet is tied back to its owning
  process and connection. *(in progress)*
- **DNS enrichment** — maps observed IPs back to hostnames from captured DNS
  traffic to enrich connection records. *(in progress)*
- **pcapng export** — export selected packets or whole sessions to pcapng,
  including per-packet process metadata, for interoperability with Wireshark.
  *(in progress)*
- **Connection history** — local persistence of past connections for later
  review. *(in progress)*
- **Project foundation** — modular Swift Package core (`MatrixNetModel`,
  `MatrixNetDissection`, `MatrixNetPcap`, `MatrixNetCapture`, `MatrixNetStore`,
  `MatrixNetGeoIP`, `MatrixNetXPC`), Swift 6 strict concurrency, the Swift
  Testing suite (with ThreadSanitizer-backed concurrency coverage), SwiftLint /
  SwiftFormat configuration, and the open-source documentation set.

### Notes
- Phase 1 is intentionally **passive**: there is no firewall, traffic blocking,
  or HTTPS/TLS decryption. Those are tracked on the
  [roadmap](./README.md#roadmap) for later phases.

[Unreleased]: https://github.com/MatrixReligio/MatrixNet/commits/main
