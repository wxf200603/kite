# Kite

> Local-first AI agent, fused from Kelivo & Operit capabilities.

Kite is an Android (and desktop) AI assistant that runs as much as possible on
the device itself: local LLM inference via llama.cpp, sandboxed JavaScript
tool packages via QuickJS, an on-device memory layer, and a lightweight MCP
tool orchestration layer. Remote providers remain optional.

## Features

- **Local llama.cpp inference** — ported JNI bindings, model mmap pre-warm,
  background model release, token-stream smoothing.
- **QuickJS + ToolPkg sandbox** — run ad-hoc JS or load signed `.toolpkg`
  packages with per-call file / network permission gating and a native
  permission audit log.
- **Controlled network capability** — ToolPkg `network` capability is bridged
  through Dart's HTTP client (no direct socket access), gated by a global
  settings toggle and an optional domain whitelist.
- **Local MCP call statistics** — per-tool call count, average duration, and
  failure count for `mcp_native_llama`, `mcp_native_js`, and ToolPkg calls,
  stored locally in a 1000-entry ring buffer.
- **Host backend abstraction** — ToolPkg exec/read/write can target a normal
  shell, a root shell (`su`), or a PRoot environment backed by the Kelivo
  rootfs.
- **Workflow orchestration** — simple step-list state machine with retry and
  failure strategies built on the existing MCP tool chain.
- **Memory enhancement** — automatic summarization and keyword-vector recall
  over the existing conversation database (no new tables).
- **Configuration import / export** — full settings backup and restore through
  `BusinessPreferences`.

## Skeleton vs full build

Kite ships native libraries (`libllama.so`, `libquickjs.so`) as precompiled
artifacts that are **not** committed to the repository.

| | Skeleton (CI) | Full (local) |
| --- | --- | --- |
| Native `.so` | Excluded | Required |
| Local inference / ToolPkg | No | Yes |
| How to build | `gh workflow run build-skeleton.yml --ref main` | Android Studio or `flutter build apk` |

See [README-CI.md](./README-CI.md) and [TRAE_BUILD.md](./TRAE_BUILD.md) for the
full build instructions.

## Core design principles

- **Lazy loading** — every optional subsystem (llama.cpp, QuickJS/ToolPkg,
  workflow, memory enhancement) is fully inert until its toggle is enabled.
  When off there is zero initialization overhead.
- **Default off** — all capabilities that touch the host (file access, network,
  root exec, accessibility) are disabled by default and must be explicitly
  granted per package or per session.
- **No telemetry** — Kite does not phone home. No crash reporting, no usage
  analytics, no remote configuration. All statistics (e.g. MCP call timing) are
  stored on-device only and never uploaded.
- **Minimum permission** — the manifest declares only the permissions the app
  actually uses; dangerous capabilities are gated behind runtime user consent.
- **No new database tables** — all configuration and statistics live in the
  existing `BusinessPreferences` key-value store.

## Hard constraints

- `applicationId`: `com.psyche.kelivo` (unchanged)
- Flutter package name: `Kelivo` (unchanged; only the user-facing brand is Kite)
- `abiFilters`: `arm64-v8a` only
- No boot auto-start, no persistent services beyond the existing foreground
  generation service, no wakelock keep-alive, no integrity checks, no telemetry.

## License

See the in-app About page / license link.
