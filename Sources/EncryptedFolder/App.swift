import AppKit
import CoreTransferable
import EncryptedFolderCore
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

private struct VaultItemTransfer: Codable, Transferable {
  let vaultID: UUID
  let itemURLs: [URL]

  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation {
      String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    } importing: {
      try JSONDecoder().decode(Self.self, from: Data($0.utf8))
    }
    .visibility(.ownProcess)
  }
}

private enum BrowserStyle: String {
  case table
  case icons
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
  private enum Field: Hashable {
    case password
    case confirmation
  }

  @Bindable var model: VaultModel
  @State private var authenticationContext = LAContext()
  @FocusState private var focusedField: Field?

  var body: some View {
    VStack {
      Spacer()
      VStack {
        VStack {
          Image(systemName: model.isCreating ? "folder.badge.plus" : "lock.fill")
            .font(.largeTitle)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
          Text(title)
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
          Text(subtitle)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.bottom)

        GroupBox(model.isCreating ? "Vault Folder" : "Selected Vault") {
          HStack {
            Image(systemName: "folder.fill")
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
            VStack(alignment: .leading) {
              Text(vaultName)
                .font(.headline)
              Text(vaultPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(vaultPath)
            }
            Spacer()
          }
        }
        .padding(.bottom)

        if model.hasStoredKey {
          LocalAuthenticationView(
            "Unlock with Touch ID",
            reason: Text("Unlock \(vaultName)"),
            context: authenticationContext
          ) { result in
            if case .success = result {
              model.unlockWithTouchID(context: authenticationContext)
            }
          }
          .padding(.bottom)
        }

        VStack(alignment: .leading) {
          Text(model.hasStoredKey ? "Or enter your password" : "Password")
            .font(.headline)
          SecureField("Password", text: $model.password)
            .textFieldStyle(.roundedBorder)
            .textContentType(model.isCreating ? .newPassword : .password)
            .focused($focusedField, equals: .password)
            .onSubmit(model.unlockWithPassword)
          if model.isCreating {
            SecureField("Confirm Password", text: $model.confirmedPassword)
              .textFieldStyle(.roundedBorder)
              .textContentType(.newPassword)
              .focused($focusedField, equals: .confirmation)
              .onSubmit(model.unlockWithPassword)
          }
          if model.touchIDAvailable && !model.hasStoredKey {
            Toggle("Use Touch ID on this Mac", isOn: $model.rememberWithTouchID)
          }

          HStack {
            Spacer()
            Button(model.isCreating ? "Create Vault" : "Unlock", action: model.unlockWithPassword)
              .keyboardShortcut(.defaultAction)
          }
          .controlSize(.large)
        }
        .controlSize(.large)
        .padding(.bottom)

        Menu("Vault Options", systemImage: "ellipsis.circle") {
          Button("Choose Another Vault…") { model.chooseVault(create: false) }
          Button("Create New Vault…") { model.chooseVault(create: true) }
          if model.hasStoredKey {
            Divider()
            Button("Forget Touch ID", action: model.forgetTouchID)
          }
        }
        .menuStyle(.borderlessButton)
      }
      // Keep the form readable without stretching controls across a large Mac window.
      .frame(maxWidth: 360)
      .task {
        await Task.yield()
        focusedField = nil
      }
      Spacer()
    }
    .padding()
  }

  private var title: String {
    model.isCreating ? "Create a Vault" : "Unlock Vault"
  }

  private var vaultName: String {
    model.vaultURL?.lastPathComponent ?? "Vault"
  }

  private var vaultPath: String {
    model.vaultURL?.path ?? ""
  }

  private var subtitle: String {
    if model.isCreating {
      "Choose a password to protect this encrypted folder."
    } else if model.hasStoredKey {
      "Use Touch ID or enter your password."
    } else {
      "Enter your password to continue."
    }
  }
}

private struct BrowserView: View {
  @Bindable var model: VaultModel
  let vault: Vault
  @AppStorage("browserColumns") private var columnCustomization =
    TableColumnCustomization<VaultItem>()
  @State private var browserStyle = BrowserStyle.table

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        breadcrumbs
        browser
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
    .onChange(of: model.currentDirectory, initial: true) {
      browserStyle = savedBrowserStyle
    }
    .toolbar {
      ToolbarItemGroup {
        Picker("View", selection: browserStyleBinding) {
          Label("Table", systemImage: "list.bullet").tag(BrowserStyle.table)
          Label("Icons", systemImage: "square.grid.2x2").tag(BrowserStyle.icons)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .frame(width: 72)
        .help("Choose table or icon view for this folder")
        Button("Import", systemImage: "square.and.arrow.down", action: model.importPanel)
          .help("Import files into the current folder")
        Button("Export", systemImage: "square.and.arrow.up", action: model.exportSelected)
          .disabled(model.selectedItems.isEmpty)
          .help("Export selected items to Finder")
        Button("Move", systemImage: "folder", action: model.promptMove)
          .disabled(model.selectedItems.isEmpty)
          .help("Move selected items")
        Button("New Folder", systemImage: "folder.badge.plus", action: model.promptCreateFolder)
          .help("Create a folder")
        Button("Lock", systemImage: "lock", action: model.lock)
          .help("Lock the vault")
      }
    }
  }

  @ViewBuilder private var browser: some View {
    switch browserStyle {
    case .table:
      table
    case .icons:
      iconGrid
    }
  }

  private var table: some View {
    Table(
      of: VaultItem.self,
      selection: $model.selection,
      columnCustomization: $columnCustomization
    ) {
      TableColumn("Name") { item in
        HStack(spacing: 7) {
          Image(systemName: item.isDirectory ? "folder.fill" : icon(for: item))
            .foregroundStyle(item.isDirectory ? .blue : .secondary)
          Text(item.name)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .customizationID("name")
      .disabledCustomizationBehavior(.visibility)
      TableColumn("Size") { item in
        Text(
          item.byteSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
          } ?? "—"
        )
        .foregroundStyle(.secondary)
      }
      .width(min: 70, ideal: 90)
      .customizationID("size")
      TableColumn("Kind") { item in
        Text(kind(for: item)).foregroundStyle(.secondary)
      }
      .width(min: 80, ideal: 120)
      .customizationID("kind")
      .defaultVisibility(.hidden)
    } rows: {
      ForEach(model.items) { item in
        TableRow(item)
          .draggable(transfer(for: item))
          .dropDestination(for: VaultItemTransfer.self) { transfers in
            if item.isDirectory { _ = move(transfers, into: item.encryptedURL) }
          }
      }
    }
    .contextMenu(forSelectionType: URL.self) { selection in
      itemActions(for: selection)
    } primaryAction: { selection in
      guard selection.count == 1,
        let item = model.items.first(where: { selection.contains($0.id) })
      else { return }
      model.enter(item)
    }
    .vaultDropDestination(for: URL.self) { urls in
      model.importItems(at: urls)
    }
    .onDeleteCommand(perform: model.confirmDelete)
  }

  private var iconGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 12)], spacing: 12
      ) {
        ForEach(model.items) { item in
          VStack(spacing: 7) {
            SecureThumbnail(
              vault: vault,
              item: item,
              fallbackIcon: item.isDirectory ? "folder.fill" : icon(for: item)
            )
            .frame(width: 72, height: 56)
            .clipped()
            Text(item.name)
              .font(.caption)
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
          .padding(8)
          .frame(maxWidth: .infinity)
          .background(
            model.selection.contains(item.id) ? Color.accentColor.opacity(0.2) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .contentShape(Rectangle())
          .onTapGesture { select(item) }
          .simultaneousGesture(TapGesture(count: 2).onEnded { model.enter(item) })
          .focusable()
          .onKeyPress(.return) {
            select(item)
            return .handled
          }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { select(item) }
          .draggable(transfer(for: item))
          .vaultDropDestination(for: VaultItemTransfer.self, isEnabled: item.isDirectory) {
            transfers in
            _ = move(transfers, into: item.encryptedURL)
          }
          .contextMenu {
            itemActions(for: contextSelection(for: item))
          }
        }
      }
      .padding(16)
    }
    .vaultDropDestination(for: URL.self) { urls in
      model.importItems(at: urls)
    }
    .onDeleteCommand(perform: model.confirmDelete)
  }

  @ViewBuilder private func itemActions(for selection: Set<URL>) -> some View {
    Button("Export…") { withSelection(selection, perform: model.exportSelected) }
    Button("Rename…") { withSelection(selection, perform: model.promptRename) }
    Button("Move…") { withSelection(selection, perform: model.promptMove) }
    Divider()
    Button("Delete", role: .destructive) {
      withSelection(selection, perform: model.confirmDelete)
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
          .vaultDropDestination(for: VaultItemTransfer.self) { transfers in
            _ = move(transfers, into: choice.url)
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

  private var browserStyleBinding: Binding<BrowserStyle> {
    Binding {
      browserStyle
    } set: { style in
      browserStyle = style
      if let key = browserStyleKey {
        UserDefaults.standard.set(style.rawValue, forKey: key)
      }
    }
  }

  private var browserStyleKey: String? {
    guard let directory = model.currentDirectory,
      let directoryID = try? vault.directoryID(at: directory)
    else { return nil }
    return "browserStyle.\(vault.id.uuidString).\(directoryID.base64EncodedString())"
  }

  private var savedBrowserStyle: BrowserStyle {
    browserStyleKey
      .flatMap(UserDefaults.standard.string(forKey:))
      .flatMap(BrowserStyle.init(rawValue:)) ?? .table
  }

  private func select(_ item: VaultItem) {
    if NSEvent.modifierFlags.contains(.command) {
      if !model.selection.insert(item.id).inserted { model.selection.remove(item.id) }
    } else {
      model.selection = [item.id]
    }
  }

  private func contextSelection(for item: VaultItem) -> Set<URL> {
    model.selection.contains(item.id) ? model.selection : [item.id]
  }

  private func transfer(for item: VaultItem) -> VaultItemTransfer {
    VaultItemTransfer(
      vaultID: vault.id,
      itemURLs: model.selection.contains(item.id)
        ? model.selectedItems.map(\.encryptedURL) : [item.encryptedURL]
    )
  }

  private func kind(for item: VaultItem) -> String {
    if item.isDirectory { return "Folder" }
    return UTType(filenameExtension: item.name.pathExtension)?.localizedDescription ?? "Document"
  }

  private func move(_ transfers: [VaultItemTransfer], into destination: URL) -> Bool {
    guard transfers.allSatisfy({ $0.vaultID == vault.id }) else { return false }
    return model.moveItems(at: transfers.flatMap(\.itemURLs), to: destination)
  }

  private func withSelection(_ selection: Set<URL>, perform action: () -> Void) {
    model.selection = selection
    action()
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

extension View {
  @ViewBuilder fileprivate func vaultDropDestination<T: Transferable>(
    for type: T.Type,
    isEnabled: Bool = true,
    action: @escaping ([T]) -> Void
  ) -> some View {
    if #available(macOS 26, *) {
      dropDestination(for: type, isEnabled: isEnabled) { items, _ in action(items) }
    } else {
      dropDestination(for: type) { items, _ in
        guard isEnabled else { return false }
        action(items)
        return true
      }
    }
  }
}
