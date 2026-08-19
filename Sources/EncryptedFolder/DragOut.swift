import AppKit
import EncryptedFolderCore
import SwiftUI
import UniformTypeIdentifiers

struct FilePromiseDragSource: NSViewRepresentable {
  let vault: Vault
  let item: VaultItem

  func makeNSView(context: Context) -> PromiseDragView {
    PromiseDragView(vault: vault, item: item)
  }

  func updateNSView(_ view: PromiseDragView, context: Context) {
    view.vault = vault
    view.item = item
  }
}

final class PromiseDragView: NSView, NSDraggingSource {
  var vault: Vault
  var item: VaultItem

  init(vault: Vault, item: VaultItem) {
    self.vault = vault
    self.item = item
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.secondaryLabelColor.set()
    NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: "Drag to export")?
      .draw(in: bounds.insetBy(dx: 2, dy: 2))
  }

  override func mouseDragged(with event: NSEvent) {
    let delegate = PromiseDelegate(vault: vault, item: item)
    let type =
      item.isDirectory
      ? UTType.folder : (UTType(filenameExtension: item.name.pathExtension) ?? .data)
    let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
    provider.userInfo = delegate
    let draggingItem = NSDraggingItem(pasteboardWriter: provider)
    draggingItem.setDraggingFrame(bounds, contents: snapshot())
    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  private func snapshot() -> NSImage {
    let image = NSImage(size: bounds.size)
    image.lockFocus()
    draw(bounds)
    image.unlockFocus()
    return image
  }
}

private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
  let operationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  private let vault: Vault
  private let item: VaultItem

  init(vault: Vault, item: VaultItem) {
    self.vault = vault
    self.item = item
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
  ) -> String {
    item.name
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    defer { url.stopAccessingSecurityScopedResource() }
    do {
      try vault.export(item, to: url)
      completionHandler(nil)
    } catch {
      completionHandler(error)
    }
  }
}

extension String {
  fileprivate var pathExtension: String { (self as NSString).pathExtension }
}
