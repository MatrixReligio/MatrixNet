# Security Policy

MatrixNet is a network monitoring and packet analysis tool that runs with a
privileged capture component and parses untrusted network data. We take its
security seriously and appreciate responsible disclosure.

> **Note:** MatrixNet is an early-stage **Phase 1** project. The version table
> below will be expanded as releases are published.

## Reporting a vulnerability

**Please do not report security issues through public GitHub issues, pull
requests, or discussions.**

Instead, report privately by email to:

**[contact@matrixreligio.com](mailto:contact@matrixreligio.com)**

Please include, where possible:

- A description of the issue and its potential impact.
- The component affected (e.g. the privileged helper, a specific protocol
  dissector, pcapng parsing, the XPC interface, the app).
- Steps to reproduce, a proof of concept, and/or a sample capture or input that
  triggers the issue.
- The MatrixNet version, macOS version, and hardware (Apple Silicon / Intel).

If you would like to encrypt your report, mention it in an initial email and we
will provide a key.

### What to expect

- **Acknowledgement** of your report within **3 business days**.
- An **initial assessment** within **10 business days**, including whether we
  have reproduced the issue and a severity estimate.
- Ongoing updates as we work on a fix, and coordination with you on a disclosure
  timeline. We aim to release a fix for confirmed high-severity issues
  promptly.
- Credit for your discovery in the release notes, if you wish.

We ask that you give us a reasonable opportunity to address the issue before any
public disclosure.

## Supported versions

| Version | Supported |
|---|---|
| Phase 1 (pre-release, `main`) | ✅ Actively developed; fixes land on `main` |
| Tagged releases | ➖ None yet; this table will be updated when releases ship |

## Security design principles

MatrixNet's architecture is built to minimize attack surface. These principles
are relevant context for assessing and reporting issues:

- **Passive, read-only (Phase 1).** MatrixNet only observes traffic. It does not
  intercept, modify, block, or inject packets, and it does not sit in the network
  path. It claims no NetworkExtension, routing, or proxy slot.
- **Least privilege.** Connection monitoring runs entirely in the unprivileged
  app with no root, entitlement, or special authorization. Only raw packet
  capture requires root.
- **Isolated, minimal privileged helper.** The root helper, registered via
  `SMAppService`, does exactly one thing: capture raw packets via PKTAP/BPF. It
  performs **no protocol parsing**. All parsing of untrusted network bytes
  happens in the unprivileged main app, so a parser vulnerability cannot directly
  escalate to root.
- **Hostile-input hardening.** Protocol dissectors are designed and tested to be
  safe against malformed, truncated, and adversarial input — no crashes, no
  infinite loops, no out-of-bounds reads. The parsing suites are exercised with
  boundary cases and fuzz-style input, including under AddressSanitizer.
- **No decryption.** Phase 1 does **not** perform HTTPS/TLS interception or
  decryption. Encrypted payloads stay encrypted; only metadata (e.g. TLS
  handshake, SNI, certificate fields) is dissected.
- **Local-only processing.** All capture, dissection, and storage happen on the
  user's machine. MatrixNet has no telemetry, no account, and no network service
  of its own. It makes outbound requests only to: fetch its own dataset/update
  assets (GeoIP, threat list, Sparkle appcast) from its GitHub releases, and —
  when **"Resolve country for proxied destinations"** is enabled (on by default) —
  resolve a *proxied* flow's domain via encrypted DNS (DoH) to Cloudflare
  (`1.1.1.1`). That last one is the only case where an observed domain leaves the
  device; it fires only for proxied flows whose country is otherwise unknown, and
  can be turned off in Settings to keep MatrixNet fully on-device.
- **Verified components.** The app and helper are signed with a Developer ID and
  notarized; the helper's signing identity (Team ID + bundle identifier) is
  validated as part of registration.

## Scope

In scope: the MatrixNet app, the privileged capture helper, the XPC interface
between them, the protocol dissectors, and the pcapng read/write code.

Out of scope: vulnerabilities in third-party operating-system frameworks
themselves (please report those to the relevant vendor), and social-engineering
attacks. If you are unsure whether something is in scope, email us and ask.
