// SettingsContent.swift
// Settings values shared by both platforms, so the two settings screens
// always say the same things even though each lays them out in its own
// style.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation

enum SettingsContent {
    /// "1.0 (54)" from the running bundle. Outside a real bundle (e.g.
    /// `swift run`) both values fall back to 0.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
