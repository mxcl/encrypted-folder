import CryptoKit
import Foundation
import Testing
@testable import EncryptedFolderCore

@Test func encryptedFileRoundTripsAcrossChunksAndRanges() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ciphertext")
    let plaintext = Data((0..<(VaultCryptor.chunkSize * 2 + 137)).map { UInt8(truncatingIfNeeded: $0) })
    let cryptor = VaultCryptor(masterKey: SymmetricKey(size: .bits256))

    try cryptor.encrypt(plaintext, to: url)
    let reader = try cryptor.reader(for: url)

    #expect(reader.plainSize == plaintext.count)
    #expect(try reader.readAll(maximumSize: plaintext.count) == plaintext)
    #expect(try reader.read(offset: UInt64(VaultCryptor.chunkSize - 17), length: 80) == plaintext[(VaultCryptor.chunkSize - 17)..<(VaultCryptor.chunkSize + 63)])
}

@Test func vaultEncryptsNamesAndExportsOnlyOnRequest() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let vaultURL = base.appendingPathComponent("vault")
    let source = base.appendingPathComponent("private notes.txt")
    try Data("classified".utf8).write(to: source)
    let vault = try Vault.create(at: vaultURL, password: "correct horse battery staple")

    let imported = try vault.importItem(at: source, into: vault.rootURL)
    let physicalNames = try FileManager.default.contentsOfDirectory(atPath: vaultURL.path)
    #expect(!physicalNames.contains("private notes.txt"))
    #expect(try vault.items(in: vault.rootURL).map(\.name) == ["private notes.txt"])

    let renamed = try vault.rename(imported, to: "renamed.txt")
    let exportDirectory = base.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
    try vault.export(renamed, to: exportDirectory)
    #expect(try Data(contentsOf: exportDirectory.appendingPathComponent("renamed.txt")) == Data("classified".utf8))
    #expect(throws: VaultError.wrongPassword) {
        _ = try Vault.open(at: vaultURL, password: "wrong")
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
