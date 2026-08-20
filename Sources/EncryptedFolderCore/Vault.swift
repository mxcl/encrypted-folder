import CryptoKit
import Foundation

public struct VaultItem: Identifiable, Hashable, Sendable {
  public var id: URL { encryptedURL }
  public let name: String
  public let isDirectory: Bool
  public let byteSize: UInt64?
  public let encryptedURL: URL

  fileprivate let parentDirectoryID: Data
}

public final class Vault: @unchecked Sendable {
  public static let directoryMarker = ".encrypted-folder-directory"
  public static let recoveryFileName = "RECOVER.command"

  public let rootURL: URL
  public let id: UUID

  private let config: VaultConfig
  private let cryptor: VaultCryptor
  private let masterKey: SymmetricKey
  private let fileManager = FileManager.default

  private init(rootURL: URL, config: VaultConfig, masterKey: SymmetricKey) {
    self.rootURL = rootURL.standardizedFileURL
    self.id = config.id
    self.config = config
    self.masterKey = masterKey
    self.cryptor = VaultCryptor(masterKey: masterKey)
  }

  public static func create(at url: URL, password: String) throws -> Vault {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    guard try fileManager.contentsOfDirectory(atPath: url.path).isEmpty else {
      throw VaultError.invalidVault
    }
    let (config, masterKey) = try VaultConfig.create(password: password)
    let configURL = url.appendingPathComponent(VaultConfig.fileName)
    let recoveryURL = url.appendingPathComponent(Self.recoveryFileName)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try encoder.encode(config).write(to: configURL, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
      guard
        let bundledRecovery = Bundle.main.url(
          forResource: "RECOVER", withExtension: "command")
          ?? Bundle.module.url(forResource: "RECOVER", withExtension: "command")
      else { throw VaultError.invalidVault }
      try Data(contentsOf: bundledRecovery).write(to: recoveryURL, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryURL.path)
      return Vault(rootURL: url, config: config, masterKey: masterKey)
    } catch {
      try? fileManager.removeItem(at: configURL)
      try? fileManager.removeItem(at: recoveryURL)
      throw error
    }
  }

  public static func open(at url: URL, password: String) throws -> Vault {
    let configURL = url.appendingPathComponent(VaultConfig.fileName)
    guard
      (try? configURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
        $0.isRegularFile == true && $0.isSymbolicLink != true
      }) == true,
      let config = try? JSONDecoder().decode(VaultConfig.self, from: Data(contentsOf: configURL))
    else {
      throw VaultError.invalidVault
    }
    return Vault(rootURL: url, config: config, masterKey: try config.unlock(password: password))
  }

  public static func open(at url: URL, masterKeyData: Data) throws -> Vault {
    let configURL = url.appendingPathComponent(VaultConfig.fileName)
    guard
      (try? configURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
        $0.isRegularFile == true && $0.isSymbolicLink != true
      }) == true,
      let config = try? JSONDecoder().decode(VaultConfig.self, from: Data(contentsOf: configURL)),
      masterKeyData.count == 32
    else {
      throw VaultError.invalidVault
    }
    return Vault(rootURL: url, config: config, masterKey: SymmetricKey(data: masterKeyData))
  }

  public var masterKeyData: Data {
    masterKey.withUnsafeBytes { Data($0) }
  }

  public func items(in directory: URL) throws -> [VaultItem] {
    let directoryID = try self.directoryID(at: directory)
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url in
      guard url.lastPathComponent != VaultConfig.fileName,
        url.lastPathComponent != Self.recoveryFileName,
        url.lastPathComponent != Self.directoryMarker,
        url.pathExtension != "partial"
      else { return nil }
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isSymbolicLink != true,
        values.isDirectory == true || values.isRegularFile == true
      else { return nil }
      let name = try cryptor.decryptName(url.lastPathComponent, directoryID: directoryID)
      let size = values.isDirectory == true ? nil : try cryptor.reader(for: url).plainSize
      return VaultItem(
        name: name,
        isDirectory: values.isDirectory == true,
        byteSize: size,
        encryptedURL: url,
        parentDirectoryID: directoryID
      )
    }
    .sorted {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  @discardableResult
  public func createFolder(named name: String, in parent: URL) throws -> VaultItem {
    try ensureAvailable(name, in: parent)
    let parentID = try directoryID(at: parent)
    let destination = try availableEncryptedURL(for: name, in: parent, directoryID: parentID)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
      try Self.randomData(count: 16).write(
        to: destination.appendingPathComponent(Self.directoryMarker),
        options: .atomic
      )
      return VaultItem(
        name: name, isDirectory: true, byteSize: nil, encryptedURL: destination,
        parentDirectoryID: parentID)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  @discardableResult
  public func importItem(at source: URL, into parent: URL) throws -> VaultItem {
    let values = try source.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isSymbolicLink != true else { throw VaultError.unsupportedFile }
    let name = source.lastPathComponent
    try ensureAvailable(name, in: parent)
    if values.isDirectory == true {
      let folder = try createFolder(named: name, in: parent)
      do {
        for child in try fileManager.contentsOfDirectory(
          at: source,
          includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
          options: []
        ) {
          _ = try importItem(at: child, into: folder.encryptedURL)
        }
        return folder
      } catch {
        try? fileManager.removeItem(at: folder.encryptedURL)
        throw error
      }
    }
    guard values.isRegularFile == true else { throw VaultError.unsupportedFile }
    let parentID = try directoryID(at: parent)
    let destination = try availableEncryptedURL(for: name, in: parent, directoryID: parentID)
    try cryptor.encryptFile(from: source, to: destination)
    return VaultItem(
      name: name,
      isDirectory: false,
      byteSize: try cryptor.reader(for: destination).plainSize,
      encryptedURL: destination,
      parentDirectoryID: parentID
    )
  }

  public func export(_ item: VaultItem, to destinationDirectory: URL) throws {
    let destination = destinationDirectory.appendingPathComponent(item.name)
    guard !fileManager.fileExists(atPath: destination.path) else { throw VaultError.alreadyExists }
    if item.isDirectory {
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
      do {
        for child in try items(in: item.encryptedURL) {
          try export(child, to: destination)
        }
      } catch {
        try? fileManager.removeItem(at: destination)
        throw error
      }
      return
    }
    let temporary = destination.appendingPathExtension("partial")
    fileManager.createFile(atPath: temporary.path, contents: nil)
    let output = try FileHandle(forWritingTo: temporary)
    do {
      let reader = try cryptor.reader(for: item.encryptedURL)
      var offset: UInt64 = 0
      while offset < reader.plainSize {
        let data = try reader.read(offset: offset, length: VaultCryptor.chunkSize)
        try output.write(contentsOf: data)
        offset += UInt64(data.count)
      }
      try output.synchronize()
      try output.close()
      try fileManager.moveItem(at: temporary, to: destination)
    } catch {
      try? output.close()
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }

  public func delete(_ item: VaultItem) throws {
    try fileManager.removeItem(at: item.encryptedURL)
  }

  @discardableResult
  public func rename(_ item: VaultItem, to newName: String) throws -> VaultItem {
    let parent = item.encryptedURL.deletingLastPathComponent()
    try ensureAvailable(newName, in: parent, excluding: item)
    let destination = try availableEncryptedURL(
      for: newName, in: parent, directoryID: item.parentDirectoryID)
    try fileManager.moveItem(at: item.encryptedURL, to: destination)
    return VaultItem(
      name: newName,
      isDirectory: item.isDirectory,
      byteSize: item.byteSize,
      encryptedURL: destination,
      parentDirectoryID: item.parentDirectoryID
    )
  }

  @discardableResult
  public func move(_ item: VaultItem, into destinationDirectory: URL) throws -> VaultItem {
    if item.isDirectory,
      destinationDirectory.standardizedFileURL.path.hasPrefix(
        item.encryptedURL.standardizedFileURL.path + "/")
    {
      throw VaultError.unsupportedFile
    }
    try ensureAvailable(item.name, in: destinationDirectory)
    let destinationID = try directoryID(at: destinationDirectory)
    let destination = try availableEncryptedURL(
      for: item.name, in: destinationDirectory, directoryID: destinationID)
    try fileManager.moveItem(at: item.encryptedURL, to: destination)
    return VaultItem(
      name: item.name,
      isDirectory: item.isDirectory,
      byteSize: item.byteSize,
      encryptedURL: destination,
      parentDirectoryID: destinationID
    )
  }

  public func reader(for item: VaultItem) throws -> EncryptedFileReader {
    guard !item.isDirectory else { throw VaultError.unsupportedFile }
    return try cryptor.reader(for: item.encryptedURL)
  }

  private func directoryID(at url: URL) throws -> Data {
    if url.standardizedFileURL == rootURL { return config.rootDirectoryID }
    let marker = url.appendingPathComponent(Self.directoryMarker)
    let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw VaultError.damagedFile
    }
    let data = try Data(contentsOf: marker)
    guard data.count == 16 else { throw VaultError.damagedFile }
    return data
  }

  private func ensureAvailable(_ name: String, in directory: URL, excluding: VaultItem? = nil)
    throws
  {
    guard
      try !items(in: directory).contains(where: {
        $0.id != excluding?.id
          && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
      })
    else {
      throw VaultError.alreadyExists
    }
  }

  private func availableEncryptedURL(for name: String, in directory: URL, directoryID: Data) throws
    -> URL
  {
    for _ in 0..<4 {
      let url = directory.appendingPathComponent(
        try cryptor.encryptName(name, directoryID: directoryID))
      if !fileManager.fileExists(atPath: url.path) { return url }
    }
    throw VaultError.alreadyExists
  }

  private static func randomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }
}
