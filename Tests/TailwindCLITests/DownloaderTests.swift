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
    let tmpDir = try await fs.temporaryDirectory.appending(RandomID.generate().description)
    let file = try await downloader.download(version: .latest, to: tmpDir)
    #expect(file.isEmpty == false)
    try await fs.removeItem(at: tmpDir, recursively: true)
}
