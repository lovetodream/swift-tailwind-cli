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

    try await fs.withTemporaryDirectory { directory, path in
        do {
            try await run(in: path, using: fs)
        } catch {
            Issue.record(error)
        }
    }
}

func run(in directory: FilePath, using fs: FileSystem) async throws {
    let cli = TailwindCLI()

    let inputCSSPath = directory.appending("input.css")
    let outputCSSPath = directory.appending("output.css")

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
}
