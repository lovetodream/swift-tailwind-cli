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

struct Downloader {
    let httpClient: HTTPClient
    let architectureDetector: ArchitectureDetector
    let logger: Logger
    let fileSystem: FileSystem
    let strictMode: Bool

    struct DownloadResult {
        let executable: FilePath
        let themes: [(name: String, path: FilePath)]
        let js: [(name: String, path: FilePath)]
    }
    func download(version: TailwindVersion = .latest, to directory: FilePath? = nil) async throws -> DownloadResult {
        guard let binaryName = try await self.binaryName() else {
            throw Error.unableToDetermineBinaryName
        }

        // fast path, no api calls needed
        let expectedVersion = self.expectedVersion(for: version)
        let downloadDirectory: FilePath
        if let directory {
            downloadDirectory = directory.appending(expectedVersion)
        } else {
            downloadDirectory = try await self.fileSystem.temporaryDirectory
                .appending("swift-tailwind")
                .appending(expectedVersion)
        }
        let binaryPath = downloadDirectory.appending(binaryName)

        if try await self.fileSystem.info(forFileAt: binaryPath) != nil {
            return try await self.fileSystem.withDirectoryHandle(atPath: downloadDirectory) { directory in
                var themes: [(name: String, path: FilePath)] = []
                var js: [(name: String, path: FilePath)] = []
                for try await content in directory.listContents() {
                    if content.name.string.hasSuffix(".css") {
                        themes.append((content.name.string, content.path))
                    } else if content.name.string.contains(/\.js(\.|$)/) {
                        js.append((content.name.string, content.path))
                    }
                }
                return .init(executable: binaryPath, themes: themes, js: js)
            }
        }

        // api calls
        let (version, binary, themes, js) = try await self.downloadMetadata(binary: binaryName, for: version)
        self.logger.debug("Downloading tailwindcss version \(version)")

        var availableThemes: [(name: String, path: FilePath)] = []
        var availableJS: [(name: String, path: FilePath)] = []
        enum FileType {
            case executable
            case theme(String, FilePath)
            case js(String, FilePath)
        }
        try await withThrowingTaskGroup(of: FileType.self) { group in

            // executable
            group.addTask {
                try await self.downloadBinary(from: binary.downloadURL, to: binaryPath)
                try await self.validateBinary(binaryPath: binaryPath, remoteChecksum: binary.digest)
                return .executable
            }

            // flowbite themes
            for theme in themes {
                group.addTask {
                    let path = downloadDirectory.appending(theme.name)
                    try await self.downloadBinary(from: theme.downloadURL, to: path)
                    try await self.validateBinary(binaryPath: path, remoteChecksum: theme.digest)
                    return .theme(theme.name, path)
                }
            }

            // flowbite js support
            for js in js {
                group.addTask {
                    let path = downloadDirectory.appending(js.name)
                    try await self.downloadBinary(from: js.downloadURL, to: path)
                    try await self.validateBinary(binaryPath: path, remoteChecksum: js.digest)
                    return .js(js.name, path)
                }
            }

            for try await asset in group {
                switch asset {
                case .executable:
                    continue
                case .theme(let name, let path):
                    availableThemes.append((name, path))
                case .js(let name, let path):
                    availableJS.append((name, path))
                }
            }
        }

        return .init(executable: binaryPath, themes: availableThemes, js: availableJS)
    }

    func validateBinary(binaryPath: FilePath, remoteChecksum: String) async throws {
        guard self.strictMode else {
            self.logger.debug("Skipping checksum validation as strict mode is disabled.")
            return
        }

        let checksumResult = try await run(
            .path("/usr/bin/shasum"),
            arguments: ["-a", "256", binaryPath.string],
            output: .string(limit: 256, encoding: UTF8.self)
        )

        guard let localChecksum = checksumResult.standardOutput?.split(separator: " ").first else {
            throw Error.checksumMismatch(local: "", remote: remoteChecksum)
        }

        guard localChecksum == remoteChecksum.dropFirst("sha256:".count) else {
            throw Error.checksumMismatch(local: String(localChecksum), remote: remoteChecksum)
        }
    }

    func downloadBinary(from url: String, to downloadPath: FilePath) async throws {
        let request = HTTPClientRequest(url: url)
        let response = try await self.httpClient.execute(request, timeout: .seconds(30), logger: self.logger)
        guard response.status == .ok else {
            throw Error.downloadError
        }
        try await self.fileSystem.createDirectory(
            at: downloadPath.removingLastComponent(),
            withIntermediateDirectories: true
        )
        try await self.fileSystem.withFileHandle(
            forWritingAt: downloadPath,
            options: .newFile(replaceExisting: true, permissions: [.ownerReadExecute, .groupReadExecute])
        ) { write in
            var offset: Int64 = 0
            for try await chunk in response.body {
                offset += try await write.write(contentsOf: chunk, toAbsoluteOffset: offset)
            }
        }
    }

    func downloadMetadata(binary: String, for version: TailwindVersion) async throws -> (
        version: String,
        download: Asset,
        themes: [Asset],
        js: [Asset]
    ) {
        let apiURL: String
        let fallbackDownloadURL: Asset
        let fallbackThemes: [Asset]
        let fallbackJS: [Asset]
        switch version {
        case .latest:
            apiURL = "https://api.github.com/repos/lovetodream/tailwind-flowbite-bundled-cli/releases/latest"
            fallbackDownloadURL = .init(
                name: binary,
                downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/latest/download/\(binary)"
            )
            fallbackThemes = [
                .init(name: "themes.css", downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/latest/download/themes.css"),
                .init(name: "default.css", downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/latest/download/default.css")
            ]
            fallbackJS = [
                .init(name: "flowbite.min.js", downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/latest/download/flowbite.min.js")
            ]
        case .fixed(let version):
            apiURL = "https://api.github.com/repos/lovetodream/tailwind-flowbite-bundled-cli/releases/v\(version)"
            fallbackDownloadURL = .init(
                name: binary,
                downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/download/v\(version)/\(binary)"
            )
            fallbackThemes = [
                .init(name: "themes.css", downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/download/v\(version)/themes.css"),
                .init(name: "default.css", downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/download/v\(version)/default.css")
            ]
            fallbackJS = [
                .init(name: "flowbite.min.js", downloadURL: "https://github.com/lovetodream/tailwind-flowbite-bundled-cli/releases/download/v\(version)/flowbite.min.js")
            ]
        }
        self.logger.trace("Downloading metadata from \(apiURL)")

        var request = HTTPClientRequest(url: apiURL)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "User-Agent", value: "com.siebenwurst.swift-tailwind-cli")
        let response = try await self.httpClient.execute(request, timeout: .seconds(30))
        var body = try await response.body.collect(upTo: 1024 * 1024)
        let json = body.readString(length: body.readableBytes).unsafelyUnwrapped

        let tagNameRegex = /"tag_name"\s*:\s*"(?<version>[^"]+)"/
        guard let tag = json.firstMatch(of: tagNameRegex)?.output.version else {
            self.logger.debug("Unexpected metadata response, tag_name not found, continuing with 'latest'")
            return ("latest", fallbackDownloadURL, fallbackThemes, fallbackJS)
        }

        let namesRegex = /"name"\s*:\s*"(?<filename>[^"]+)"/
        let nameMatches = json.matches(of: namesRegex)

        var download: Asset?
        var themes: [Asset] = []
        var js: [Asset] = []

        for nameMatch in nameMatches {
            let name = nameMatch.output.filename

            var endIndex = nameMatch.range.lowerBound
            _ = json.formIndex(&endIndex, offsetBy: 2_000, limitedBy: json.index(before: json.endIndex))
            let part = json[nameMatch.range.lowerBound...endIndex]
            
            let digestRegex = /"digest"\s*:\s*"(?<hash>[^"]+)"/
            let digest = part.firstMatch(of: digestRegex)?.output.1
            
            let downloadURLRegex = /"browser_download_url"\s*:\s*"(?<url>[^"]+)"/
            let downloadURL = part.firstMatch(of: downloadURLRegex)?.output.1

            guard let downloadURL else { continue }
            let asset = Asset(
                name: String(name),
                digest: digest.flatMap({ String($0) }),
                downloadURL: String(downloadURL)
            )

            if name == binary {
                download = asset
            } else if name.hasSuffix(".css") {
                themes.append(asset)
            } else if name.contains(/\.js(\.|$)/) {
                js.append(asset)
            }
        }

        guard let download else {
            self.logger.debug("Unexpected metadata response, browser_download_url not found, continuing with fallback")
            return ("latest", fallbackDownloadURL, fallbackThemes, fallbackJS)
        }

        return (String(tag), download, themes, js)
    }

    private func expectedVersion(for version: TailwindVersion) -> String {
        switch version {
        case .latest:
            return "latest"
        case .fixed(let value):
            return "v\(value)"
        }
    }

    /// Returns the name of the artifact that we should pull from the GitHub release.
    ///
    /// The artifact follows the convention: tailwindcss-{os}-{arch}.
    private func binaryName() async throws -> String? {
        let architecture = try await self.architectureDetector.architecture()
        guard let architecture else { return nil }

        let os: String
        let ext: String
        #if os(Windows)
            os = "windows"
            ext = ".exe"
        #elseif os(Linux)
            os = "linux"
            ext = ""
        #else
            os = "macos"
            ext = ""
        #endif

        return "tailwindcss-flowbite-\(os)-\(architecture.tailwindValue)\(ext)"
    }

    enum Error: Swift.Error {
        case unableToDetermineBinaryName
        case unableToFlagBinaryAsExecutable
        case checksumMismatch(local: String, remote: String)
        case downloadError
    }

    struct Asset {
        let name: String
        let digest: String
        let downloadURL: String

        init(name: String, digest: String? = nil, downloadURL: String) {
            self.name = name
            self.digest = digest ?? ""
            self.downloadURL = downloadURL
        }
    }
}
