# Changelog

All notable changes to MatrixNet are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Status:** Phase 1. Until version `1.0.0`, public interfaces and behavior may
> change without notice.

## [Unreleased]

## [0.1.2] - 2026-06-27

### Added
- **Sortable, resizable, persistent table columns** across the Connections,
  History, and Packets tables: click any header to sort, drag dividers to
  resize, reorder or hide columns — the layout is remembered across launches.

### Fixed
- **No more "wants to access data from other apps" prompt on every launch.** The
  shared App Group is now prefixed with the Team ID, which macOS does not gate
  behind that per-launch privacy prompt for a Developer ID app — so the app and
  its widget share live metrics silently.

### Changed
- The widget reload nudge is rate-limited so WidgetKit's refresh budget is not
  exhausted (which had left the widget showing stale, empty data).

## [0.1.1] - 2026-06-27

### Fixed
- **Top Talkers and the widget now show real per-app traffic.** They summed the
  live snapshot's instantaneous per-connection byte counters, which the kernel
  reports as 0 for the many idle keep-alive sockets and for proxied/loopback
  flows, so every app showed `0 B`. Traffic is now accumulated per app from the
  same positive byte deltas as the session totals (surviving connection close),
  so the figures stay meaningful.
- **Widget no longer appears frozen.** The app nudged WidgetKit to reload every
  couple of seconds, exhausting the system reload budget so later refreshes were
  dropped; reloads are now throttled.

## [0.1.0] - 2026-06-27

First Developer ID-signed, notarized build.

### Added
- **In-app auto-update** via Sparkle, with EdDSA-signed updates served from the
  GitHub "latest release" appcast; on-demand and daily background checks.
- **Automatic GeoIP refresh** — the country database updates in the background
  from the monthly DB-IP dataset (published by a scheduled CI job), preferring a
  downloaded copy over the bundled one.
- **Localization into 8 languages** — English plus Simplified & Traditional
  Chinese, Japanese, Korean, French, German, and Spanish — across the app and the
  widget, following the macOS system language, with CI enforcing full translation
  coverage.
- **Live throughput & session totals** — per-direction byte rate plus monotonic
  session totals that survive connection close, surfaced in the Overview, menu
  bar, and widget.
- **Connection monitoring** — system-wide, per-app live connection tracking via
  the kernel `NetworkStatistics` mechanism: process attribution, 5-tuple, remote
  host/IP, byte and packet counters, and connection lifecycle. Requires no
  privilege or special authorization, and coexists with any VPN/proxy/filter.
- **Reverse-DNS hostnames**, **address-scope classification** (private/public/
  loopback/…), and **country geolocation with flags** (DB-IP, CC-BY).
- **Desktop widget** (WidgetKit, small / medium / large) showing active and total
  connection counts, up/down throughput, session totals, and the top talking apps,
  refreshed live from the shared App Group container.
- **Deep packet capture** — raw, per-packet capture via PKTAP/BPF where each
  packet carries its originating PID, performed by a minimal, capture-only
  privileged helper registered through `SMAppService`. A single unfiltered pktap
  clone covers every interface at once (`en0`, `utun*`, `lo0`). The Packets view
  surfaces capture errors and offers a one-click helper reinstall (the
  registered daemon otherwise keeps running an older helper binary after an
  app update).

- **Protocol dissection** — parsers for Ethernet, IPv4, IPv6, TCP, UDP, ICMP,
  DNS, TLS (handshake / SNI / certificate), and HTTP/1.1, with Follow Stream
  reassembly. Built test-first and hardened against malformed input.

- **Per-app attribution and correlation** — fuses the connection and packet
  sources by 5-tuple and PID so every captured packet is tied back to its owning
  process and connection.
- **DNS enrichment** — maps observed IPs back to hostnames from captured DNS
  traffic to enrich connection records.
- **pcapng export** — export selected packets or whole sessions to pcapng,
  including per-packet process metadata, for interoperability with Wireshark.

- **Connection history** — local persistence of past connections for later
  review.
- **Project foundation** — modular Swift Package core (`MatrixNetModel`,
  `MatrixNetDissection`, `MatrixNetPcap`, `MatrixNetCapture`, `MatrixNetStore`,
  `MatrixNetGeoIP`, `MatrixNetXPC`), Swift 6 strict concurrency, the Swift
  Testing suite (with ThreadSanitizer-backed concurrency coverage), SwiftLint /
  SwiftFormat configuration, and the open-source documentation set.

### Notes
- Phase 1 is intentionally **passive**: there is no firewall, traffic blocking,
  or HTTPS/TLS decryption. Those are tracked on the
  [roadmap](./README.md#roadmap) for later phases.

[Unreleased]: https://github.com/MatrixReligio/MatrixNet/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.2
[0.1.1]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.1
[0.1.0]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.0
