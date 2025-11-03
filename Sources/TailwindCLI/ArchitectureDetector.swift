//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-tailwind-cli open source project
//
// Copyright (c) 2025 Timo Zacherl and the swift-tailwind-cli project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of swift-tailwind-cli project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Subprocess

enum CPUArchitecture: String, Hashable {
    case aarch64 = "aarch64"
    case arm64 = "arm64"
    case armv7 = "armv7"
    // swift-format-ignore: AlwaysUseLowerCamelCase
    case x86_64 = "x86_64"

    var tailwindValue: String {
        switch self {
        case .aarch64, .arm64:
            "arm64"
        case .armv7:
            "armv7"
        case .x86_64:
            "x86_64"
        }
    }
}

struct ArchitectureDetector {
    func architecture() async throws -> CPUArchitecture? {
        let output = try await run(
            .name("uname"),
            arguments: ["-m"],
            output: .string(limit: 32, encoding: UTF8.self)
        )
        guard let arch = output.standardOutput?.replacing(/(^\s+|\s+$)/, with: "") else { return nil }
        return CPUArchitecture(rawValue: arch)
    }
}
