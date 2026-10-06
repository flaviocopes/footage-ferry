// Talks to the iPhone plugged in over USB and checks the parts the app relies on: finding the
// phone, opening Blackmagic Cam's Documents, listing Media, reading a clip and the iPhone's own
// SHA-1 of it. Run it with scripts/check-iphone.sh. It reads the smallest clip, or the one named
// as an argument. With --write it also creates a scratch
// folder in Blackmagic Cam's Documents, writes, hashes and deletes a small file there, then
// removes the folder. It never touches the videos.
import CryptoKit
import Foundation

@main
enum CheckIPhone {
  static func main() {
    let write = CommandLine.arguments.contains("--write")
    MainActor.assumeIsolated {
      let timeout = DispatchWorkItem {
        print("FAIL no iPhone found over USB in 10 seconds")
        exit(1)
      }
      let watcher = DeviceWatcher { event in
        guard case .connected(let phone) = event, !timeout.isCancelled else { return }
        timeout.cancel()
        Thread.detachNewThread { run(phone, write: write) }
      }
      do {
        try watcher.start()
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
      withExtendedLifetime(watcher) { CFRunLoopRun() }
    }
  }

  static func run(_ phone: Phone, write: Bool) {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
      print(condition ? "ok   \(message)" : "FAIL \(message)")
      if !condition { failures += 1 }
    }
    func seconds(since start: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }

    do {
      do {
        let (_, first) = try phone.openDocuments(of: Importer.bundleID)
        _ = try first.list("/Documents")
      }
      let (name, files) = try phone.openDocuments(of: Importer.bundleID)
      check(true, "opened Blackmagic Cam's Documents on \(name), closed it and opened it again")

      let names = try files.list("/Documents/Media").sorted()
      let infos = try names.map { try files.info("/Documents/Media/\($0)") }
      let clips = zip(names, infos).filter { !$0.1.isDirectory }
      let total = clips.reduce(Int64(0)) { $0 + $1.1.size }
      check(!clips.isEmpty, "Media has \(clips.count) files, \(total / 1_000_000) MB")

      let chosen = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
      let (clip, info) = clips.first { $0.0 == chosen } ?? clips.min { $0.1.size < $1.1.size }!
      let path = "/Documents/Media/\(clip)"
      print("     clip \(clip), \(info.size) bytes, recorded \(info.created)")

      var start = Date()
      let phoneHash = try files.sha1(path)
      print("     iPhone SHA-1 \(phoneHash.hex) in \(seconds(since: start))")

      start = Date()
      var hasher = Insecure.SHA1()
      var received: Int64 = 0
      var firstBytes = Data()
      try files.read(path) { chunk in
        hasher.update(data: chunk)
        received += Int64(chunk.count)
        if firstBytes.count < 8 << 20 { firstBytes += chunk.prefix((8 << 20) - firstBytes.count) }
      }
      let elapsed = Date().timeIntervalSince(start)
      let localHash = Data(hasher.finalize())
      check(received == info.size, "read all \(received) bytes at \(Int(Double(received) / elapsed / 1_000_000)) MB/s")
      check(localHash == phoneHash, "the bytes read hash to the iPhone's SHA-1")

      let rangeStart = Int64(firstBytes.count / 3)
      let rangeLength = Int64(firstBytes.count / 3)
      var range = Data()
      try files.read(path, offset: rangeStart, length: rangeLength) { range += $0 }
      check(range == firstBytes[Int(rangeStart)..<Int(rangeStart + rangeLength)], "a read from the middle of the clip returns the same bytes")

      let (largest, largestInfo) = clips.max { $0.1.size < $1.1.size }!
      let counting = CountingFiles(files)
      let largestVideo = Video(name: largest, size: largestInfo.size, recorded: largestInfo.created, modified: largestInfo.modified)
      start = Date()
      let thumbnail = try runAsync { await Thumbnails.make(largestVideo, files: counting) }
      check(thumbnail != nil, "a thumbnail of \(largest) (\(largestInfo.size / 1_000_000) MB) read \(counting.bytes / 1000) KB in \(seconds(since: start))")

      let folder = URL.temporaryDirectory.appending(path: "blackmagic-importer-check-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }
      let video = Video(name: clip, size: info.size, recorded: info.created, modified: info.modified)
      let copy = try runAsync { try await Importer(files: files).copy(video, to: folder, cancellation: Cancellation()) { _ in } }
      let copyHash = try Importer.sha1(of: copy.url)
      check(copy.downloaded && copyHash == phoneHash, "the importer copies the clip and checks it")

      do {
        _ = try files.info("/Documents/Media/no-such-clip.mov")
        check(false, "a missing file throws")
      } catch PhoneError.afc(let code, _) {
        check(code == 8 || code == 4, "a missing file throws AFC error \(code)")
      }

      if write {
        let folder = "/Documents/Importer check \(UUID().uuidString.prefix(8))"
        let file = "\(folder)/scratch.bin"
        let bytes = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try files.makeDirectory(folder)
        try files.write(file, bytes)
        check(try files.info(file).size == Int64(bytes.count), "wrote a scratch file")
        check(try files.sha1(file) == Data(Insecure.SHA1.hash(data: bytes)), "the iPhone hashes the scratch file correctly")
        try files.remove(file)
        check((try? files.info(file)) == nil, "deleted the scratch file")
        try files.remove(folder)
        check(try !files.list("/Documents").contains { $0.hasPrefix("Importer check") }, "removed the scratch folder")
      }
    } catch {
      check(false, error.localizedDescription)
    }
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
  }
}

extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Counts the bytes previews read, to check they only read a small part of a clip.
final class CountingFiles: PhoneFiles, @unchecked Sendable {
  private let files: PhoneFiles
  private let lock = NSLock()
  private var count: Int64 = 0

  init(_ files: PhoneFiles) {
    self.files = files
  }

  var bytes: Int64 { lock.withLock { count } }

  func list(_ path: String) throws -> [String] { try files.list(path) }
  func info(_ path: String) throws -> FileInfo { try files.info(path) }
  func sha1(_ path: String) throws -> Data { try files.sha1(path) }
  func remove(_ path: String) throws { try files.remove(path) }

  func read(_ path: String, _ chunk: (Data) throws -> Void) throws {
    try files.read(path) { data in
      lock.withLock { count += Int64(data.count) }
      try chunk(data)
    }
  }

  func read(_ path: String, offset: Int64, length: Int64, _ chunk: (Data) throws -> Void) throws {
    try files.read(path, offset: offset, length: length) { data in
      lock.withLock { count += Int64(data.count) }
      try chunk(data)
    }
  }
}

/// Waits on this thread for async work, since the checks run on a plain thread.
func runAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: Result<T, Error>!
  Task {
    do { result = .success(try await work()) } catch { result = .failure(error) }
    semaphore.signal()
  }
  semaphore.wait()
  return try result.get()
}
