import Testing

@testable import EncryptedFolderCore

@Test func errorsHaveDescriptions() {
  #expect(VaultError.wrongPassword.errorDescription == "The password is incorrect.")
}
