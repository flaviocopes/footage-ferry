import AppKit
import Observation

enum VideoState: Equatable {
  case onPhone
  /// A file with the same name and size is in the import folder. It gets checked before any delete.
  case onMac
  case waiting
  case copying(Double)
  case checking
  /// Copied, or found in the folder, and checked against the iPhone's file.
  case imported
  case failed(String)
  case deleting
}

/// The import that's running.
struct Batch {
  let count: Int
  let totalBytes: Int64
  var started = Date()
  var index = 0
  var current = ""
  var finishedBytes: Int64 = 0
  var currentBytes: Int64 = 0
  var downloadedBytes: Int64 = 0

  var fraction: Double {
    totalBytes > 0 ? Double(finishedBytes + currentBytes) / Double(totalBytes) : 0
  }

  var bytesPerSecond: Double? {
    let elapsed = Date().timeIntervalSince(started)
    return elapsed > 2 && downloadedBytes > 0 ? Double(downloadedBytes) / elapsed : nil
  }

  var secondsLeft: Double? {
    bytesPerSecond.map { Double(totalBytes - finishedBytes - currentBytes) / $0 }
  }
}

/// Videos the app offers to delete from the iPhone, because they're in the import folder.
struct DeleteOffer: Identifiable {
  let id = UUID()
  let videos: [Video]
  let failed: Int

  var bytes: Int64 { videos.reduce(0) { $0 + $1.size } }
}

@MainActor
@Observable
final class AppModel {
  enum Phase: Equatable {
    case waiting
    case connecting
    /// The iPhone was asked to trust this Mac and nobody has tapped Trust yet.
    case needsTrust
    case ready
    case failed(String)
  }

  static let defaultDestination = URL.moviesDirectory.appending(path: "Blackmagic Camera")

  private(set) var phase: Phase = .waiting
  private(set) var phoneName: String?
  private(set) var videos: [Video] = []
  private(set) var states: [Video.ID: VideoState] = [:]
  private(set) var destination: URL
  private(set) var batch: Batch?
  private(set) var isDeleting = false
  private(set) var thumbnails: [Video.ID: NSImage] = [:]
  var selection: Set<Video.ID> = []
  var previewing: Video?
  var deleteOffer: DeleteOffer?
  var alert: String?
  /// What the last import or delete did, shown at the bottom of the window.
  private(set) var notice: String?
  var sortOrder: [KeyPathComparator<Video>] {
    didSet {
      videos.sort(using: sortOrder)
      guard let first = sortOrder.first else { return }
      defaults.set(Self.sortKey(of: first), forKey: "sortKey")
      defaults.set(first.order == .forward, forKey: "sortAscending")
    }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var importer: Importer?
  @ObservationIgnored private var copies: [Video.ID: URL] = [:]
  @ObservationIgnored private var phone: Phone?
  @ObservationIgnored private var watcher: DeviceWatcher?
  @ObservationIgnored private var cancellation: Cancellation?
  @ObservationIgnored private var thumbnailRequests: Set<Video.ID> = []
  @ObservationIgnored private var thumbnailQueue: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    destination = defaults.string(forKey: "destination").map { URL(filePath: $0, directoryHint: .isDirectory) }
      ?? Self.defaultDestination
    sortOrder = [Self.comparator(defaults.string(forKey: "sortKey"), ascending: defaults.object(forKey: "sortAscending") as? Bool ?? true)]
  }

  var isBusy: Bool { batch != nil || isDeleting }
  var selectedVideos: [Video] { videos.filter { selection.contains($0.id) } }
  var totalBytes: Int64 { videos.reduce(0) { $0 + $1.size } }
  var onMacCount: Int { videos.count(where: { copy(of: $0) != nil }) }

  func state(of video: Video) -> VideoState {
    states[video.id] ?? .onPhone
  }

  /// The copy in the import folder, for videos that have one.
  func copy(of video: Video) -> URL? {
    switch state(of: video) {
    case .imported: copies[video.id]
    case .onMac: destination.appending(path: video.name)
    default: nil
    }
  }

  // MARK: Connecting

  func start(demo: Bool, demoVideo: URL? = nil) {
    if demo {
      Task { await connect(name: "iPhone 16 Pro", files: DemoFiles.sample(video: demoVideo)) }
      return
    }
    let watcher = DeviceWatcher { [weak self] event in self?.handle(event) }
    self.watcher = watcher
    do {
      try watcher.start()
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func retry() {
    guard let phone else { return }
    Task { await open(phone) }
  }

  func connect(name: String, files: PhoneFiles) async {
    phoneName = name
    importer = Importer(files: files)
    await reload()
  }

  func reload() async {
    guard let importer, !isBusy else { return }
    do {
      let videos = try await importer.videos()
      guard self.importer === importer else { return }
      self.videos = videos.sorted(using: sortOrder)
      selection.formIntersection(videos.map(\.id))
      refreshStates()
      phase = .ready
    } catch {
      guard self.importer === importer else { return }
      phase = .failed(error.localizedDescription)
    }
  }

  private func handle(_ event: DeviceWatcher.Event) {
    switch event {
    case .connected(let phone):
      guard self.phone == nil else { return }
      self.phone = phone
      Task { await open(phone) }
    case .disconnected(let id):
      guard id == phone?.id else { return }
      cancellation?.cancel()
      phone = nil
      importer = nil
      phoneName = nil
      videos = []
      states = [:]
      copies = [:]
      selection = []
      previewing = nil
      deleteOffer = nil
      thumbnails = [:]
      thumbnailRequests = []
      phase = .waiting
    }
  }

  private func open(_ phone: Phone) async {
    if phase != .needsTrust {
      phase = .connecting
    }
    do {
      let (name, files) = try await Task.detached { try phone.openDocuments(of: Importer.bundleID) }.value
      guard self.phone === phone else { return }
      await connect(name: name, files: files)
    } catch PhoneError.notPaired {
      guard self.phone === phone else { return }
      phase = .needsTrust
      try? await Task.sleep(for: .seconds(3))
      guard self.phone === phone, phase == .needsTrust else { return }
      await open(phone)
    } catch {
      guard self.phone === phone else { return }
      phase = .failed(error.localizedDescription)
    }
  }

  // MARK: Sorting

  private static func comparator(_ key: String?, ascending: Bool) -> KeyPathComparator<Video> {
    let order: SortOrder = ascending ? .forward : .reverse
    return switch key {
    case "name": KeyPathComparator(\.name, order: order)
    case "size": KeyPathComparator(\.size, order: order)
    default: KeyPathComparator(\.recorded, order: order)
    }
  }

  private static func sortKey(of comparator: KeyPathComparator<Video>) -> String {
    switch comparator.keyPath {
    case \Video.name: "name"
    case \Video.size: "size"
    default: "recorded"
    }
  }

  // MARK: Previews

  var previewFiles: PhoneFiles? { importer?.files }

  func preview(_ ids: Set<Video.ID>) {
    previewing = videos.first { ids.contains($0.id) }
  }

  /// Loads thumbnails one at a time, in the order the rows ask for them, so they don't crowd
  /// the connection. Each one reads about a megabyte from the iPhone, then comes from the cache.
  func loadThumbnail(for video: Video) async {
    guard let importer, thumbnailRequests.insert(video.id).inserted else { return }
    if let image = Thumbnails.cached(video) {
      thumbnails[video.id] = image
      return
    }
    let files = importer.files
    let previous = thumbnailQueue
    let job = Task.detached { () -> Data? in
      await previous?.value
      return await Thumbnails.make(video, files: files)
    }
    thumbnailQueue = Task { _ = await job.value }
    if let jpeg = await job.value, self.importer === importer, let image = NSImage(data: jpeg) {
      thumbnails[video.id] = image
    }
  }

  // MARK: Import folder

  func setDestination(_ url: URL) {
    destination = url
    defaults.set(url.path, forKey: "destination")
    copies = [:]
    refreshStates()
  }

  private func refreshStates() {
    for video in videos {
      states[video.id] = localState(of: video)
    }
  }

  private func localState(of video: Video) -> VideoState {
    if let copy = copies[video.id], Importer.size(of: copy) == video.size {
      return .imported
    }
    copies[video.id] = nil
    return Importer.size(of: destination.appending(path: video.name)) == video.size ? .onMac : .onPhone
  }

  // MARK: Importing

  func importVideos(_ list: [Video]) async {
    guard let importer, !isBusy, !list.isEmpty else { return }
    let folder = destination
    let cancellation = Cancellation()
    self.cancellation = cancellation
    notice = nil
    Importer.removeLeftovers(in: folder)
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing videos from the iPhone")
    defer { ProcessInfo.processInfo.endActivity(activity) }

    batch = Batch(count: list.count, totalBytes: list.reduce(0) { $0 + $1.size })
    for video in list { states[video.id] = .waiting }
    var imported: [Video] = []
    var failures: [String] = []
    for (index, video) in list.enumerated() {
      guard !cancellation.isCancelled else { break }
      batch?.index = index
      batch?.current = video.name
      batch?.currentBytes = 0
      states[video.id] = .copying(0)
      do {
        let copy = try await importer.copy(video, to: folder, cancellation: cancellation) { step in
          Task { @MainActor [weak self] in self?.update(video, step) }
        }
        copies[video.id] = copy.url
        states[video.id] = .imported
        imported.append(video)
      } catch is CancellationError {
        states[video.id] = localState(of: video)
      } catch {
        states[video.id] = .failed(error.localizedDescription)
        failures.append(error.localizedDescription)
      }
      batch?.finishedBytes += video.size
      batch?.currentBytes = 0
    }
    for video in list where states[video.id] == .waiting {
      states[video.id] = localState(of: video)
    }
    batch = nil
    self.cancellation = nil
    guard self.importer === importer else { return }

    let count = imported.count
    if cancellation.isCancelled {
      notice = "Import cancelled. \(count == 1 ? "1 video was" : "\(count) videos were") imported before that."
    } else if failures.isEmpty {
      notice = "Imported \(count == 1 ? "1 video" : "\(count) videos") into \(folder.lastPathComponent)."
    } else {
      notice = "Imported \(count) of \(list.count) videos. \(failures.count) failed."
    }
    if !imported.isEmpty && !cancellation.isCancelled {
      deleteOffer = DeleteOffer(videos: imported, failed: failures.count)
    } else if !failures.isEmpty {
      alert = "Couldn't import \(failures.count == 1 ? "1 video" : "\(failures.count) videos").\n\n"
        + failures.prefix(3).joined(separator: "\n")
    }
  }

  func cancelImport() {
    cancellation?.cancel()
  }

  private func update(_ video: Video, _ step: Importer.Step) {
    guard var batch, batch.current == video.name else { return }
    switch (step, state(of: video)) {
    case (.copying(let bytes), .copying):
      batch.downloadedBytes += bytes - batch.currentBytes
      batch.currentBytes = bytes
      self.batch = batch
      states[video.id] = .copying(video.size > 0 ? Double(bytes) / Double(video.size) : 1)
    case (.checking, .copying):
      states[video.id] = .checking
    default:
      break
    }
  }

  // MARK: Deleting

  /// Offers to delete the videos in `list` that have a copy in the import folder.
  func offerDelete(_ list: [Video]) {
    let onMac = list.filter { copy(of: $0) != nil }
    guard !onMac.isEmpty, !isBusy else { return }
    deleteOffer = DeleteOffer(videos: onMac, failed: 0)
  }

  func deleteFromPhone(_ list: [Video]) async {
    guard let importer, !isBusy else { return }
    isDeleting = true
    defer { isDeleting = false }
    notice = nil
    var deleted: Set<Video.ID> = []
    var kept: [String] = []
    for video in list {
      guard let copy = copy(of: video) else {
        kept.append(ImportError.copyMissing(video.name).localizedDescription)
        continue
      }
      states[video.id] = .deleting
      do {
        try await importer.deleteOriginal(video, copy: copy)
        deleted.insert(video.id)
      } catch {
        states[video.id] = .failed(error.localizedDescription)
        kept.append(error.localizedDescription)
      }
    }
    guard self.importer === importer else { return }
    videos.removeAll { deleted.contains($0.id) }
    selection.subtract(deleted)
    for id in deleted {
      states[id] = nil
      copies[id] = nil
    }
    notice = "Deleted \(deleted.count == 1 ? "1 video" : "\(deleted.count) videos") from the iPhone."
    if !kept.isEmpty {
      alert = "Kept \(kept.count == 1 ? "1 video" : "\(kept.count) videos") on the iPhone.\n\n"
        + kept.prefix(3).joined(separator: "\n")
    }
  }
}

#if SCREENSHOT
extension AppModel {
  /// Puts the window in the state the README screenshots show. Only scripts/screenshot.sh builds it.
  func stage(states: [Video.ID: VideoState], batch: Batch?, thumbnails: [Video.ID: NSImage]) {
    self.states = states
    self.batch = batch
    self.thumbnails = thumbnails
  }
}
#endif
