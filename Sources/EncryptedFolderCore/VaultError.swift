import Foundation

public enum VaultError: LocalizedError, Equatable {
    case invalidVault
    case wrongPassword
    case damagedFile
    case nameTooLong
    case unsupportedFile

    public var errorDescription: String? {
        switch self {
        case .invalidVault: "This folder is not an Encrypted Folder vault."
        case .wrongPassword: "The password is incorrect."
        case .damagedFile: "The encrypted file is damaged or has been modified."
        case .nameTooLong: "The encrypted filename would exceed the filesystem limit."
        case .unsupportedFile: "This file type cannot be viewed without exposing plaintext."
        }
    }
}
