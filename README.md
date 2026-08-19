# Encrypted Folder

Finder for an encrypted folder. No mount, no container, no plaintext temp files.

> [!WARNING]
> This is new software with a new file format. Keep backups of the whole vault, especially `encrypted-folder.json`. Lose that file and the ciphertext is decorative.

## Build it

Requires macOS 15 or newer and Xcode 26.

```sh
$ make run
swift build -c release --product EncryptedFolder
Built build/Encrypted Folder.app
# ^^ signed, sandboxed, opened
```

Pick an empty folder, choose a password, then drag files in. Drag them back to Finder to export. Images, PDFs, audio and video stay inside the app while viewing.

## What it does not do

- It does not mount a filesystem.
- It does not sync anything. Put the vault in iCloud, Dropbox, rsync or whatever already disappoints you least.
- It does not hand plaintext to Quick Look. Apple's API doesn't promise the cache/process boundary this app requires.
- It is not gocryptfs-compatible. The per-file format is documented in [`FORMAT.md`](FORMAT.md).

Touch ID stores the vault's master key in the device-only data-protection Keychain. The password is never stored.

## Develop it

```sh
$ make test
Test run with 4 tests in 0 suites passed.

$ make install
Installed /Applications/Encrypted Folder.app
# ^^ Developer ID signed, notarized and stapled
```

`make install` is the maintainer path: it expects Max's Developer ID certificate and injects `APPLE_USERNAME` and `APPLE_PASSWORD` with Automic Vault.
