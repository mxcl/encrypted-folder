#!/usr/bin/xcrun swift

// Encrypted Folder format v1 recovery tool.
// Double-click this file, or run: xcrun swift RECOVER.command [output-directory]
// Requires Apple's free Command Line Tools. Anyone able to replace this file can
// steal the password you enter; use a trusted copy if the vault may be compromised.

import CommonCrypto
import CryptoKit
import Darwin
import Foundation

let configFileName = "encrypted-folder.json"
let recoveryFileName = "RECOVER.command"
let directoryMarker = ".encrypted-folder-directory"
let chunkSize = 1_048_576
let headerSize = 64
let chunkOverhead = 28
let magic = Data("EFV1".utf8)

struct VaultConfig: Decodable {
  let format: String
  let version: Int
  let rootDirectoryID: Data
  let salt: Data
  let iterations: Int
  let wrappedMasterKey: Data
}

struct RecoveryFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

func readPassword() throws -> String {
  var buffer = [CChar](repeating: 0, count: 16_384)
  defer {
    buffer.withUnsafeMutableBytes { bytes in
      _ = bytes.initializeMemory(as: UInt8.self, repeating: 0)
    }
  }
  let result = buffer.withUnsafeMutableBufferPointer {
    readpassphrase("Vault password: ", $0.baseAddress, $0.count, 0)
  }
  guard result != nil, let password = String(validatingCString: buffer) else {
    throw RecoveryFailure("Could not read the password.")
  }
  return password
}

func unlock(_ config: VaultConfig, password: String) throws -> SymmetricKey {
  guard config.format == "encrypted-folder", config.version == 1,
    config.rootDirectoryID.count == 16, config.salt.count == 32,
    config.wrappedMasterKey.count == 60,
    (1_000...5_000_000).contains(config.iterations)
  else {
    throw RecoveryFailure("This is not a supported Encrypted Folder v1 vault.")
  }

  var passwordBytes = Array(password.utf8)
  defer { passwordBytes.resetBytes(in: passwordBytes.indices) }
  var derivedKey = Data(count: 32)
  defer { derivedKey.resetBytes(in: derivedKey.indices) }
  let status = derivedKey.withUnsafeMutableBytes { output in
    config.salt.withUnsafeBytes { salt in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        passwordBytes,
        passwordBytes.count,
        salt.bindMemory(to: UInt8.self).baseAddress,
        config.salt.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
        UInt32(config.iterations),
        output.bindMemory(to: UInt8.self).baseAddress,
        derivedKey.count
      )
    }
  }
  guard status == kCCSuccess else { throw RecoveryFailure("Password derivation failed.") }

  do {
    let box = try AES.GCM.SealedBox(combined: config.wrappedMasterKey)
    let masterKey = try AES.GCM.open(box, using: SymmetricKey(data: derivedKey))
    guard masterKey.count == 32 else { throw RecoveryFailure("The vault key is damaged.") }
    return SymmetricKey(data: masterKey)
  } catch {
    throw RecoveryFailure("The password is incorrect, or encrypted-folder.json is damaged.")
  }
}

func derivedKey(masterKey: SymmetricKey, salt: Data, purpose: String) -> SymmetricKey {
  HKDF<SHA256>.deriveKey(
    inputKeyMaterial: masterKey,
    salt: salt,
    info: Data("encrypted-folder/\(purpose)/v1".utf8),
    outputByteCount: 32
  )
}

func decryptName(_ encryptedName: String, directoryID: Data, masterKey: SymmetricKey) throws
  -> String
{
  guard let combined = Data(base64URLEncoded: encryptedName) else {
    throw RecoveryFailure("A filename is not valid Encrypted Folder data.")
  }
  do {
    let box = try AES.GCM.SealedBox(combined: combined)
    let plaintext = try AES.GCM.open(
      box,
      using: derivedKey(masterKey: masterKey, salt: directoryID, purpose: "name"),
      authenticating: directoryID
    )
    guard let name = String(data: plaintext, encoding: .utf8),
      !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0")
    else {
      throw RecoveryFailure("A decrypted filename is unsafe.")
    }
    return name
  } catch let error as RecoveryFailure {
    throw error
  } catch {
    throw RecoveryFailure("A filename is damaged or has been modified.")
  }
}

func readDirectoryID(at directory: URL) throws -> Data {
  let marker = directory.appendingPathComponent(directoryMarker)
  let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
  guard values.isRegularFile == true, values.isSymbolicLink != true else {
    throw RecoveryFailure("A directory marker is missing or unsafe.")
  }
  let data = try Data(contentsOf: marker)
  guard data.count == 16 else { throw RecoveryFailure("A directory marker is damaged.") }
  return data
}

func decryptFile(_ source: URL, to destination: URL, masterKey: SymmetricKey) throws {
  let input = try FileHandle(forReadingFrom: source)
  defer { try? input.close() }
  let header = try input.read(upToCount: headerSize) ?? Data()
  guard header.count == headerSize,
    header.prefix(4) == magic,
    let plainSize = UInt64(bigEndianData: header[20..<28]),
    UInt32(bigEndianData: header[28..<32]) == UInt32(chunkSize)
  else {
    throw RecoveryFailure("An encrypted file has an invalid header.")
  }

  let fileID = Data(header[4..<20])
  let contentKey = derivedKey(masterKey: masterKey, salt: fileID, purpose: "content")
  let headerKey = derivedKey(masterKey: masterKey, salt: fileID, purpose: "header")
  guard HMAC<SHA256>.isValidAuthenticationCode(
    header.suffix(32), authenticating: header.prefix(32), using: headerKey)
  else {
    throw RecoveryFailure("An encrypted file header is damaged or has been modified.")
  }

  let chunkCount = plainSize == 0 ? 0 : (plainSize - 1) / UInt64(chunkSize) + 1
  let (overhead, overheadOverflow) = chunkCount.multipliedReportingOverflow(
    by: UInt64(chunkOverhead))
  let (payloadSize, payloadOverflow) = plainSize.addingReportingOverflow(overhead)
  let (expectedSize, sizeOverflow) = UInt64(headerSize).addingReportingOverflow(payloadSize)
  guard plainSize <= UInt64(Int64.max),
    !overheadOverflow, !payloadOverflow, !sizeOverflow,
    try input.seekToEnd() == expectedSize
  else {
    throw RecoveryFailure("An encrypted file has an invalid size.")
  }

  let temporary = destination.appendingPathExtension("partial")
  guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
    throw RecoveryFailure("Could not create \(temporary.path).")
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
  let output = try FileHandle(forWritingTo: temporary)
  do {
    var remaining = plainSize
    var index: UInt64 = 0
    while remaining > 0 {
      let plaintextLength = Int(min(UInt64(chunkSize), remaining))
      let encryptedLength = plaintextLength + chunkOverhead
      let encryptedOffset = UInt64(headerSize) + index * UInt64(chunkSize + chunkOverhead)
      try input.seek(toOffset: encryptedOffset)
      let combined = try input.read(upToCount: encryptedLength) ?? Data()
      guard combined.count == encryptedLength else {
        throw RecoveryFailure("An encrypted file ended unexpectedly.")
      }
      let box = try AES.GCM.SealedBox(combined: combined)
      let plaintext = try AES.GCM.open(
        box, using: contentKey, authenticating: header + index.bigEndianData)
      try output.write(contentsOf: plaintext)
      remaining -= UInt64(plaintextLength)
      index += 1
    }
    try output.synchronize()
    try output.close()
    try FileManager.default.moveItem(at: temporary, to: destination)
  } catch {
    try? output.close()
    try? FileManager.default.removeItem(at: temporary)
    throw RecoveryFailure("An encrypted file is damaged or has been modified.")
  }
}

func recoverDirectory(
  _ source: URL,
  directoryID: Data,
  to destination: URL,
  masterKey: SymmetricKey,
  fileCount: inout Int
) throws {
  let entries = try FileManager.default.contentsOfDirectory(
    at: source,
    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
    options: [.skipsHiddenFiles]
  )
  for entry in entries {
    guard entry.lastPathComponent != configFileName,
      entry.lastPathComponent != recoveryFileName,
      entry.pathExtension != "partial"
    else { continue }

    let values = try entry.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isSymbolicLink != true,
      values.isDirectory == true || values.isRegularFile == true
    else {
      throw RecoveryFailure("The vault contains an unsupported filesystem entry.")
    }

    let name = try decryptName(
      entry.lastPathComponent, directoryID: directoryID, masterKey: masterKey)
    let output = destination.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw RecoveryFailure("Two recovered items would overwrite \(output.path).")
    }

    if values.isDirectory == true {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
      try recoverDirectory(
        entry,
        directoryID: readDirectoryID(at: entry),
        to: output,
        masterKey: masterKey,
        fileCount: &fileCount
      )
    } else {
      try decryptFile(entry, to: output, masterKey: masterKey)
      fileCount += 1
    }
  }
}

func main() throws {
  guard CommandLine.arguments.count <= 2 else {
    throw RecoveryFailure("Usage: RECOVER.command [output-directory]")
  }
  let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  let vault = script.deletingLastPathComponent()
  let output: URL
  if CommandLine.arguments.count == 2 {
    output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
  } else {
    output = vault.deletingLastPathComponent().appendingPathComponent(
      vault.lastPathComponent + "-decrypted")
  }

  guard output.path != vault.path, !output.path.hasPrefix(vault.path + "/") else {
    throw RecoveryFailure("The plaintext output directory must be outside the encrypted vault.")
  }
  guard !FileManager.default.fileExists(atPath: output.path) else {
    throw RecoveryFailure("Refusing to overwrite existing output at \(output.path).")
  }

  let configURL = vault.appendingPathComponent(configFileName)
  let config = try JSONDecoder().decode(VaultConfig.self, from: Data(contentsOf: configURL))
  print("Encrypted vault: \(vault.path)")
  print("Plaintext output: \(output.path)")
  let masterKey = try unlock(config, password: readPassword())

  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
  do {
    var fileCount = 0
    try recoverDirectory(
      vault,
      directoryID: config.rootDirectoryID,
      to: output,
      masterKey: masterKey,
      fileCount: &fileCount
    )
    print("Recovered \(fileCount) file\(fileCount == 1 ? "" : "s") to \(output.path)")
  } catch {
    try? FileManager.default.removeItem(at: output)
    throw error
  }
}

extension FixedWidthInteger {
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

extension Data {
  init?(base64URLEncoded string: String) {
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }
}

do {
  try main()
} catch {
  fputs("Recovery failed: \(error.localizedDescription)\n", stderr)
  exit(EXIT_FAILURE)
}
