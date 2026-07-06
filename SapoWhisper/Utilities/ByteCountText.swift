//
//  ByteCountText.swift
//  SapoWhisper
//

import Foundation

extension Int64 {
    /// File-style MB/GB label used wherever the UI reports model sizes.
    var byteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
