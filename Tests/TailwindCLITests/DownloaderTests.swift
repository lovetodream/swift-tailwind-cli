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

import Testing
import _NIOFileSystem

@testable import TailwindCLI

@Test func download() async throws {
    let fs = FileSystem.shared
    let downloader = Downloader(
        httpClient: .shared,
        architectureDetector: .init(),
        logger: .init(label: "Downloader"),
        fileSystem: .shared,
        strictMode: true
    )
    try await fs.withTemporaryDirectory { directory, path in
        let assets = try await downloader.download(version: .latest, to: path)
        #expect(assets.executable.isEmpty == false)
    }
}
