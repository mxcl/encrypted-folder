import CommonCrypto
import CryptoKit
import Foundation

public struct VaultConfig: Codable, Sendable {
    public static let fileName = "encrypted-folder.json"

    public let format: String
    public let version: Int
    public let id: UUID
    public let rootDirectoryID: Data
    public let salt: Data
    public let iterations: Int
    public let wrappedMasterKey: Data

    public static func create(password: String, iterations: Int = 600_000) throws -> (Self, SymmetricKey) {
        let salt = randomData(count: 32)
        let masterKey = SymmetricKey(size: .bits256)
        let passwordKey = try derivePasswordKey(password, salt: salt, iterations: iterations)
        let wrapped = try AES.GCM.seal(masterKey.data, using: passwordKey).combined!
        return (
            Self(
                format: "encrypted-folder",
                version: 1,
                id: UUID(),
                rootDirectoryID: randomData(count: 16),
                salt: salt,
                iterations: iterations,
                wrappedMasterKey: wrapped
            ),
            masterKey
        )
    }

    public func unlock(password: String) throws -> SymmetricKey {
        guard format == "encrypted-folder", version == 1,
              rootDirectoryID.count == 16, salt.count == 32,
              (1_000...5_000_000).contains(iterations) else {
            throw VaultError.invalidVault
        }
        do {
            let passwordKey = try Self.derivePasswordKey(password, salt: salt, iterations: iterations)
            let box = try AES.GCM.SealedBox(combined: wrappedMasterKey)
            return SymmetricKey(data: try AES.GCM.open(box, using: passwordKey))
        } catch {
            throw VaultError.wrongPassword
        }
    }

    private static func derivePasswordKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var passwordBytes = Array(password.utf8)
        defer { passwordBytes.resetBytes(in: passwordBytes.indices) }
        let keyLength = 32
        var result = Data(count: keyLength)
        let status = result.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes,
                    passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    output.bindMemory(to: UInt8.self).baseAddress,
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw VaultError.invalidVault }
        return SymmetricKey(data: result)
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public struct VaultCryptor: Sendable {
    public static let chunkSize = 1_048_576
    fileprivate static let magic = Data("EFV1".utf8)
    fileprivate static let headerSize = 64
    fileprivate static let overhead = 28

    private let masterKey: SymmetricKey

    public init(masterKey: SymmetricKey) {
        self.masterKey = masterKey
    }

    public func encryptName(_ name: String, directoryID: Data) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw VaultError.invalidVault
        }
        let box = try AES.GCM.seal(Data(name.utf8), using: nameKey(directoryID), authenticating: directoryID)
        let encoded = box.combined!.base64URLEncodedString()
        guard encoded.utf8.count <= 240 else { throw VaultError.nameTooLong }
        return encoded
    }

    public func decryptName(_ encryptedName: String, directoryID: Data) throws -> String {
        guard let combined = Data(base64URLEncoded: encryptedName) else { throw VaultError.damagedFile }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let data = try AES.GCM.open(box, using: nameKey(directoryID), authenticating: directoryID)
            guard let name = String(data: data, encoding: .utf8) else { throw VaultError.damagedFile }
            return name
        } catch {
            throw VaultError.damagedFile
        }
    }

    public func encryptFile(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let fileSize = values.fileSize else {
            throw VaultError.unsupportedFile
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try encrypt(plainSize: UInt64(fileSize), to: destination) { count in
            try input.read(upToCount: count) ?? Data()
        }
    }

    public func encrypt(_ data: Data, to destination: URL) throws {
        var offset = 0
        try encrypt(plainSize: UInt64(data.count), to: destination) { count in
            let end = min(offset + count, data.count)
            defer { offset = end }
            return data[offset..<end]
        }
    }

    public func reader(for url: URL) throws -> EncryptedFileReader {
        try EncryptedFileReader(url: url, masterKey: masterKey)
    }

    private func encrypt(plainSize: UInt64, to destination: URL, read: (Int) throws -> Data) throws {
        let fileID = Self.randomData(count: 16)
        let headerPrefix = Self.magic + fileID + plainSize.bigEndianData + UInt32(Self.chunkSize).bigEndianData
        let headerMAC = Data(HMAC<SHA256>.authenticationCode(for: headerPrefix, using: headerKey(fileID)))
        let header = headerPrefix + headerMAC
        let temporary = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.write(contentsOf: header)
            var remaining = plainSize
            var index: UInt64 = 0
            while remaining > 0 {
                let requested = min(Self.chunkSize, Int(remaining))
                let plaintext = try read(requested)
                guard plaintext.count == requested else { throw VaultError.damagedFile }
                let box = try AES.GCM.seal(
                    plaintext,
                    using: fileKey(fileID),
                    authenticating: header + index.bigEndianData
                )
                try output.write(contentsOf: box.combined!)
                remaining -= UInt64(requested)
                index += 1
            }
            try output.synchronize()
            try output.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func nameKey(_ directoryID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: directoryID,
            info: Data("encrypted-folder/name/v1".utf8),
            outputByteCount: 32
        )
    }

    fileprivate func fileKey(_ fileID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: fileID,
            info: Data("encrypted-folder/content/v1".utf8),
            outputByteCount: 32
        )
    }

    private func headerKey(_ fileID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: fileID,
            info: Data("encrypted-folder/header/v1".utf8),
            outputByteCount: 32
        )
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public final class EncryptedFileReader: @unchecked Sendable {
    public let plainSize: UInt64

    private let handle: FileHandle
    private let header: Data
    private let fileKey: SymmetricKey
    private let lock = NSLock()

    fileprivate init(url: URL, masterKey: SymmetricKey) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: VaultCryptor.headerSize) ?? Data()
        guard header.count == VaultCryptor.headerSize,
              header.prefix(4) == VaultCryptor.magic,
              let plainSize = UInt64(bigEndianData: header[20..<28]),
              UInt32(bigEndianData: header[28..<32]) == UInt32(VaultCryptor.chunkSize) else {
            try? handle.close()
            throw VaultError.damagedFile
        }
        let fileID = Data(header[4..<20])
        let fileKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: fileID,
            info: Data("encrypted-folder/content/v1".utf8),
            outputByteCount: 32
        )
        let headerKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: fileID,
            info: Data("encrypted-folder/header/v1".utf8),
            outputByteCount: 32
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(header.suffix(32), authenticating: header.prefix(32), using: headerKey) else {
            try? handle.close()
            throw VaultError.damagedFile
        }
        let chunkCount = plainSize == 0 ? 0 : (plainSize - 1) / UInt64(VaultCryptor.chunkSize) + 1
        let (overhead, overheadOverflow) = chunkCount.multipliedReportingOverflow(by: UInt64(VaultCryptor.overhead))
        let (payloadSize, payloadOverflow) = plainSize.addingReportingOverflow(overhead)
        let (expectedSize, sizeOverflow) = UInt64(VaultCryptor.headerSize).addingReportingOverflow(payloadSize)
        guard !overheadOverflow, !payloadOverflow, !sizeOverflow,
              try handle.seekToEnd() == expectedSize else {
            try? handle.close()
            throw VaultError.damagedFile
        }
        self.plainSize = plainSize
        self.header = header
        self.fileKey = fileKey
    }

    deinit { try? handle.close() }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard offset <= plainSize, length >= 0 else { throw VaultError.damagedFile }
        let (unboundedEnd, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow else { throw VaultError.damagedFile }
        let requestedEnd = min(plainSize, unboundedEnd)
        guard requestedEnd > offset else { return Data() }
        let firstChunk = Int(offset / UInt64(VaultCryptor.chunkSize))
        let lastChunk = Int((requestedEnd - 1) / UInt64(VaultCryptor.chunkSize))
        var result = Data()
        result.reserveCapacity(Int(requestedEnd - offset))
        for index in firstChunk...lastChunk {
            let chunk = try decryptChunk(index)
            let chunkStart = UInt64(index * VaultCryptor.chunkSize)
            let lower = Int(max(offset, chunkStart) - chunkStart)
            let upper = Int(min(requestedEnd, chunkStart + UInt64(chunk.count)) - chunkStart)
            result.append(chunk[lower..<upper])
        }
        return result
    }

    public func readAll(maximumSize: Int = 256 * 1_048_576) throws -> Data {
        guard plainSize <= UInt64(maximumSize) else { throw VaultError.unsupportedFile }
        return try read(offset: 0, length: Int(plainSize))
    }

    private func decryptChunk(_ index: Int) throws -> Data {
        let chunkStart = UInt64(index * VaultCryptor.chunkSize)
        let plaintextLength = Int(min(UInt64(VaultCryptor.chunkSize), plainSize - chunkStart))
        let encryptedOffset = UInt64(VaultCryptor.headerSize + index * (VaultCryptor.chunkSize + VaultCryptor.overhead))
        let encryptedLength = plaintextLength + VaultCryptor.overhead
        let combined: Data = try lock.withLock {
            try handle.seek(toOffset: encryptedOffset)
            return try handle.read(upToCount: encryptedLength) ?? Data()
        }
        guard combined.count == encryptedLength else { throw VaultError.damagedFile }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: fileKey, authenticating: header + UInt64(index).bigEndianData)
        } catch {
            throw VaultError.damagedFile
        }
    }
}

private extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

private extension FixedWidthInteger {
    var bigEndianData: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init?(bigEndianData data: some DataProtocol) {
        guard data.count == MemoryLayout<Self>.size else { return nil }
        var value: Self = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        self = Self(bigEndian: value)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
