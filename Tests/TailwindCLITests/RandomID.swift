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

public struct RandomID: CustomStringConvertible {
    public typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    /// The bytes of this UUID.
    ///
    public let bytes: Bytes

    /// Creates a UUID with the given bytes.
    ///
    @inlinable
    public init(bytes: Bytes) {
        self.bytes = bytes
    }

    /// The null UUID, `00000000-0000-0000-0000-000000000000`.
    ///
    @inlinable
    public static var null: RandomID {
        RandomID(bytes: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    /// Creates a UUID with the given sequence of bytes. The sequence must contain exactly 16 bytes.
    ///
    @inlinable
    public init?<Bytes>(bytes: Bytes) where Bytes: Sequence, Bytes.Element == UInt8 {
        var uuid = RandomID.null.bytes
        let bytesCopied = withUnsafeMutableBytes(of: &uuid) { uuidBytes in
            UnsafeMutableBufferPointer(
                start: uuidBytes.baseAddress.unsafelyUnwrapped.assumingMemoryBound(to: UInt8.self),
                count: 16
            ).initialize(from: bytes).1
        }
        guard bytesCopied == 16 else { return nil }
        self.init(bytes: uuid)
    }

    public static func generate() -> RandomID {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    @inlinable
    public static func generate<RNG>(using rng: inout RNG) -> RandomID where RNG: RandomNumberGenerator {
        var bytes = RandomID.null.bytes
        withUnsafeMutableBytes(of: &bytes) { dest in
            var random = rng.next()
            Swift.withUnsafePointer(to: &random) {
                dest.baseAddress!.copyMemory(from: UnsafeRawPointer($0), byteCount: 8)
            }
            random = rng.next()
            Swift.withUnsafePointer(to: &random) {
                dest.baseAddress!.advanced(by: 8).copyMemory(from: UnsafeRawPointer($0), byteCount: 8)
            }
        }
        // octet 6 = time_hi_and_version (high octet).
        // high 4 bits = version number.
        bytes.6 = (bytes.6 & 0xF) | 0x40
        // octet 8 = clock_seq_high_and_reserved.
        // high 2 bits = variant (10 = standard).
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return RandomID(bytes: bytes)
    }

    public var description: String {
        String(unsafeUninitializedCapacity: 32) { buffer in
            withUnsafeBytes(of: self.bytes) { octets in
                var i = 0
                for octetPosition in 0..<16 {
                    i = buffer.writeHex(octets[octetPosition], at: i)
                }
                return i
            }
        }
    }
}

extension UnsafeMutableBufferPointer where Element == UInt8 {
    func writeHex(_ value: UInt8, at i: Index) -> Index {
        let table: StaticString = "0123456789abcdef"
        table.withUTF8Buffer { table in
            self[i] = table[Int(value &>> 4)]
            self[i &+ 1] = table[Int(value & 0xF)]
        }
        return i &+ 2
    }
}
