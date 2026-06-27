# Changelog

All notable changes to MatrixNet are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Status:** Phase 1. Until version `1.0.0`, public interfaces and behavior may
> change without notice.

## [Unreleased]

## [0.1.7] - 2026-06-27

### Fixed
- **History "Seen" count is now per-sample.** Observations sharing the same
  app + host + protocol within one 5-second sample are collapsed, so the count
  reflects how many samples a connection appeared in — no longer inflated by how
  many concurrent sockets an app holds to that host. Per-host bytes are now the
  sum across those sockets instead of the largest single one.
- **History detail timestamps** use a consistent format (both "First Seen" and
  "Last Seen" now show seconds).

### Changed
- **Small widget throughput** is laid out as two stacked full-width rows so both
  rates render at one consistent size instead of one shrinking to fit.

## [0.1.6] - 2026-06-27

### Fixed
- **Widget throughput no longer wraps.** The rate figures are now constrained to
  a single line (scaling down to fit) and the two readouts share the small
  widget's width evenly, so values like `10.4 KB/s` stay on one line.
- **Toolbar throughput is inset** from its rounded background so the first label
  no longer hugs the left edge.

## [0.1.5] - 2026-06-27

### Added
- **Threat-IP awareness.** Remote addresses on a public threat-intelligence
  blocklist are flagged with a ⚠️ badge in the Connections list and detail
  inspector, and the desktop widget shows a count of active connections reaching
  flagged addresses. The list is built from the public-domain
  [IPsum](https://github.com/stamparm/ipsum) aggregate (level 3 — addresses on
  three or more independent blocklists), refreshed in the background from a
  CI-published rolling release. It is **advisory only** — MatrixNet labels, it
  never blocks — and the app only ever contacts its own release asset, never the
  upstream feeds.
- **Client/server role.** A new Role column infers, from the ports, whether the
  local host is the client (it dialed out) or the server (it accepted a
  connection) of each flow.
- **Proxy and VPN/tunnel labelling.** Connections whose remote is your
  configured or local proxy are marked “→ proxy”, and processes that carry other
  apps' traffic (NetworkExtension VPN/tunnel/proxy engines) are badged, so it is
  clear when traffic is being relayed.
- **Packet filtering.** The Packets view gains a search field to filter the live
  packet list by process, protocol, or address.

### Changed
- **Steadier readouts.** The toolbar and menu-bar throughput figures no longer
  jump around as the numbers change width, and the widget's throughput/total
  figures stay on one line instead of wrapping.
- Long application and host names that are truncated in tables now show their
  full value on hover, and the History “Seen” column explains what its count
  means.

## [0.1.4] - 2026-06-27

### Added
- **History detail and time-range filter.** Select a history row to see its
  full detail (app, remote, protocol, inbound/outbound bytes, sightings, first/
  last seen) in an inspector, and filter the list to the last hour, 24 hours,
  7 days, or all time.

## [0.1.3] - 2026-06-27

### Added
- **Real per-connection and per-app byte counts from packet capture.** While the
  packet helper is capturing, each packet is attributed to its connection at the
  data-link layer, so the Connections, History, and Top Talkers views show true
  byte totals even for traffic a transparent proxy/VPN hides from
  `NetworkStatistics` (where per-connection counters read 0).

### Fixed
- **Packet timestamps are now per-packet** (microsecond `bh_tstamp`) instead of
  one shared time per read batch, and the Packets time column shows
  `HH:mm:ss.microseconds` — so packets within the same second are distinguishable.
- **Help menu no longer reports "No help found."** It now links to the project on
  GitHub and to the issue tracker.

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

[Unreleased]: https://github.com/MatrixReligio/MatrixNet/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.7
[0.1.6]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.6
[0.1.5]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.5
[0.1.4]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.4
[0.1.3]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.3
[0.1.2]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.2
[0.1.1]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.1
[0.1.0]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.0
