import Foundation
import Security

let dataProtection = CommandLine.arguments.contains("--data-protection")
let service = "dev.mxcl.encrypted-folder.probe.\(UUID().uuidString)"
var error: Unmanaged<CFError>?
guard let access = SecAccessControlCreateWithFlags(
  nil,
  kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
  .biometryCurrentSet,
  &error
) else {
  print(error?.takeRetainedValue().localizedDescription ?? "access control failed")
  exit(2)
}

var query: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: service,
  kSecAttrAccount as String: "probe",
  kSecAttrAccessControl as String: access,
  kSecValueData as String: Data("probe".utf8),
]
if dataProtection {
  query[kSecUseDataProtectionKeychain as String] = true
}

let status = SecItemAdd(query as CFDictionary, nil)
print("status=\(status) \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")")
if status == errSecSuccess {
  query.removeValue(forKey: kSecAttrAccessControl as String)
  query.removeValue(forKey: kSecValueData as String)
  SecItemDelete(query as CFDictionary)
}
exit(status == errSecSuccess ? 0 : 1)
