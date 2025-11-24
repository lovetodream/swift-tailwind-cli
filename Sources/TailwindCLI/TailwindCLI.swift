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

import AsyncHTTPClient
import Logging
import Subprocess
import _NIOFileSystem

public struct TailwindCLI: Sendable {
    let version: TailwindVersion
    let downloader: Downloader

    public init(
        version: TailwindVersion = .latest,
        httpClient: HTTPClient = .shared,
        logger: Logger? = nil,
        strictMode: Bool = true
    ) {
        let logger = logger ?? Logger(label: "TailwindCLI", factory: { SwiftLogNoOpLogHandler($0) })

        self.version = version
        self.downloader = .init(
            httpClient: httpClient,
            architectureDetector: .init(),
            logger: logger,
            fileSystem: .shared,
            strictMode: strictMode
        )
    }

    public func run(
        input: String,
        output: String,
        directory: String? = nil,
        options: RunOption...
    ) async throws {
        let assets = try await self.downloader.download(
            version: self.version, to: directory.flatMap({ .init($0) }))
        let arguments = Arguments(["--input", input, "--output", output] + options.map(\.flag))
        let result = try await Subprocess.run(
            .path(.init(assets.executable.string)), arguments: arguments, output: .discarded,
            error: .string(limit: 1024, encoding: UTF8.self))
        guard result.terminationStatus.isSuccess else {
            throw Error.cliFailure(result.standardError)
        }

        // copy themes and js to out dir
        try await withThrowingDiscardingTaskGroup { group in
            let outputPath = FilePath(output).removingLastComponent().appending("flowbite")
            try await FileSystem.shared.removeItem(at: outputPath, recursively: true)
            let themesPath = outputPath.appending("themes")
            try await FileSystem.shared.createDirectory(at: themesPath, withIntermediateDirectories: true)
            for theme in assets.themes {
                group.addTask {
                    try await FileSystem.shared.copyItem(at: theme.path, to: themesPath.appending(theme.name))
                }
            }
            for js in assets.js {
                group.addTask {
                    try await FileSystem.shared.copyItem(at: js.path, to: outputPath.appending(js.name))
                }
            }
        }
    }

    public enum RunOption: Sendable, Hashable {
        /// Watch for changes and rebuild as needed.
        case watch

        /// Optimize and minify the output.
        case minify

        /// Optimize the output without minifying.
        case optimize

        /// Generate a source map.
        case map

        /// A custom flag.
        case custom(String)

        var flag: String {
            switch self {
            case .watch:
                return "--watch"
            case .minify:
                return "--minify"
            case .optimize:
                return "--optimize"
            case .map:
                return "--map"
            case .custom(let flag):
                return flag
            }
        }
    }

    enum Error: Swift.Error {
        case cliFailure(String?)
    }
}
