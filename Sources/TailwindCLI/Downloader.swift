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

    func download(version: TailwindVersion = .latest, to directory: FilePath? = nil) async throws -> FilePath {
        guard let binaryName = try await self.binaryName() else {
            throw Error.unableToDetermineBinaryName
        }

        // fast path, no api calls needed
        let expectedVersion = self.expectedVersion(for: version)
        let binaryPath: FilePath
        if let directory {
            binaryPath = directory.appending(expectedVersion).appending(binaryName)
        } else {
            binaryPath = try await self.fileSystem.temporaryDirectory.appending("swift-tailwind").appending(
                expectedVersion
            ).appending(binaryName)
        }

        if try await self.fileSystem.info(forFileAt: binaryPath) != nil {
            return binaryPath
        }

        // api calls
        let (version, remoteChecksum, downloadURL) = try await self.downloadMetadata(binary: binaryName, for: version)
        self.logger.debug("Downloading tailwindcss version \(version)")
        try await self.downloadBinary(from: downloadURL, to: binaryPath)

        // checksum validation
        guard self.strictMode else {
            self.logger.debug("Skipping checksum validation as strict mode is disabled.")
            return binaryPath
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

        return binaryPath
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
        //        let result = try await run(.name("chmod"), arguments: ["+x", downloadPath.string], output: .discarded)
        //        guard result.terminationStatus.isSuccess else {
        //            throw Error.unableToFlagBinaryAsExecutable
        //        }
    }

    func downloadMetadata(binary: String, for version: TailwindVersion) async throws -> (
        version: String,
        checksum: String,
        download: String
    ) {
        let apiURL: String
        let fallbackDownloadURL: String
        switch version {
        case .latest:
            apiURL = "https://api.github.com/repos/dobicinaitis/tailwind-cli-extra/releases/latest"
            fallbackDownloadURL =
                "https://github.com/dobicinaitis/tailwind-cli-extra/releases/latest/download/\(binary)"
        case .fixed(let version):
            apiURL = "https://api.github.com/repos/dobicinaitis/tailwind-cli-extra/releases/v\(version)"
            fallbackDownloadURL =
                "https://github.com/dobicinaitis/tailwind-cli-extra/releases/download/v\(version)/\(binary)"
        }
        self.logger.trace("Downloading metadata from \(apiURL)")

        var request = HTTPClientRequest(url: apiURL)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "User-Agent", value: "com.siebenwurst.swift-tailwind-cli")
        let response = try await self.httpClient.execute(request, timeout: .seconds(30))
        var body = try await response.body.collect(upTo: 1024 * 1024)
        let json = body.readString(length: body.readableBytes).unsafelyUnwrapped

        let tagNameRegex = /"tag_name"\s*:\s*"([^"]+)"/
        guard let tag = json.firstMatch(of: tagNameRegex)?.output.1 else {
            self.logger.debug("Unexpected metadata response, tag_name not found, continuing with 'latest'")
            return ("latest", "", fallbackDownloadURL)
        }

        let nameRegex = try Regex(#""name"\s*:\s*"\#(binary)""#)
        guard let nameMatch = json.firstMatch(of: nameRegex) else {
            self.logger.debug("Unexpected metadata response, digest not found, continuing without check")
            return (String(tag), "", fallbackDownloadURL)
        }

        var endIndex = nameMatch.range.lowerBound
        _ = json.formIndex(&endIndex, offsetBy: 2_000, limitedBy: json.index(before: json.endIndex))
        let part = json[nameMatch.range.lowerBound...endIndex]

        let digestRegex = /"digest"\s*:\s*"([^"]+)"/
        guard let digest = part.firstMatch(of: digestRegex)?.output.1 else {
            self.logger.debug("Unexpected metadata response, digest not found, continuing without check")
            return (String(tag), "", fallbackDownloadURL)
        }

        let downloadURLRegex = /"browser_download_url"\s*:\s*"([^"]+)"/
        guard let downloadURL = part.firstMatch(of: downloadURLRegex)?.output.1 else {
            self.logger.debug("Unexpected metadata response, browser_download_url not found, continuing with fallback")
            return (String(tag), String(digest), fallbackDownloadURL)
        }

        return (String(tag), String(digest), String(downloadURL))
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

        return "tailwindcss-extra-\(os)-\(architecture.tailwindValue)\(ext)"
    }

    enum Error: Swift.Error {
        case unableToDetermineBinaryName
        case unableToFlagBinaryAsExecutable
        case checksumMismatch(local: String, remote: String)
        case downloadError
    }
}
