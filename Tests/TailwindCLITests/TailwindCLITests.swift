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

import TailwindCLI
import Testing
import _NIOFileSystem

@Test func run() async throws {
    let fs = FileSystem.shared
    let tmpDir = try await fs.temporaryDirectory.appending(RandomID.generate().description)
    try await fs.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    do {
        let cli = TailwindCLI()

        let inputCSSPath = tmpDir.appending("input.css")
        let outputCSSPath = tmpDir.appending("output.css")

        let inputCSSContent = """
            @import "tailwindcss";

            p {
                @apply font-bold;
            }
            """

        _ = try await fs.withFileHandle(forWritingAt: inputCSSPath, options: .newFile(replaceExisting: true)) { write in
            try await write.write(contentsOf: inputCSSContent.utf8, toAbsoluteOffset: 0)
        }

        try await cli.run(input: inputCSSPath.string, output: outputCSSPath.string)

        #expect(try await fs.info(forFileAt: outputCSSPath) != nil)
        let content = try await fs.withFileHandle(forReadingAt: outputCSSPath) { read in
            var contents = ""
            for try await chunk in read.readChunks() {
                contents.append(chunk.peekString(length: chunk.readableBytes).unsafelyUnwrapped)
                if contents.contains("--font-weight-bold: 700") { return contents }
            }
            return contents
        }
        #expect(content.contains("--font-weight-bold: 700"))
    } catch {
        Issue.record(error)
    }

    try await fs.removeItem(at: tmpDir, recursively: true)
}
