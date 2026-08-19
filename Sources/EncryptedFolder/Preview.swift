import AVFoundation
import AVKit
import AppKit
import EncryptedFolderCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct SecurePreview: View {
  let vault: Vault
  let item: VaultItem

  @State private var content: PreviewContent = .loading

  var body: some View {
    Group {
      switch content {
      case .loading:
        ProgressView()
      case .image(let image):
        ScrollView([.horizontal, .vertical]) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .pdf(let data):
        PDFPreview(data: data)
      case .player(let session):
        PlayerPreview(player: session.player)
      case .unsupported:
        ContentUnavailableView(
          "Preview Unavailable",
          systemImage: "eye.slash",
          description: Text(
            "This format cannot be viewed without handing plaintext to another process. Export it explicitly to open it elsewhere."
          )
        )
      case .failed(let message):
        ContentUnavailableView(
          "Unable to Preview", systemImage: "exclamationmark.triangle", description: Text(message))
      }
    }
    .navigationTitle(item.name)
    .task(id: item.id) { await load() }
  }

  private func load() async {
    content = .loading
    let type = UTType(filenameExtension: item.name.pathExtension) ?? .data
    do {
      if type.conforms(to: .image) {
        let data = try await readAll()
        guard let image = NSImage(data: data) else { throw VaultError.damagedFile }
        content = .image(image)
      } else if type.conforms(to: .pdf) {
        content = .pdf(try await readAll())
      } else if type.conforms(to: .audio) || type.conforms(to: .movie) {
        content = .player(
          try PlayerSession(reader: vault.reader(for: item), type: type, name: item.name))
      } else {
        content = .unsupported
      }
    } catch {
      content = .failed(error.localizedDescription)
    }
  }

  private func readAll() async throws -> Data {
    let reader = try vault.reader(for: item)
    return try await Task.detached { try reader.readAll() }.value
  }
}

private enum PreviewContent {
  case loading
  case image(NSImage)
  case pdf(Data)
  case player(PlayerSession)
  case unsupported
  case failed(String)
}

private struct PDFPreview: NSViewRepresentable {
  let data: Data

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    if view.document?.dataRepresentation() != data {
      view.document = PDFDocument(data: data)
    }
  }
}

private struct PlayerPreview: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.player = player
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }

  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
    view.player?.pause()
    view.player = nil
  }
}

@MainActor
private final class PlayerSession {
  let player: AVPlayer
  private let loader: EncryptedAssetLoader

  init(reader: EncryptedFileReader, type: UTType, name: String) throws {
    loader = EncryptedAssetLoader(reader: reader, type: type)
    let ext = name.pathExtension.isEmpty ? "bin" : name.pathExtension
    let asset = AVURLAsset(url: URL(string: "encrypted-folder://vault/asset.\(ext)")!)
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }
}

private final class EncryptedAssetLoader: NSObject, AVAssetResourceLoaderDelegate,
  @unchecked Sendable
{
  let queue = DispatchQueue(label: "com.mxcl.EncryptedFolder.media-loader", qos: .userInitiated)
  private let reader: EncryptedFileReader
  private let type: UTType

  init(reader: EncryptedFileReader, type: UTType) {
    self.reader = reader
    self.type = type
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    do {
      if let information = request.contentInformationRequest {
        information.contentType = type.identifier
        information.contentLength = Int64(reader.plainSize)
        information.isByteRangeAccessSupported = true
      }
      if let dataRequest = request.dataRequest {
        let start = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        guard start >= 0, dataRequest.requestedLength >= 0,
          UInt64(start) <= reader.plainSize
        else { throw VaultError.damagedFile }
        let available = reader.plainSize - UInt64(start)
        var remaining =
          dataRequest.requestsAllDataToEndOfResource
          ? available
          : min(available, UInt64(dataRequest.requestedLength))
        var offset = UInt64(start)
        while remaining > 0, !request.isCancelled {
          let data = try reader.read(
            offset: offset, length: Int(min(remaining, UInt64(VaultCryptor.chunkSize))))
          guard !data.isEmpty else { throw VaultError.damagedFile }
          dataRequest.respond(with: data)
          offset += UInt64(data.count)
          remaining -= UInt64(data.count)
        }
      }
      if !request.isCancelled { request.finishLoading() }
    } catch {
      request.finishLoading(with: error)
    }
    return true
  }
}

extension String {
  fileprivate var pathExtension: String { (self as NSString).pathExtension }
}
