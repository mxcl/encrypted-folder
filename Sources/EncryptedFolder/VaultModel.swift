import AppKit
import EncryptedFolderCore
import Foundation
import Observation
import UniformTypeIdentifiers

struct DirectoryChoice: Identifiable, Hashable {
  var id: URL { url }
  let name: String
  let url: URL
}

@Observable @MainActor
final class VaultModel {
  private(set) var vault: Vault?
  private(set) var vaultURL: URL?
  private(set) var currentDirectory: URL?
  private(set) var path: [DirectoryChoice] = []
  private(set) var items: [VaultItem] = []
  var selection: Set<URL> = []
  var password = ""
  var confirmedPassword = ""
  var rememberWithTouchID = false
  private(set) var isCreating = false
  private(set) var isBusy = false
  private(set) var hasStoredKey = false
  var errorMessage: String?

  var selectedItems: [VaultItem] { items.filter { selection.contains($0.id) } }
  var selectedItem: VaultItem? { selectedItems.count == 1 ? selectedItems[0] : nil }
  var touchIDAvailable: Bool { VaultKeychain.touchIDAvailable }

  private var access: ScopedVaultAccess?
  private var selectedVaultID: UUID?

  init() {
    do {
      if let url = try VaultBookmarkStore.resolve() {
        access = try ScopedVaultAccess(bookmarkURL: url)
        try selectExistingVault(at: url)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func chooseVault(create: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = create ? "Create Vault" : "Open Vault"
    panel.message = create ? "Choose an empty folder." : "Choose an Encrypted Folder vault."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try VaultBookmarkStore.save(url)
      access = ScopedVaultAccess(panelURL: url)
      vaultURL = url
      isCreating = create
      selectedVaultID = nil
      hasStoredKey = false
      password = ""
      confirmedPassword = ""
      if !create { try selectExistingVault(at: url) }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func unlockWithPassword() {
    guard let vaultURL, !password.isEmpty else { return }
    guard !isCreating || password == confirmedPassword else {
      errorMessage = "The passwords do not match."
      return
    }
    let password = password
    let create = isCreating
    isBusy = true
    Task {
      do {
        let opened = try await Task.detached {
          create
            ? try Vault.create(at: vaultURL, password: password)
            : try Vault.open(at: vaultURL, password: password)
        }.value
        try finishUnlock(opened)
      } catch {
        errorMessage = error.localizedDescription
      }
      self.password = ""
      confirmedPassword = ""
      isBusy = false
    }
  }

  func unlockWithTouchID() {
    guard let vaultURL, let selectedVaultID else { return }
    isBusy = true
    Task {
      do {
        let opened = try await Task.detached {
          let key = try VaultKeychain.read(vaultID: selectedVaultID)
          return try Vault.open(at: vaultURL, masterKeyData: key)
        }.value
        try finishUnlock(opened)
      } catch {
        errorMessage = error.localizedDescription
      }
      isBusy = false
    }
  }

  func lock() {
    vault = nil
    currentDirectory = nil
    items = []
    selection = []
    path = []
    password = ""
    confirmedPassword = ""
  }

  func forgetTouchID() {
    guard let selectedVaultID else { return }
    do {
      try VaultKeychain.delete(vaultID: selectedVaultID)
      hasStoredKey = false
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func enter(_ item: VaultItem) {
    guard item.isDirectory else { return }
    currentDirectory = item.encryptedURL
    path.append(DirectoryChoice(name: item.name, url: item.encryptedURL))
    reload()
  }

  func navigate(to choice: DirectoryChoice) {
    guard let index = path.firstIndex(of: choice) else { return }
    path.removeSubrange(path.index(after: index)..<path.endIndex)
    currentDirectory = choice.url
    reload()
  }

  func reload() {
    guard let vault, let currentDirectory else { return }
    do {
      items = try vault.items(in: currentDirectory)
      selection.formIntersection(Set(items.map(\.id)))
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importPanel() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Import"
    guard panel.runModal() == .OK else { return }
    importItems(at: panel.urls)
  }

  func importItems(at urls: [URL]) {
    guard let vault, let currentDirectory, !urls.isEmpty else { return }
    isBusy = true
    Task {
      do {
        try await Task.detached {
          defer {
            for url in urls { url.stopAccessingSecurityScopedResource() }
          }
          for url in urls { _ = try vault.importItem(at: url, into: currentDirectory) }
        }.value
        reload()
      } catch {
        errorMessage = error.localizedDescription
      }
      isBusy = false
    }
  }

  func exportSelected() {
    guard let vault, !selectedItems.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Export Here"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    let selectedItems = selectedItems
    isBusy = true
    Task {
      do {
        try await Task.detached {
          defer { destination.stopAccessingSecurityScopedResource() }
          for item in selectedItems { try vault.export(item, to: destination) }
        }.value
      } catch {
        errorMessage = error.localizedDescription
      }
      isBusy = false
    }
  }

  func createFolder(named name: String) {
    guard let vault, let currentDirectory else { return }
    do {
      let item = try vault.createFolder(named: name, in: currentDirectory)
      reload()
      selection = [item.id]
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func promptCreateFolder() {
    if let name = promptForName(title: "New Folder", value: "untitled folder") {
      createFolder(named: name)
    }
  }

  func renameSelected(to name: String) {
    guard let vault, let item = selectedItem else { return }
    do {
      let renamed = try vault.rename(item, to: name)
      reload()
      selection = [renamed.id]
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func promptRename() {
    guard let item = selectedItem,
      let name = promptForName(title: "Rename \(item.name)", value: item.name)
    else { return }
    renameSelected(to: name)
  }

  func deleteSelected() {
    guard let vault, !selectedItems.isEmpty else { return }
    let selectedItems = selectedItems
    do {
      for item in selectedItems { try vault.delete(item) }
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func confirmDelete() {
    guard !selectedItems.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText =
      selectedItems.count == 1
      ? "Delete \(selectedItems[0].name)?" : "Delete \(selectedItems.count) items?"
    alert.informativeText =
      "This removes the encrypted data immediately. This action cannot be undone."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    deleteSelected()
  }

  func moveSelected(to destination: URL) {
    guard let vault, let item = selectedItem else { return }
    do {
      _ = try vault.move(item, into: destination)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func directoryChoices() -> [DirectoryChoice] {
    guard let vault else { return [] }
    var result: [DirectoryChoice] = [
      DirectoryChoice(name: vault.rootURL.lastPathComponent, url: vault.rootURL)
    ]
    func appendChildren(of directory: URL, prefix: String) throws {
      for item in try vault.items(in: directory) where item.isDirectory {
        if item.id == selectedItem?.id { continue }
        let choice = DirectoryChoice(name: prefix + item.name, url: item.encryptedURL)
        result.append(choice)
        try appendChildren(of: item.encryptedURL, prefix: prefix + item.name + " / ")
      }
    }
    do {
      try appendChildren(of: vault.rootURL, prefix: "")
    } catch {
      errorMessage = error.localizedDescription
    }
    return result
  }

  func promptMove() {
    let choices = directoryChoices().filter { $0.url != currentDirectory }
    guard !choices.isEmpty else { return }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    popup.addItems(withTitles: choices.map(\.name))
    let alert = NSAlert()
    alert.messageText = "Move \(selectedItem?.name ?? "Item")"
    alert.accessoryView = popup
    alert.addButton(withTitle: "Move")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 else {
      return
    }
    moveSelected(to: choices[popup.indexOfSelectedItem].url)
  }

  private func selectExistingVault(at url: URL) throws {
    let config = try JSONDecoder().decode(
      VaultConfig.self,
      from: Data(contentsOf: url.appendingPathComponent(VaultConfig.fileName))
    )
    vaultURL = url
    selectedVaultID = config.id
    hasStoredKey = VaultKeychain.contains(vaultID: config.id)
    isCreating = false
  }

  private func finishUnlock(_ opened: Vault) throws {
    vault = opened
    selectedVaultID = opened.id
    isCreating = false
    currentDirectory = opened.rootURL
    path = [DirectoryChoice(name: opened.rootURL.lastPathComponent, url: opened.rootURL)]
    items = try opened.items(in: opened.rootURL)
    selection = []
    if rememberWithTouchID {
      try VaultKeychain.save(opened.masterKeyData, vaultID: opened.id)
      hasStoredKey = true
    }
  }

  private func promptForName(title: String, value: String) -> String? {
    let field = NSTextField(string: value)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    let alert = NSAlert()
    alert.messageText = title
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}
