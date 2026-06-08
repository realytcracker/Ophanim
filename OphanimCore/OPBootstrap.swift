//
//  OPBootstrap.swift
//  OphanimCore
//
//  ObjC-callable entry point. This file is compiled into BOTH the embedded Galgal runtime and the
//  standalone sibling agent dylib, so the @objc entry class needs a build-specific runtime name to
//  avoid a duplicate-class collision when both images are loaded in the same process (sibling mode):
//    • embedded build  → @objc(OPBootstrap)      - Galgal loader calls [OPBootstrap startEmbedded]
//    • sibling build   → @objc(OPAgentBootstrap)  - agent constructor calls [OPAgentBootstrap start]
//  The sibling build is selected by the -D OPHANIM_SIBLING flag in build-agent.sh. The shared logic
//  lives in `OPBootstrapCore` (no fixed ObjC name → per-module symbol, no collision); the two @objc
//  shims below just forward to it. Starting is idempotent, so calling twice is harmless.
//

import Foundation

/// Shared engine start/hook logic. Not @objc-named, so each image gets its own symbol and there's
/// no cross-image duplicate-class warning.
enum OPBootstrapCore {
    /// Unconditional start - the sibling agent uses this. The agent only loads when the app is set
    /// to sibling injection, so it always owns the engine.
    /// We must NOT do heavy work (plist parsing, libdispatch sources, swizzling) at call time: the
    /// constructors run during dyld initialization while the linker holds locks, where touching
    /// Foundation heavily can crash. Defer to the main queue, which runs once the runloop starts.
    static func startForced() {
        DispatchQueue.main.async {
            guard OPAgent.shared.start() else { return }
            installHooks()
        }
    }

    /// Gated start - the embedded Galgal loader calls this unconditionally, but it only starts the
    /// engine when the app is configured for embedded injection. In sibling mode the standalone
    /// agent owns the engine, so the embedded core stays dormant (no duplicate engine, no
    /// double-swizzle).
    static func startEmbedded() {
        DispatchQueue.main.async {
            guard OPConfigLoader.load().injectionStrategy == .embedded else { return }
            guard OPAgent.shared.start() else { return }
            installHooks()
        }
    }

    /// Called from GalgalShadow's jailbreak-bypass stubs when a detector is invoked and we return a
    /// safe value. Logged under the .jailbreak category (no-op when that category isn't active).
    static func logJailbreakBypass(cls: String, selector: String) {
        guard OPAgent.shared.isActive(.jailbreak) else { return }
        OPAgent.shared.observe(OPEvent(category: .jailbreak, layer: .objc,
                                       api: "\(cls).\(selector)",
                                       summary: "jailbreak/root check bypassed → returned safe value",
                                       disposition: .returnReplaced))
    }

    private static var hooksInstalled = false

    static func installHooks() {
        guard !hooksInstalled else { return }   // idempotent (live reload may re-invoke)
        hooksInstalled = true
        // Start the capture-ring consumer thread (safe context, post-launch). The low-level C
        // interposes (process/fs/…) enqueue into the ring; this drains them into OPEvents.
        op_ring_start()
        OPNetworkHooks.install()
        OPDeviceHooks.install()
        OPLaunchHooks.install()
        installUserHooks()              // user-configured objc/swift/inline hooks (also re-run on reload)
        #if OPHANIM_SIBLING
        // Sibling-only: filesystem at the ObjC layer (NSFileManager). Raw POSIX open/stat/access/
        // rename/unlink are now also captured by OPHooksFSRaw.m's DYLD_INTERPOSE entries (agent-only,
        // -D OPHANIM_SIBLING), giving sibling injection parity with embedded mode's C-level capture.
        // This NSFileManager swizzle stays because it adds high-level operations the raw syscalls don't
        // surface - directory enumeration (readdir) and attribute queries. (Keychain has no ObjC
        // fallback - SecItem* is a C API, and Galgal's gg_SecItem* do emulation, not observe - so it
        // stays embedded-only.)
        OPFilesystemHooks.install()
        #endif
        // Process hooks (dlopen/fork/posix_spawn), TLS, and (sibling) raw-FS are static DYLD_INTERPOSE
        // entries - they apply at load automatically and gate emit via op_ring_started() in the wrapper.
        // Keychain/crypto (embedded) are logged inline in Galgal's existing SecItem interposers.
    }

    /// User-configured ObjC/Swift/inline hooks. Split out from installHooks() so config live-reload can
    /// re-run JUST these to pick up newly added hooks without re-doing the one-time base setup. Each is
    /// idempotent (tracks what it has already installed), so re-running only installs the new entries.
    static func installUserHooks() {
        OPConfigurableHooks.install()   // user-specified ObjC boundary hooks (OPConfig.objcHooks)
        OPSwiftHooks.install()          // user-specified native-Swift vtable hooks (OPConfig.swiftHooks)
        OPInlineHooks.install()         // inline (machine-code) hooks (OPConfig.inlineHooks; gated)
    }
}

#if OPHANIM_SIBLING
@objc(OPAgentBootstrap) public final class OPBootstrap: NSObject {
    @objc public static func start() { OPBootstrapCore.startForced() }
    @objc public static func startEmbedded() { OPBootstrapCore.startEmbedded() }
    @objc public static func logJailbreakBypass(_ cls: String, selector: String) {
        OPBootstrapCore.logJailbreakBypass(cls: cls, selector: selector)
    }
}
#else
@objc(OPBootstrap) public final class OPBootstrap: NSObject {
    @objc public static func start() { OPBootstrapCore.startForced() }
    @objc public static func startEmbedded() { OPBootstrapCore.startEmbedded() }
    @objc public static func logJailbreakBypass(_ cls: String, selector: String) {
        OPBootstrapCore.logJailbreakBypass(cls: cls, selector: selector)
    }
}
#endif
