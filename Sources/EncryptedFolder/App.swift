import CoreTransferable
import EncryptedFolderCore
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
  static let vaultItems = UTType(exportedAs: "dev.mxcl.encrypted-folder.items")
}

private struct VaultItemTransfer: Codable, Transferable {
  let vaultID: UUID
  let itemURLs: [URL]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .vaultItems)
      .visibility(.ownProcess)
  }
}

@main
struct EncryptedFolderApp: App {
  @State private var model = VaultModel()

  var body: some Scene {
    Window("Encrypted Folder", id: "main") {
      RootView(model: model)
        .frame(minWidth: 820, minHeight: 520)
        .focusedSceneValue(\.vaultModel, model)
    }
    .windowStyle(.titleBar)
    .commands {
      SidebarCommands()
      VaultCommands()
    }
  }
}

private struct RootView: View {
  @Bindable var model: VaultModel

  var body: some View {
    Group {
      if let vault = model.vault {
        BrowserView(model: model, vault: vault)
      } else if model.vaultURL != nil {
        UnlockView(model: model)
      } else {
        WelcomeView(model: model)
      }
    }
    .overlay {
      if model.isBusy {
        ZStack {
          Color.black.opacity(0.12)
          ProgressView()
            .controlSize(.large)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
      }
    }
    .alert(
      "Encrypted Folder",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

private struct WelcomeView: View {
  let model: VaultModel

  var body: some View {
    ContentUnavailableView {
      Label("Encrypted Folder", systemImage: "lock.square")
    } description: {
      Text("Finder for a folder whose contents and names stay encrypted.")
    } actions: {
      HStack {
        Button("Open Vault…") { model.chooseVault(create: false) }
        Button("New Vault…") { model.chooseVault(create: true) }
          .buttonStyle(.borderedProminent)
      }
    }
  }
}

private struct UnlockView: View {
  @Bindable var model: VaultModel
  @State private var authenticationContext = LAContext()

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: model.isCreating ? "folder.badge.plus" : "lock.square")
        .font(.system(size: 52))
        .foregroundStyle(.secondary)
      Text(
        model.isCreating ? "Create Vault" : "Unlock \(model.vaultURL?.lastPathComponent ?? "Vault")"
      )
      .font(.title2)
      if model.hasStoredKey {
        LocalAuthenticationView(
          "Unlock with Touch ID",
          reason: Text("Unlock this encrypted folder"),
          context: authenticationContext
        ) { result in
          if case .success = result {
            model.unlockWithTouchID(context: authenticationContext)
          }
        }
      }
      VStack(spacing: 12) {
        SecureField("Password", text: $model.password)
          .textFieldStyle(.roundedBorder)
          .onSubmit(model.unlockWithPassword)
        if model.isCreating {
          SecureField("Confirm password", text: $model.confirmedPassword)
            .textFieldStyle(.roundedBorder)
            .onSubmit(model.unlockWithPassword)
        }
        if model.touchIDAvailable {
          Toggle("Store the key for Touch ID", isOn: $model.rememberWithTouchID)
        }
      }
      .frame(width: 320)
      HStack {
        Button(model.isCreating ? "Create" : "Unlock", action: model.unlockWithPassword)
          .buttonStyle(.borderedProminent)
          .disabled(model.password.isEmpty || (model.isCreating && model.confirmedPassword.isEmpty))
      }
      HStack {
        Button("Choose Another…") { model.chooseVault(create: false) }
          .buttonStyle(.link)
        Button("New Vault…") { model.chooseVault(create: true) }
          .buttonStyle(.link)
        if model.hasStoredKey {
          Button("Forget Touch ID", action: model.forgetTouchID)
            .buttonStyle(.link)
        }
      }
    }
    .padding(40)
  }
}

private struct BrowserView: View {
  @Bindable var model: VaultModel
  let vault: Vault

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        breadcrumbs
        Table(model.items, selection: $model.selection) {
          TableColumn("Name") { item in
            HStack(spacing: 7) {
              FilePromiseDragSource(vault: vault, item: item)
                .frame(width: 18, height: 18)
                .help("Drag to Finder to export")
              Image(systemName: item.isDirectory ? "folder.fill" : icon(for: item))
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
              Text(item.name)
                .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.enter(item) }
            .draggable(
              VaultItemTransfer(
                vaultID: vault.id,
                itemURLs: model.selection.contains(item.id)
                  ? model.selectedItems.map(\.encryptedURL) : [item.encryptedURL]
              )
            ) {
              Label(item.name, systemImage: item.isDirectory ? "folder.fill" : "doc")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: VaultItemTransfer.self) { transfers, _ in
              item.isDirectory && move(transfers, into: item.encryptedURL)
            }
            .contextMenu {
              Button("Export…", action: model.exportSelected)
              Button("Rename…", action: model.promptRename)
              Button("Move…", action: model.promptMove)
              Divider()
              Button("Delete", role: .destructive, action: model.confirmDelete)
            }
          }
          TableColumn("Size") { item in
            Text(
              item.byteSize.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
              } ?? "—"
            )
            .foregroundStyle(.secondary)
          }
          .width(min: 70, ideal: 90)
          TableColumn("Kind") { item in
            Text(kind(for: item)).foregroundStyle(.secondary)
          }
          .width(min: 80, ideal: 120)
        }
        .dropDestination(for: URL.self) { urls, _ in
          model.importItems(at: urls)
          return true
        }
        .onDeleteCommand(perform: model.confirmDelete)
      }
      .navigationSplitViewColumnWidth(min: 380, ideal: 500)
    } detail: {
      if let item = model.selectedItem {
        if item.isDirectory {
          ContentUnavailableView(
            "Folder", systemImage: "folder", description: Text("Double-click to open \(item.name).")
          )
        } else {
          SecurePreview(vault: vault, item: item)
            .id(item.id)
        }
      } else {
        ContentUnavailableView("No Selection", systemImage: "doc")
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button("Import", systemImage: "square.and.arrow.down", action: model.importPanel)
        Button("Export", systemImage: "square.and.arrow.up", action: model.exportSelected)
          .disabled(model.selectedItems.isEmpty)
        Button("Move", systemImage: "folder", action: model.promptMove)
          .disabled(model.selectedItems.isEmpty)
        Button("New Folder", systemImage: "folder.badge.plus", action: model.promptCreateFolder)
        Button("Lock", systemImage: "lock", action: model.lock)
      }
    }
  }

  private var breadcrumbs: some View {
    HStack(spacing: 4) {
      ForEach(model.path) { choice in
        if choice != model.path.first {
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        Button(choice.name) { model.navigate(to: choice) }
          .buttonStyle(.plain)
          .dropDestination(for: VaultItemTransfer.self) { transfers, _ in
            move(transfers, into: choice.url)
          }
      }
      Spacer()
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(.bar)
  }

  private func icon(for item: VaultItem) -> String {
    let type = UTType(filenameExtension: item.name.pathExtension)
    if type?.conforms(to: .image) == true { return "photo" }
    if type?.conforms(to: .audio) == true { return "waveform" }
    if type?.conforms(to: .movie) == true { return "film" }
    if type?.conforms(to: .pdf) == true { return "doc.richtext" }
    return "doc"
  }

  private func kind(for item: VaultItem) -> String {
    if item.isDirectory { return "Folder" }
    return UTType(filenameExtension: item.name.pathExtension)?.localizedDescription ?? "Document"
  }

  private func move(_ transfers: [VaultItemTransfer], into destination: URL) -> Bool {
    guard transfers.allSatisfy({ $0.vaultID == vault.id }) else { return false }
    return model.moveItems(at: transfers.flatMap(\.itemURLs), to: destination)
  }
}

private struct VaultModelFocusedKey: FocusedValueKey {
  typealias Value = VaultModel
}

extension FocusedValues {
  fileprivate var vaultModel: VaultModel? {
    get { self[VaultModelFocusedKey.self] }
    set { self[VaultModelFocusedKey.self] = newValue }
  }
}

private struct VaultCommands: Commands {
  @FocusedValue(\.vaultModel) private var model

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Vault…") { model?.chooseVault(create: true) }
      Button("Open Vault…") { model?.chooseVault(create: false) }
        .keyboardShortcut("o")
    }
    CommandMenu("Vault") {
      Button("Import…") { model?.importPanel() }
        .keyboardShortcut("i")
        .disabled(model?.vault == nil)
      Button("Export…") { model?.exportSelected() }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(model?.selectedItems.isEmpty != false)
      Button("New Folder…") { model?.promptCreateFolder() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(model?.vault == nil)
      Divider()
      Button("Rename…") { model?.promptRename() }
        .disabled(model?.selectedItem == nil)
      Button("Move…") { model?.promptMove() }
        .disabled(model?.selectedItems.isEmpty != false)
      Button("Delete") { model?.confirmDelete() }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(model?.selectedItems.isEmpty != false)
      Divider()
      Button("Lock Vault") { model?.lock() }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(model?.vault == nil)
    }
  }
}

extension String {
  fileprivate var pathExtension: String { (self as NSString).pathExtension }
}
