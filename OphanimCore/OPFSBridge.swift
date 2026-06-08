//
//  OPFSBridge.swift
//  OphanimCore
//
//  Filesystem logging for EMBEDDED mode. Galgal already DYLD_INTERPOSEs open/stat/access/rename/
//  unlink (for its Unreal path-rewriting), so - per the no-double-interpose rule - Galgal's
//  wrappers call this bridge inline rather than Ophanim re-hooking. Observe-only. High volume, so
//  it self-gates on the .filesystem category (cheap when disabled).
//

import Foundation

@objc(OPFSBridge) public final class OPFSBridge: NSObject {
    // Takes a raw C string (not NSString): open/stat/access can be called by malloc itself during
    // heap setup, so the caller MUST NOT allocate. We set the re-entrancy guard first, then build
    // the Swift String - any malloc→stat→hook re-entry then bails before allocating.
    @objc public static func log(api: NSString, cpath: UnsafePointer<CChar>?) {
        guard !OPReentry.active else { return }
        OPReentry.active = true
        defer { OPReentry.active = false }
        guard OPAgent.shared.isActive(.filesystem) else { return }
        let path = cpath.map { String(cString: $0) } ?? ""
        let ctx = OPCallContext(category: .filesystem, layer: .interpose, api: api as String, path: path)
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
    }
}
