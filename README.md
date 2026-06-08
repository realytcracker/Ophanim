# Ophanim

A runtime instrumentation and interception toolkit for iOS apps on Apple Silicon. Run an iOS app
natively on macOS and observe - or actively rewrite - what it does.

## What it is

Ophanim is a macOS **dynamic-analysis and security-testing** tool. It runs an iOS app natively on
Apple Silicon (macOS 12.0+) by re-signing it and hosting it as a Mac Catalyst process, then injects a
runtime into that process so you can **observe and intercept the app's behavior from the inside**:

- **Network** - HTTP(S) requests and decrypted response bodies, raw socket/DNS, Secure-Transport
  plaintext, and certificate-pinning **bypass + logging**.
- **Keychain & crypto** - `SecItem*` access and CommonCrypto (`CCCrypt`/`CCHmac`).
- **Device & privacy** - vendor/advertising IDs, location, pasteboard, App Attest / DeviceCheck,
  biometrics, and camera/mic/photos/contacts prompts.
- **Filesystem & process** - file access and jailbreak-path probes, `dlopen`/`fork`/`posix_spawn`,
  and inter-app launches.
- **Custom hooks** - swizzle any Objective-C `(class, selector)` boundary; patch overridable
  native-Swift methods at the vtable (reaching non-`@objc` Swift); or **inline-hook arbitrary machine
  code by address, symbol, module+offset, or byte signature** (reaching statically-linked / stripped /
  static-dispatch functions) - all without touching the app's code on disk.

Every hook routes through a **policy decision**: *observe* by default, or - when a rule matches -
*block*, *replace the return/response*, *delay*, or *fault*. Rules can carry a JavaScript body
(evaluated via JavaScriptCore) for **per-call** logic - a static rule replaces the same thing every
time, while a script sees each call's context (URL, headers, request body, fields) and can return a
different result per call. Captured events are written as NDJSON, plain text, and/or `os_log`, and can
be browsed in the built-in log viewer or driven over a built-in MCP server for scripted analysis.

Not every layer can intercept. **Active modification** is available for HTTP(S) responses (block /
replace body+status+headers), device & privacy values (fake vendor/ad IDs, pasteboard, `canOpenURL`),
inline-hooked functions (block / replace return / fault / delay), and any ObjC or Swift hook (block /
delay - those are void methods, so there's no return to replace). The raw plaintext layers - TLS
read/write, socket/DNS, crypto, keychain, and `dlopen`/`fork`/`posix_spawn` - are **observe-only**:
they're captured through a lock-free ring on a drain thread, so the original call has already returned
by the time the event is processed.

> **Authorized use only.** Ophanim is for analyzing software you own or are authorized to test
> (security research, app QA, CTF, reverse-engineering your own dependencies). Re-signing breaks
> server-side attestation by design, so it cannot be used to defeat licensing or impersonate a
> genuine device to a server.

## How it works

Ophanim has three parts:

| Component | What it is |
|---|---|
| **Ophanim.app** | The SwiftUI front-end: imports an `.ipa`, re-signs it, rewrites its Mach-O load commands to inject the runtime, converts it to Mac Catalyst, and manages per-app instrumentation settings + the log viewer. Also exposes an MCP server (`Ophanim --mcp`). |
| **Galgal.framework** | The injected in-process runtime. It loads into the hosted app, provides the iPad-emulation/compatibility layer, and hosts the instrumentation engine in *embedded* mode. |
| **OphanimCore** | The shared instrumentation + interception engine: hook modules, the lock-free capture ring, the rule/scripting engine, and the log sinks. It compiles into Galgal (embedded) and into a standalone agent dylib (sibling). |

### Injection modes

- **Embedded** (default) - the engine runs inside the Galgal runtime that's already in the app. Full
  capture, no extra re-sign.
- **Sibling** - a standalone agent dylib is injected alongside the runtime via a second
  `LC_LOAD_DYLIB` (the app is re-signed). Use it when instrumentation should be independent of the
  runtime.

### Capture coverage by mode

| Category | Embedded | Sibling |
|---|:---:|:---:|
| Network (HTTP(S) bodies, socket/DNS, TLS plaintext, pinning bypass + log) | ✅ | ✅ |
| Process (`dlopen`/`fork`/`posix_spawn`, app/URL launches) | ✅ | ✅ |
| Device / Privacy (IDs, location, pasteboard, App Attest, biometrics, camera/mic/photos/contacts) | ✅ | ✅ |
| Crypto (`CCCrypt` / `CCHmac`) | ✅ | ✅ |
| Custom ObjC hooks (swizzle any class/selector) | ✅ | ✅ |
| Custom Swift hooks (native-Swift vtable patching) | ✅ | ✅ |
| Inline hooks (arm64 machine-code patch by address/symbol/offset/signature; intercept/modify return/log; render `NSData`/`NSString` arg registers as bodies/fields) | ✅ | ✅ |
| Rules engine + JavaScriptCore scripting + all sinks | ✅ | ✅ |
| Filesystem | ✅ full (`open`/`stat`/`access`/`rename`/`unlink`) | ◑ partial - `NSFileManager` only |
| Keychain (`SecItem*`) | ✅ | ✗ (C API; no ObjC fallback) |
| Jailbreak / root-detector bypass + logging | ✅ | bypass yes; logging Embedded-only |

The engine deliberately only interposes C symbols the runtime doesn't already own, so the two never
collide - that's why keychain and raw C-level filesystem stay Embedded-only and Sibling falls back to
`NSFileManager`-level filesystem capture.

## Building

Apple Silicon Mac, Xcode 26+, and the iOS platform installed (`xcodebuild -downloadPlatform iOS`).

```sh
# Build Ophanim.app (builds the Galgal runtime + the sibling agent, deep ad-hoc re-signs,
# and installs to ~/Applications/Ophanim.app)
./build-ophanim.sh Release

# Deploy the injected runtime to ~/Library/Frameworks (where hosted apps load it from)
./scripts/deploy-runtime.sh
```

Other scripts:

- `Galgal/build-galgal.sh` - build just the runtime framework (+ input plugin), retag to Mac Catalyst.
- `Galgal/build-agent.sh` - build just the standalone sibling agent dylib.
- `TestApp/build-testapp.sh` - build the bundled test harness (`OphanimTest.ipa`) that exercises every capture category.
- `scripts/integration-test.sh` - install/launch the harness and assert each category captures.

## Using it

1. Launch Ophanim and drop in an `.ipa`. It re-signs, injects, and installs the app.
2. Open the app's **Instrumentation** settings: enable the engine, pick categories, sinks, the
   injection method, and (optionally) author interception rules or custom ObjC/Swift hooks.
3. Launch the app from within Ophanim. View captured events in **View log…** or
   `log stream --predicate 'subsystem == "be.ophanim"'`.

### Scripting (MCP)

`Ophanim --mcp` speaks the Model Context Protocol over stdio (or an HTTP port), exposing tools to
list/launch apps, read & write per-app config, set rules and ObjC/Swift hooks, list and apply presets,
enumerate jailbreak detectors, inspect a binary's import/symbol surface, and tail/query captured
events - so analysis can be driven programmatically.

## License

Distributed under the GPLv3 License. See `LICENSE`.

## Credits

Ophanim is created and maintained by **ytcracker** and **clord**.

## Acknowledgments

Built with these open-source components:

- [inject](https://github.com/paradiseduo/inject) - Mach-O load-command injection.
- [PTFakeTouch](https://github.com/Ret70/PTFakeTouch) - synthetic touch events (vendored in the runtime).
- [DataCache](https://github.com/huynguyencong/DataCache) - on-disk caching.
- [CachedAsyncImage](https://github.com/bullinnyc/CachedAsyncImage) - async/cached image loading.
- [Yams](https://github.com/jpsim/Yams) - YAML parsing.
- [swift-atomics](https://github.com/apple/swift-atomics) - lock-free atomics (runtime).
