import CryptoKit
import Foundation
import os

struct Video: Identifiable, Hashable, Sendable {
  let name: String
  let size: Int64
  let recorded: Date
  let modified: Date

  var id: String { name }
  var path: String { "\(Importer.mediaFolder)/\(name)" }
}

enum ImportError: LocalizedError {
  case mismatch(String)
  case copyMissing(String)
  case copyChanged(String)

  var errorDescription: String? {
    switch self {
    case .mismatch(let name):
      "The copy of \(name) didn't match the iPhone's file, so it was thrown away."
    case .copyMissing(let name):
      "\(name) isn't in the import folder anymore."
    case .copyChanged(let name):
      "The copy of \(name) on the Mac doesn't match the iPhone's file."
    }
  }
}

final class Cancellation: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: false)

  var isCancelled: Bool { state.withLock { $0 } }

  func cancel() {
    state.withLock { $0 = true }
  }
}

/// Copies Blackmagic Camera's videos from the iPhone into a folder on the Mac. A copy only counts
/// once the file read back from the Mac's disk has the same SHA-1 as the one the iPhone computes
/// from its own storage, and a video is only deleted from the iPhone after that check passes
/// again, right before the delete.
final class Importer: @unchecked Sendable {
  static let bundleID = "com.blackmagic-design.DaVinciCamera"
  static let mediaFolder = "/Documents/Media"
  static let partialSuffix = ".importing"

  enum Step: Sendable {
    case copying(Int64)
    case checking
  }

  struct Copy: Sendable {
    let url: URL
    /// False when an identical file was already in the folder.
    let downloaded: Bool
  }

  let files: PhoneFiles
  private let queue = DispatchQueue(label: "com.flaviocopes.blackmagic-cam-importer.transfer")

  init(files: PhoneFiles) {
    self.files = files
  }

  func videos() async throws -> [Video] {
    try await run { [files] in
      try files.list(Self.mediaFolder).compactMap { name -> Video? in
        guard !name.hasPrefix(".") else { return nil }
        let info = try files.info("\(Self.mediaFolder)/\(name)")
        guard !info.isDirectory else { return nil }
        return Video(name: name, size: info.size, recorded: info.created, modified: info.modified)
      }
      .sorted { ($0.recorded, $0.name) < ($1.recorded, $1.name) }
    }
  }

  /// Copies a video into `folder` under its own name. When a file with that name is already there,
  /// it's kept if it matches the iPhone's file, and otherwise the copy gets a new name.
  func copy(_ video: Video, to folder: URL, cancellation: Cancellation, onStep: @escaping @Sendable (Step) -> Void) async throws -> Copy {
    try await run { [files] in
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let existing = folder.appending(path: video.name)
      if Self.size(of: existing) == video.size {
        onStep(.checking)
        if try Self.sha1(of: existing) == files.sha1(video.path) {
          return Copy(url: existing, downloaded: false)
        }
      }

      let partial = folder.appending(path: ".\(video.name)\(Self.partialSuffix)")
      try? FileManager.default.removeItem(at: partial)
      guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
      }
      do {
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var written: Int64 = 0
        try files.read(video.path) { chunk in
          if cancellation.isCancelled { throw CancellationError() }
          try handle.write(contentsOf: chunk)
          written += Int64(chunk.count)
          onStep(.copying(written))
        }
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.close()

        onStep(.checking)
        guard Self.size(of: partial) == video.size, try Self.sha1(of: partial) == files.sha1(video.path) else {
          throw ImportError.mismatch(video.name)
        }
        try FileManager.default.setAttributes(
          [.creationDate: video.recorded, .modificationDate: video.modified], ofItemAtPath: partial.path)
        let destination = Self.freeURL(for: video.name, in: folder)
        try FileManager.default.moveItem(at: partial, to: destination)
        return Copy(url: destination, downloaded: true)
      } catch {
        try? FileManager.default.removeItem(at: partial)
        throw error
      }
    }
  }

  /// Deletes the video from the iPhone, but only if `copy` is still on the Mac, has the same size
  /// as the iPhone's file and reads back from disk with the same SHA-1 the iPhone computes now.
  func deleteOriginal(_ video: Video, copy: URL) async throws {
    try await run { [files] in
      guard let size = Self.size(of: copy) else { throw ImportError.copyMissing(video.name) }
      guard size == (try files.info(video.path).size),
            try Self.sha1(of: copy) == files.sha1(video.path) else {
        throw ImportError.copyChanged(video.name)
      }
      try files.remove(video.path)
    }
  }

  /// Removes the temporary files of copies that never finished, like when the app quit mid-copy.
  static func removeLeftovers(in folder: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasPrefix(".") && name.hasSuffix(partialSuffix) {
      try? FileManager.default.removeItem(at: folder.appending(path: name))
    }
  }

  static func size(of url: URL) -> Int64? {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true, let size = values.fileSize else { return nil }
    return Int64(size)
  }

  /// Reads the file with the cache turned off, so the hash comes from what's on the disk rather
  /// than what's still in memory from the copy.
  static func sha1(of url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
    var hasher = Insecure.SHA1()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
  }

  /// `name`, or "name 2.mov", "name 3.mov" and so on when it's taken, like the Finder does.
  static func freeURL(for name: String, in folder: URL) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var url = folder.appending(path: name)
    var number = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
      number += 1
    }
    return url
  }

  /// Runs blocking iPhone and disk work on the importer's own queue, one job at a time.
  private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Result { try work() })
      }
    }
  }
}
