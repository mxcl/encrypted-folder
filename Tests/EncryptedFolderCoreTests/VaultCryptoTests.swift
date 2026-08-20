import CryptoKit
import Foundation
import Testing

@testable import EncryptedFolderCore

@Test func encryptedFileRoundTripsAcrossChunksAndRanges() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ciphertext")
  let plaintext = Data(
    (0..<(VaultCryptor.chunkSize * 2 + 137)).map { UInt8(truncatingIfNeeded: $0) })
  let cryptor = VaultCryptor(masterKey: SymmetricKey(size: .bits256))

  try cryptor.encrypt(plaintext, to: url)
  let reader = try cryptor.reader(for: url)

  #expect(reader.plainSize == plaintext.count)
  #expect(try reader.readAll(maximumSize: plaintext.count) == plaintext)
  #expect(
    try reader.read(offset: UInt64(VaultCryptor.chunkSize - 17), length: 80)
      == plaintext[(VaultCryptor.chunkSize - 17)..<(VaultCryptor.chunkSize + 63)])
}

@Test func encryptedFileRejectsTampering() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ciphertext")
  let cryptor = VaultCryptor(masterKey: SymmetricKey(size: .bits256))
  try cryptor.encrypt(Data("secret".utf8), to: url)
  let handle = try FileHandle(forUpdating: url)
  try handle.seek(toOffset: 70)
  let original = try #require(try handle.read(upToCount: 1)?.first)
  try handle.seek(toOffset: 70)
  try handle.write(contentsOf: Data([original ^ 0xff]))
  try handle.close()

  let reader = try cryptor.reader(for: url)
  #expect(throws: VaultError.damagedFile) {
    _ = try reader.readAll()
  }
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
  #expect(
    try Data(contentsOf: exportDirectory.appendingPathComponent("renamed.txt"))
      == Data("classified".utf8))
  #expect(throws: VaultError.wrongPassword) {
    _ = try Vault.open(at: vaultURL, password: "wrong")
  }
}

@Test func bundledRecoveryScriptDecryptsVault() throws {
  let base = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: base) }
  let vaultURL = base.appendingPathComponent("vault")
  let source = base.appendingPathComponent("source")
  let nested = source.appendingPathComponent("nested")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  try Data("recovered text".utf8).write(to: source.appendingPathComponent("notes.txt"))
  try Data([0, 1, 2, 255]).write(to: nested.appendingPathComponent("bytes.bin"))

  let vault = try Vault.create(at: vaultURL, password: "correct 🐎")
  _ = try vault.importItem(at: source, into: vault.rootURL)
  let recovery = vaultURL.appendingPathComponent(Vault.recoveryFileName)
  #expect(try vault.items(in: vault.rootURL).map(\.name) == ["source"])
  #expect(
    ((try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions]
      as? NSNumber)?.intValue ?? 0) & 0o100 != 0)

  let output = base.appendingPathComponent("recovered")
  let process = Process()
  let input = Pipe()
  let diagnostics = Pipe()
  process.executableURL = recovery
  process.arguments = [output.path]
  process.standardInput = input
  process.standardOutput = diagnostics
  process.standardError = diagnostics
  try process.run()
  try input.fileHandleForWriting.write(contentsOf: Data("correct 🐎\n".utf8))
  try input.fileHandleForWriting.close()
  process.waitUntilExit()
  let message = String(
    data: try diagnostics.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8) ?? ""
  #expect(process.terminationStatus == 0, "\(message)")
  guard process.terminationStatus == 0 else { return }

  #expect(
    try Data(contentsOf: output.appendingPathComponent("source/notes.txt"))
      == Data("recovered text".utf8))
  #expect(
    try Data(contentsOf: output.appendingPathComponent("source/nested/bytes.bin"))
      == Data([0, 1, 2, 255]))
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}
