import AVFoundation
import AVKit
import AppKit
import EncryptedFolderCore
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SecureThumbnail: View {
  let vault: Vault
  let item: VaultItem
  let fallbackIcon: String

  @State private var thumbnail: NSImage?
  @State private var webMData: Data?

  var body: some View {
    Group {
      if let webMData {
        WebMThumbnail(data: webMData)
          .allowsHitTesting(false)
      } else if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: fallbackIcon)
          .font(.system(size: 38))
          .foregroundStyle(item.isDirectory ? .blue : .secondary)
      }
    }
    .task(id: item.id) { await load() }
  }

  private func load() async {
    guard !item.isDirectory else { return }
    let fileExtension = item.name.pathExtension.lowercased()
    let type = UTType(filenameExtension: fileExtension) ?? .data
    let isWebM = fileExtension == "webm"
    guard
      type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie)
        || isWebM
    else { return }
    do {
      let reader = try vault.reader(for: item)
      if isWebM {
        let data = try await Task.detached { try reader.readAll() }.value
        guard !Task.isCancelled else { return }
        webMData = data
      } else if type.conforms(to: .image) || type.conforms(to: .pdf) {
        let data = try await Task.detached { try reader.readAll() }.value
        guard !Task.isCancelled else { return }
        if type.conforms(to: .image) {
          thumbnail = imageThumbnail(from: data)
        } else {
          thumbnail = PDFDocument(data: data)?.page(at: 0)?.thumbnail(
            of: NSSize(width: 160, height: 160), for: .mediaBox)
        }
      } else {
        let image = try await EncryptedMediaAsset(
          reader: reader, type: type, name: item.name
        ).thumbnail()
        guard !Task.isCancelled else { return }
        thumbnail = image
      }
    } catch {
      thumbnail = nil
    }
  }

  private func imageThumbnail(from data: Data) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 320,
        ] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: .zero)
  }
}

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
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .pdf(let data):
        PDFPreview(data: data)
      case .player(let session):
        PlayerPreview(player: session.player)
      case .web(let data):
        WebPreview(data: data)
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
      } else if item.name.pathExtension.lowercased() == "webm" {
        content = .web(try await readAll())
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
  case web(Data)
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

private struct WebPreview: NSViewRepresentable {
  let data: Data

  func makeNSView(context: Context) -> WKWebView {
    let configuration = webMConfiguration(data: data)
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: "document.querySelector('video')?.setAttribute('loop', '')",
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true))
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.load(URLRequest(url: URL(string: "encrypted-folder-webm://preview/video.webm")!))
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct WebMThumbnail: NSViewRepresentable {
  let data: Data

  func makeNSView(context: Context) -> WKWebView {
    let configuration = webMConfiguration(data: data)
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: """
          (() => {
            const video = document.querySelector('video');
            if (!video) return;
            video.controls = false;
            video.muted = true;
            const showFrame = () => {
              video.pause();
              if (video.duration > 0.1) video.currentTime = 0.1;
            };
            video.addEventListener('loadeddata', showFrame, { once: true });
            video.addEventListener('seeked', () => video.pause());
            document.documentElement.style.cssText = 'width:100%;height:100%;margin:0;background:#000';
            document.body.style.cssText = 'width:100%;height:100%;margin:0;background:#000';
            video.style.cssText = 'width:100%;height:100%;object-fit:contain';
            if (video.readyState >= 2) showFrame();
          })()
          """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true))
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setAccessibilityElement(false)
    view.load(URLRequest(url: URL(string: "encrypted-folder-webm://preview/video.webm")!))
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor
private func webMConfiguration(data: Data) -> WKWebViewConfiguration {
  let configuration = WKWebViewConfiguration()
  configuration.websiteDataStore = .nonPersistent()
  configuration.setURLSchemeHandler(
    WebMURLSchemeHandler(data: data), forURLScheme: "encrypted-folder-webm")
  return configuration
}

private final class WebMURLSchemeHandler: NSObject, WKURLSchemeHandler {
  let data: Data

  init(data: Data) { self.data = data }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    task.didReceive(
      URLResponse(
        url: task.request.url!, mimeType: "video/webm", expectedContentLength: data.count,
        textEncodingName: nil))
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
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
  private let source: EncryptedMediaAsset
  private let looper: AVPlayerLooper?

  init(reader: EncryptedFileReader, type: UTType, name: String) throws {
    source = EncryptedMediaAsset(reader: reader, type: type, name: name)
    let item = AVPlayerItem(asset: source.asset)
    if type.conforms(to: .movie) {
      let player = AVQueuePlayer()
      self.player = player
      looper = AVPlayerLooper(player: player, templateItem: item)
      player.play()
    } else {
      player = AVPlayer(playerItem: item)
      looper = nil
    }
  }
}

private final class EncryptedMediaAsset {
  let asset: AVURLAsset
  private let loader: EncryptedAssetLoader

  init(reader: EncryptedFileReader, type: UTType, name: String) {
    loader = EncryptedAssetLoader(reader: reader, type: type)
    let ext = name.pathExtension.isEmpty ? "bin" : name.pathExtension
    asset = AVURLAsset(url: URL(string: "encrypted-folder://vault/asset.\(ext)")!)
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
  }

  func thumbnail() async throws -> NSImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = NSSize(width: 320, height: 320)
    let (image, _) = try await generator.image(at: .zero)
    return NSImage(cgImage: image, size: .zero)
  }
}

private final class EncryptedAssetLoader: NSObject, AVAssetResourceLoaderDelegate,
  @unchecked Sendable
{
  let queue = DispatchQueue(label: "dev.mxcl.encrypted-folder.media-loader", qos: .userInitiated)
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
