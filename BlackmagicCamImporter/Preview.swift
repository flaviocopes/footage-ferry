import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Feeds AVFoundation a clip straight from the iPhone, one byte range at a time, so a thumbnail
/// or a preview only reads the parts it needs: the index at the end of the file and the frames
/// it shows. AVFoundation asks through a made-up URL scheme, since the clip has no real URL.
final class ClipLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  private struct Request: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
  }

  let asset: AVURLAsset
  private let files: PhoneFiles
  private let video: Video
  private let delegateQueue = DispatchQueue(label: "com.flaviocopes.blackmagic-cam-importer.loader")
  /// Concurrent, so a long read the player hasn't cancelled yet doesn't hold up the next one.
  private let readQueue = DispatchQueue(label: "com.flaviocopes.blackmagic-cam-importer.reads", attributes: .concurrent)

  init(files: PhoneFiles, video: Video) {
    self.files = files
    self.video = video
    var components = URLComponents()
    components.scheme = "blackmagic-clip"
    components.host = "iphone"
    components.path = "/\(video.name)"
    asset = AVURLAsset(url: components.url!)
    super.init()
    asset.resourceLoader.setDelegate(self, queue: delegateQueue)
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    if let info = loadingRequest.contentInformationRequest {
      info.contentType = (UTType(filenameExtension: (video.name as NSString).pathExtension) ?? .quickTimeMovie).identifier
      info.contentLength = video.size
      info.isByteRangeAccessSupported = true
    }
    guard let data = loadingRequest.dataRequest else {
      loadingRequest.finishLoading()
      return true
    }
    let offset = data.requestedOffset
    let length = data.requestsAllDataToEndOfResource ? video.size - offset : Int64(data.requestedLength)
    let request = Request(value: loadingRequest)
    readQueue.async { [files, video] in
      do {
        try files.read(video.path, offset: offset, length: min(length, video.size - offset)) { chunk in
          if request.value.isCancelled { throw CancellationError() }
          request.value.dataRequest?.respond(with: chunk)
        }
        request.value.finishLoading()
      } catch is CancellationError {
      } catch {
        request.value.finishLoading(with: error)
      }
    }
    return true
  }
}

/// Clip thumbnails: one frame near the start, grabbed from the iPhone and kept as a JPEG in the
/// app's caches folder, under the clip's name and size.
enum Thumbnails {
  static let folder = URL.cachesDirectory.appending(path: "com.flaviocopes.blackmagic-cam-importer/Thumbnails")

  static func cached(_ video: Video) -> NSImage? {
    NSImage(contentsOf: url(for: video))
  }

  /// Returns the JPEG, or nil when the clip can't be decoded.
  static func make(_ video: Video, files: PhoneFiles) async -> Data? {
    let loader = ClipLoader(files: files, video: video)
    let generator = AVAssetImageGenerator(asset: loader.asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 240, height: 240)
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    guard let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)),
          let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
      return nil
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? jpeg.write(to: url(for: video))
    return withExtendedLifetime(loader) { jpeg }
  }

  private static func url(for video: Video) -> URL {
    folder.appending(path: "\(video.name)-\(video.size).jpg")
  }
}

/// AppKit's player, with the floating controls and the full screen button. SwiftUI's
/// `VideoPlayer` crashes on macOS unless AVKit happens to be linked.
struct PlayerView: NSViewRepresentable {
  let player: AVPlayer?

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .floating
    view.showsFullScreenToggleButton = true
    view.player = player
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    view.player = player
  }
}

/// Plays a clip streamed from the iPhone. Nothing is saved: closing the preview stops the reads.
struct PreviewView: View {
  let video: Video
  let files: PhoneFiles
  @State private var loader: ClipLoader?
  @State private var player: AVPlayer?
  @State private var details = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      PlayerView(player: player)
        .frame(width: 880, height: 495)
        .background(.black)
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(video.name)
            .font(.headline)
          Text(subtitle)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)
    }
    .task {
      let loader = ClipLoader(files: files, video: video)
      let player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset))
      self.loader = loader
      self.player = player
      player.play()
      details = await Self.details(of: loader.asset)
    }
    .onDisappear {
      player?.pause()
      player = nil
      loader = nil
    }
  }

  private var subtitle: String {
    let recorded = video.recorded.formatted(date: .abbreviated, time: .shortened)
    let parts = [recorded, video.size.formatted(.byteCount(style: .file)), details]
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// Like "3840×2160 · 60 fps · 0:41".
  private static func details(of asset: AVURLAsset) async -> String {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let (size, transform, rate) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate),
          let duration = try? await asset.load(.duration) else {
      return ""
    }
    let shown = size.applying(transform)
    let seconds = Duration.seconds(duration.seconds.rounded())
    return "\(Int(abs(shown.width)))×\(Int(abs(shown.height))) · \(Int(rate.rounded())) fps · \(seconds.formatted(.time(pattern: .minuteSecond)))"
  }
}
