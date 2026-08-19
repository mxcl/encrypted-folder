# Encrypted Folder format v1

This is a native per-file format, not a partial gocryptfs implementation. A vault contains:

```text
encrypted-folder.json
<base64url encrypted name>
<base64url encrypted directory>/
  .encrypted-folder-directory
  <base64url encrypted name>
```

`encrypted-folder.json` stores a random 256-bit master key wrapped with AES-256-GCM. The wrapping key is PBKDF2-HMAC-SHA256(password, 32-byte salt, 600,000 iterations). The config also stores the vault UUID and root directory ID. Touch ID, when enabled, stores the unwrapped master key in the device-only data-protection Keychain; it never stores the password.

Each directory has a random 16-byte ID. Names are UTF-8 encrypted with AES-256-GCM using an HKDF-SHA256 key derived from the master key and directory ID, then encoded as unpadded base64url. The directory ID is authenticated as associated data. Ciphertext names longer than 240 UTF-8 bytes are rejected instead of creating sidecar files.

Each encrypted regular file has a 64-byte header:

| Offset | Size | Value |
| ---: | ---: | --- |
| 0 | 4 | `EFV1` |
| 4 | 16 | random file ID |
| 20 | 8 | plaintext size, big-endian |
| 28 | 4 | chunk size, big-endian (`1,048,576`) |
| 32 | 32 | HMAC-SHA256 over bytes 0–31 |

Content follows as independent AES-256-GCM chunks. Each stored chunk is CryptoKit's combined representation: a 12-byte random nonce, up to 1 MiB of ciphertext, and a 16-byte authentication tag. Its associated data is the complete header followed by the chunk index as a big-endian `UInt64`. Content and header-authentication keys are separately derived with HKDF-SHA256 from the master key and file ID.

One logical file changes only its ciphertext file. Renames and moves change only the encrypted directory entry. Directories add their 16-byte marker. Symlinks and special files are rejected; filesystem metadata is not preserved.
