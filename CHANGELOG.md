# Changelog

All notable changes to MatrixNet are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Status:** Phase 1. Until version `1.0.0`, public interfaces and behavior may
> change without notice.

## [0.1.24] - 2026-06-28

### Added
- **New-destination ("phoning home") alerts.** Opt-in, non-blocking notifications
  when a known app first reaches a country it has never reached before — Little
  Snitch's core insight without the firewall or the alert-flood. A per-app
  15-minute learning window quietly establishes each app's normal destinations
  first (so multi-country CDNs don't flood on first run), and alerts are
  rate-limited. Entirely passive and on-device; enable it in Settings → General.

### Fixed
- **The Usage tab now fills during ordinary monitoring.** It previously only
  counted packet-capture-derived bytes, so without the capture helper running it
  stayed stuck on "Gathering usage…"; usage now also accrues from passive
  connection statistics, the same source as the Overview top talkers.

## [0.1.23] - 2026-06-28

### Changed
- **Accurate hostnames from TLS SNI and DNS.** Connections, Packets, Usage, and
  the Map now show the host an app actually requested, read from the TLS
  ClientHello's Server Name Indication and from DNS answers — with no decryption
  or MITM — and preferred over reverse-DNS PTR records, which are frequently
  generic CDN wildcards. The toggle between domain names and raw IPs is unchanged.

## [0.1.22] - 2026-06-28

### Added
- **Usage tab — "where did my bandwidth go".** A new top-level tab reports the
  top apps, countries, and domains by bytes over Today / 7 days / 30 days / your
  billing cycle, with a download/upload trend chart. Usage is accumulated into
  hourly buckets kept locally (default 90 days, configurable in Settings → Data),
  so totals survive relaunch instead of resetting to zero. Select an app to scope
  the country and domain breakdowns, and set a billing-cycle reset day so the
  "Cycle" window matches your plan. Fully passive, on-device, and offline.

## [0.1.21] - 2026-06-28

### Fixed
- **Throughput chart time axis is clearer.** "Now" is pinned to the right edge
  with a stable 60-second window, and the tick labels drop the minus sign in
  favour of plain ages (`60s … 15s … now`), so they no longer collide visually
  with the y-axis baseline.
- **Throughput tooltip uses a 24-hour clock.** Hovering past midnight previously
  showed `12:10:49 AM` (rendered as "上午12:10:49" in Chinese); it now reads a
  plain, locale-independent `00:10:49`.

## [0.1.20] - 2026-06-27

### Added
- **Show domains or IPs.** A toolbar toggle (in Connections and Packets) switches
  between resolved domain names and raw IP addresses; the Packets summaries swap
  each known IP for its hostname, keeping the port. Defaults to domains, and the
  choice is shared across both views.

## [0.1.19] - 2026-06-27

### Fixed
- **Packet process names are no longer truncated to 16 characters.** PKTAP only
  carries a 16-char `comm` per packet (so "Spark Mail Helper" showed as "Spark
  Mail Helpe"); MatrixNet now resolves the full name from the packet's PID
  (matching the Connections view), falling back to the short name when the path
  isn't readable.

## [0.1.18] - 2026-06-27

### Fixed
- **Process / application names are no longer cut off** in the Packets, Connections
  and History tables. Cells now fill their column width and truncate with an
  ellipsis only when genuinely too long (full name still on hover); the Packets
  "Process" column is also wider by default.

## [0.1.17] - 2026-06-27

### Fixed
- **Overview throughput chart is clearer.** The two series are now distinct
  colors with a legend (Download blue / Upload orange), and the x-axis reads as
  relative time (`-45s` … `now`) instead of an ambiguous clock format.

## [0.1.16] - 2026-06-27

### Added
- **Drill into a country on the Map.** Click a country (in the list or on the
  globe) to see its individual connections — app, remote host:port, protocol and
  client/server role, with threat rows flagged. A back button returns to the list.

### Changed
- The Map's labels are now mode-aware: in **History** mode destinations and counts
  read as "records" rather than "active", since historical connections are not live.

## [0.1.15] - 2026-06-27

### Changed
- **The Map now fills the whole view and resizes with the window** — it is no
  longer a fixed-height card, so enlarging the window enlarges the globe.

### Added
- **Home region setting (Map).** Every arc originates from "this Mac", anchored
  at your region's centroid. Because the system region can differ from your
  physical location (e.g. a Chinese-language Mac set to the US region), a new
  General setting lets you choose the home region explicitly; it defaults to
  Automatic (system region).

## [0.1.14] - 2026-06-27

### Changed
- **The Map fills the card and looks sharper.** The world is cropped to the
  populated latitudes (the empty polar oceans are trimmed) so land fills the
  canvas, with a faint lat/long graticule behind the dots.
- **Richer Map metrics.** The toolbar now shows live ↓/↑ throughput and counts
  of countries, located connections, and threats; the destinations list gains a
  per-country connection-count bar.

## [0.1.13] - 2026-06-27

### Changed
- The menu-bar dropdown's monitoring switch now has a clear **"Monitoring"**
  label (and a tooltip) so it is obvious it pauses/resumes passive monitoring,
  instead of an unlabeled toggle.

## [0.1.12] - 2026-06-27

### Fixed
- **Background (menu-bar-only) mode no longer makes the app unreachable.** The
  Dock icon and app menu now hide only once the *last window closes* — while a
  window is open the app stays a normal app, so the menu, Settings (⌘,) and Dock
  icon remain available. Reopening from the menu bar restores them. The menu-bar
  dropdown also gains a **Settings…** entry so preferences are always reachable.

## [0.1.11] - 2026-06-27

### Added
- **Map tab — a live world globe.** A new sidebar section renders a real-world
  dotted map (from the public-domain Natural Earth 1:110m dataset, drawn entirely
  offline — no map tiles) with glowing arcs from this Mac to every country it is
  currently talking to. Node size grows with the connection count, threat
  destinations pulse red, and a side list plus hover tooltip name each
  destination. A Live/History switch and a "Threats only" filter are included.

### Fixed
- **The menu-bar item shows its icon again** alongside the live ↓/↑ rate, so it
  stays recognizable in a crowded menu bar (and findable when running Dock-less).
- **Launch at login** gains a "Manage in System Settings…" button and clearer
  wording: `SMAppService` adds the login item silently (no prompt), so this lets
  you verify it under Login Items.

## [0.1.10] - 2026-06-27

### Fixed
- **Overview throughput chart** no longer overshoots into stray loops below the
  axis — it uses monotone interpolation. It now has a **time x-axis** and a
  **hover readout**: move the pointer to see point markers and a tooltip with the
  exact ↓/↑ rates at that moment.
- **Overview "Destinations"** bars are populated again. They now rank countries by
  **active connection count** (reliable) instead of per-connection bytes, which
  the kernel reports as 0 for many sockets — leaving the bars empty.

### Changed
- Added project status badges to the README (latest release, downloads, stars,
  last commit, notarized, passive · zero-conflict, no telemetry).

## [0.1.9] - 2026-06-27

### Changed
- **Redesigned Overview into a live dashboard.** A throughput chart (Swift Charts)
  graphs the last minute of ↓/↑ rates; a richer metric strip adds session total,
  active apps, **countries reached**, **threat connections**, and **share via
  proxy**; new **Protocol mix** and **Destinations** panels break down active
  traffic; and **Top Talkers** now show each app's country flag, live connection
  count, and threat/tunnel markers.

### Fixed
- **Local, private, and loopback addresses no longer show a bogus flag.** They
  have no country, so MatrixNet now shows none instead of the "🇿🇿" missing-glyph
  boxes (placeholder country codes like `ZZ` are also rejected).

## [0.1.8] - 2026-06-27

### Added
- **Runs in the background.** MatrixNet keeps monitoring after the main window is
  closed, so the desktop widget stays up to date. A new General setting — "Run in
  background (menu bar only)" — hides the Dock icon and keeps the app in the menu
  bar.
- **Settings window** (⌘,) with General, Updates, and Data sections.
- **Launch at login.** Register MatrixNet as a login item from Settings
  (via `SMAppService`).
- **Live throughput in the menu bar.** The menu-bar title now shows the current
  ↓/↑ rate in a compact, non-jittering form.
- **Threat-connection notifications.** Optionally post a system notification when
  an active connection reaches a flagged address — advisory only (it never
  blocks), de-duplicated per app+address and rate-limited so it cannot flood.
- The Data settings show when the GeoIP and threat datasets were last checked and
  offer an on-demand refresh.

### Fixed
- **The desktop widget no longer freezes when the main window is closed.** The
  monitoring engine now runs for the whole app lifetime instead of being tied to
  the window, so the shared metrics the widget reads keep updating.

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

[0.1.20]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.20
[0.1.19]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.19
[0.1.18]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.18
[0.1.17]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.17
[0.1.16]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.16
[0.1.15]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.15
[0.1.14]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.14
[0.1.13]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.13
[0.1.12]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.12
[0.1.11]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.11
[0.1.10]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.10
[0.1.9]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.9
[0.1.8]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.8
[0.1.7]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.7
[0.1.6]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.6
[0.1.5]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.5
[0.1.4]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.4
[0.1.3]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.3
[0.1.2]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.2
[0.1.1]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.1
[0.1.0]: https://github.com/MatrixReligio/MatrixNet/releases/tag/v0.1.0
