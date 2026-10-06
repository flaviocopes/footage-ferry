import CryptoKit
import Foundation

/// Made-up Blackmagic Cam files, for the demo (`--demo`) and the tests. A clip's bytes are one
/// block, made from its name, repeated, so clips of any size can be read and hashed without being
/// stored anywhere. With a `video`, every clip is a copy of that file instead, so previews play.
final class DemoFiles: PhoneFiles, @unchecked Sendable {
  struct Clip {
    let size: Int64
    let recorded: Date
  }

  private static let blockSize = 1 << 20
  private let lock = NSLock()
  private var clips: [String: Clip]
  private let bytesPerSecond: Double?
  private let video: URL?
  /// Clips whose reads come back with one byte changed, like a cable that drops a bit.
  var corrupted: Set<String> = []

  init(clips: [String: Clip], bytesPerSecond: Double? = nil, video: URL? = nil) {
    self.clips = clips
    self.bytesPerSecond = bytesPerSecond
    self.video = video
  }

  /// Clips named and sized like real Blackmagic Cam recordings.
  static func sample(count: Int = 14, megabytes: ClosedRange<Int> = 30...600, bytesPerSecond: Double? = 120_000_000, video: URL? = nil) -> DemoFiles {
    var generator = SeededGenerator(seed: 7)
    var date = DateComponents(calendar: .current, year: 2026, month: 8, day: 2, hour: 17, minute: 11).date!
    let stamp = DateFormatter()
    stamp.dateFormat = "MMddHHmm"
    let videoSize = video.flatMap { Importer.size(of: $0) }
    var clips: [String: Clip] = [:]
    for number in 1...count {
      date += Double.random(in: 600...200_000, using: &generator)
      let name = String(format: "A001_%@_C%03d.mov", stamp.string(from: date), number)
      let size = Int64(Int.random(in: megabytes, using: &generator)) * 1_000_000 + Int64(number)
      clips[name] = Clip(size: videoSize ?? size, recorded: date)
    }
    return DemoFiles(clips: clips, bytesPerSecond: bytesPerSecond, video: video)
  }

  func list(_ path: String) throws -> [String] {
    switch path {
    case "/Documents": ["LUT", "Media", "Presets"]
    case Importer.mediaFolder: lock.withLock { Array(clips.keys) } + ["Proxy"]
    default: throw PhoneError.afc(8, path)
    }
  }

  func info(_ path: String) throws -> FileInfo {
    if path == "\(Importer.mediaFolder)/Proxy" {
      return FileInfo(size: 64, isDirectory: true, created: .distantPast, modified: .distantPast)
    }
    let clip = try clip(at: path)
    return FileInfo(size: clip.size, isDirectory: false, created: clip.recorded, modified: clip.recorded + 1)
  }

  func read(_ path: String, _ chunk: (Data) throws -> Void) throws {
    let clip = try clip(at: path)
    try stream(path, offset: 0, length: clip.size, chunkSize: 4 * Self.blockSize, transfer: true, chunk)
  }

  func read(_ path: String, offset: Int64, length: Int64, _ chunk: (Data) throws -> Void) throws {
    let clip = try clip(at: path)
    guard offset >= 0, offset + length <= clip.size else { throw PhoneError.truncated(path) }
    try stream(path, offset: offset, length: length, chunkSize: Self.blockSize, transfer: true, chunk)
  }

  func sha1(_ path: String) throws -> Data {
    let clip = try clip(at: path)
    var hasher = Insecure.SHA1()
    try stream(path, offset: 0, length: clip.size, chunkSize: 4 * Self.blockSize, transfer: false) { hasher.update(data: $0) }
    return Data(hasher.finalize())
  }

  func remove(_ path: String) throws {
    _ = try clip(at: path)
    lock.withLock { clips[(path as NSString).lastPathComponent] = nil }
  }

  func contains(_ name: String) -> Bool {
    lock.withLock { clips[name] != nil }
  }

  private func clip(at path: String) throws -> Clip {
    let name = (path as NSString).lastPathComponent
    guard (path as NSString).deletingLastPathComponent == Importer.mediaFolder,
          let clip = lock.withLock({ clips[name] }) else {
      throw PhoneError.afc(8, path)
    }
    return clip
  }

  /// A transfer is throttled and can be corrupted. The iPhone's own hash is neither.
  private func stream(_ path: String, offset: Int64, length: Int64, chunkSize: Int, transfer: Bool, _ chunk: (Data) throws -> Void) throws {
    let name = (path as NSString).lastPathComponent
    let corrupt = transfer && lock.withLock { corrupted.contains(name) }
    let handle = try video.map { try FileHandle(forReadingFrom: $0) }
    defer { try? handle?.close() }
    try handle?.seek(toOffset: UInt64(offset))
    let block = handle == nil ? Self.block(for: name) : Data()
    var position = offset
    while position < offset + length {
      let count = Int(min(Int64(chunkSize), offset + length - position))
      var data: Data
      if let handle {
        data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw PhoneError.truncated(path) }
      } else {
        data = Data(capacity: count)
        var index = Int(position % Int64(Self.blockSize))
        while data.count < count {
          let take = min(count - data.count, Self.blockSize - index)
          data.append(block[index..<index + take])
          index = 0
        }
      }
      if corrupt && position == 0 { data[data.startIndex] ^= 0xFF }
      if transfer, let bytesPerSecond { Thread.sleep(forTimeInterval: Double(count) / bytesPerSecond) }
      try chunk(data)
      position += Int64(count)
    }
  }

  private static func block(for name: String) -> Data {
    var generator = SeededGenerator(seed: name.utf8.reduce(5381) { $0 &* 33 &+ UInt64($1) })
    return (0..<blockSize / 8).map { _ in generator.next() }.withUnsafeBytes { Data($0) }
  }
}

/// SplitMix64, so the demo clips come out the same on every run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
