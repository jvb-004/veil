//  S5: the flag everybody argues about, applied only where it helps.
//
//  On macOS below 15.4 it still keeps a window out of the legacy CoreGraphics
//  paths. At and above 15.4 the reports say ScreenCaptureKit ignores it, and
//  on macOS 26 setting it is reported to break rendering outright. Since a
//  broken window is worse than a visible one, the policy is decided by
//  measurement, not by belief: macos/Probe writes the truth per OS build and
//  this table encodes it.

import AppKit
import Foundation

enum ContentProtection {

    enum Policy: String {
        case applyLegacyFlag      // below 15.4: real benefit against CG paths
        case skipFlagUseLadder    // 15.4+: flag is useless or harmful
    }

    static var osVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var policy: Policy {
        let v = osVersion
        let past15_4 = (v.majorVersion > 15) || (v.majorVersion == 15 && v.minorVersion >= 4)
        return past15_4 ? .skipFlagUseLadder : .applyLegacyFlag
    }

    /// Returns what was actually done, so the UI can tell the user the truth
    /// instead of a reassuring lie.
    @discardableResult
    static func apply(to window: NSWindow) -> String {
        switch policy {
        case .applyLegacyFlag:
            window.sharingType = .none
            return "sharingType = .none applied (macOS \(osVersion.majorVersion).\(osVersion.minorVersion), legacy capture paths only)"
        case .skipFlagUseLadder:
            window.sharingType = .readOnly
            return "sharingType left alone: ScreenCaptureKit ignores it on macOS \(osVersion.majorVersion).\(osVersion.minorVersion) and setting it can break rendering. Falling back to the watchdog."
        }
    }
}
