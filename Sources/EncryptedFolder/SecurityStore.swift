import Foundation
import LocalAuthentication
import Security

enum SecurityStoreError: LocalizedError {
  case keychain(OSStatus)
  case bookmark

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    case .bookmark:
      "The app no longer has permission to open this vault."
    }
  }
}

struct VaultKeychain {
  private static let service = "dev.mxcl.encrypted-folder.master-key"

  static var touchIDAvailable: Bool {
    let context = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
      && context.biometryType == .touchID
  }

  static func contains(vaultID: UUID) -> Bool {
    var query = baseQuery(vaultID: vaultID)
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
  }

  static func save(_ data: Data, vaultID: UUID) throws {
    let base = baseQuery(vaultID: vaultID)
    var query = base
    let context = LAContext()
    context.localizedReason = "Update the Touch ID key for this encrypted folder"
    query[kSecUseAuthenticationContext as String] = context
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw SecurityStoreError.keychain(updateStatus)
    }

    var accessError: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        .biometryCurrentSet,
        &accessError
      )
    else {
      if let accessError { throw accessError.takeRetainedValue() }
      throw SecurityStoreError.bookmark
    }
    var add = base
    add[kSecAttrAccessControl as String] = accessControl
    add[kSecValueData as String] = data
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw SecurityStoreError.keychain(addStatus) }
  }

  static func read(vaultID: UUID, context: LAContext) throws -> Data {
    context.localizedFallbackTitle = "Use Password"
    context.localizedReason = "Unlock this encrypted folder"
    var query = baseQuery(vaultID: vaultID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
      throw SecurityStoreError.keychain(status)
    }
    return data
  }

  static func delete(vaultID: UUID) throws {
    let status = SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecurityStoreError.keychain(status)
    }
  }

  private static func baseQuery(vaultID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: vaultID.uuidString,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}

final class ScopedVaultAccess {
  let url: URL
  private let shouldStop: Bool

  init(panelURL: URL) {
    self.url = panelURL
    self.shouldStop = true
  }

  init(bookmarkURL: URL) throws {
    guard bookmarkURL.startAccessingSecurityScopedResource() else {
      throw SecurityStoreError.bookmark
    }
    self.url = bookmarkURL
    self.shouldStop = true
  }

  deinit {
    if shouldStop { url.stopAccessingSecurityScopedResource() }
  }
}

enum VaultBookmarkStore {
  static func save(_ url: URL) throws {
    let data = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: bookmarkURL, options: [.atomic, .completeFileProtection])
  }

  static func resolve() throws -> URL? {
    guard let data = try? Data(contentsOf: bookmarkURL) else { return nil }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: .withSecurityScope,
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    if stale { try save(url) }
    return url
  }

  private static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EncryptedFolder", isDirectory: true)
  }

  private static var bookmarkURL: URL {
    directory.appendingPathComponent("vault.bookmark")
  }
}
