import CryptoKit
import Foundation

struct FileInfo: Sendable {
  let size: Int64
  let isDirectory: Bool
  let created: Date
  let modified: Date
}

/// Blackmagic Cam's files on the iPhone. `AFCClient` is the real thing, `DemoFiles` stands in for
/// it in the demo and the tests. Every call blocks until the iPhone answers.
protocol PhoneFiles: AnyObject, Sendable {
  func list(_ path: String) throws -> [String]
  func info(_ path: String) throws -> FileInfo
  /// Streams the whole file, in order, and throws unless it gets exactly `info(path).size` bytes.
  func read(_ path: String, _ chunk: (Data) throws -> Void) throws
  /// Streams `length` bytes starting at `offset`, in smaller chunks, for previews.
  func read(_ path: String, offset: Int64, length: Int64, _ chunk: (Data) throws -> Void) throws
  /// The SHA-1 of the file, computed by the iPhone from what's on its storage.
  func sha1(_ path: String) throws -> Data
  func remove(_ path: String) throws
}

/// A client for AFC, the protocol iOS uses to share an app's files with a Mac. Each request is
/// a 40-byte header ("CFA6LPAA", total length, header length, packet number, operation) followed
/// by its arguments, and the iPhone answers each one before the next is sent.
final class AFCClient: PhoneFiles, @unchecked Sendable {
  private enum Operation: UInt64 {
    case status = 0x01
    case data = 0x02
    case readDirectory = 0x03
    case removePath = 0x08
    case makeDirectory = 0x09
    case fileInfo = 0x0A
    case open = 0x0D
    case openResult = 0x0E
    case read = 0x0F
    case write = 0x10
    case seek = 0x11
    case close = 0x14
    case fileHash = 0x1D
  }

  private enum Mode: UInt64 {
    case readOnly = 1
    case writeOnly = 3
  }

  private static let magic = Data("CFA6LPAA".utf8)
  private static let headerSize = 40
  private static let chunkSize: Int64 = 4 << 20
  /// Smaller chunks for previews, so a cancelled request stops quickly and other requests,
  /// like an import, get their turn on the connection sooner.
  private static let rangeChunkSize: Int64 = 1 << 20
  private static let notSupported: UInt64 = 15

  private let connection: ServiceConnection
  private let lock = NSLock()
  private var packetNumber: UInt64 = 0

  init(connection: ServiceConnection) {
    self.connection = connection
  }

  func list(_ path: String) throws -> [String] {
    let reply = try perform(.readDirectory, cString(path), path: path)
    return reply.split(separator: 0, omittingEmptySubsequences: true)
      .map { String(decoding: $0, as: UTF8.self) }
      .filter { $0 != "." && $0 != ".." }
  }

  func info(_ path: String) throws -> FileInfo {
    let fields = try perform(.fileInfo, cString(path), path: path)
      .split(separator: 0, omittingEmptySubsequences: false)
      .map { String(decoding: $0, as: UTF8.self) }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: fields.count - 1, by: 2) {
      values[fields[index]] = fields[index + 1]
    }
    func date(_ key: String) -> Date {
      Date(timeIntervalSince1970: (Double(values[key] ?? "") ?? 0) / 1_000_000_000)
    }
    return FileInfo(
      size: Int64(values["st_size"] ?? "") ?? 0,
      isDirectory: values["st_ifmt"] == "S_IFDIR",
      created: date("st_birthtime"),
      modified: date("st_mtime")
    )
  }

  func read(_ path: String, _ chunk: (Data) throws -> Void) throws {
    try read(path, offset: 0, length: info(path).size, chunkSize: Self.chunkSize, chunk)
  }

  func read(_ path: String, offset: Int64, length: Int64, _ chunk: (Data) throws -> Void) throws {
    try read(path, offset: offset, length: length, chunkSize: Self.rangeChunkSize, chunk)
  }

  private func read(_ path: String, offset: Int64, length: Int64, chunkSize: Int64, _ chunk: (Data) throws -> Void) throws {
    guard length > 0 else { return }
    let handle = try open(path, .readOnly)
    defer { close(handle) }
    if offset > 0 {
      _ = try perform(.seek, uint64(handle) + uint64(UInt64(SEEK_SET)) + uint64(UInt64(offset)), path: path)
    }
    var remaining = length
    while remaining > 0 {
      let data = try perform(.read, uint64(handle) + uint64(UInt64(min(chunkSize, remaining))), path: path)
      guard !data.isEmpty else { throw PhoneError.truncated(path) }
      try chunk(data)
      remaining -= Int64(data.count)
    }
  }

  func sha1(_ path: String) throws -> Data {
    do {
      let hash = try perform(.fileHash, cString(path), path: path)
      guard hash.count == Insecure.SHA1.byteCount else { throw PhoneError.badReply }
      return hash
    } catch PhoneError.afc(Self.notSupported, _) {
      var hasher = Insecure.SHA1()
      try read(path) { hasher.update(data: $0) }
      return Data(hasher.finalize())
    }
  }

  func remove(_ path: String) throws {
    _ = try perform(.removePath, cString(path), path: path)
  }

  func makeDirectory(_ path: String) throws {
    _ = try perform(.makeDirectory, cString(path), path: path)
  }

  func write(_ path: String, _ data: Data) throws {
    let handle = try open(path, .writeOnly)
    defer { close(handle) }
    _ = try perform(.write, uint64(handle), data, path: path)
  }

  private func open(_ path: String, _ mode: Mode) throws -> UInt64 {
    let reply = try perform(.open, uint64(mode.rawValue) + cString(path), path: path)
    guard reply.count >= 8 else { throw PhoneError.badReply }
    return reply.littleEndianUInt64(at: 0)
  }

  private func close(_ handle: UInt64) {
    _ = try? perform(.close, uint64(handle))
  }

  /// Sends one request and returns the data of the reply. `arguments` go in the header part of
  /// the packet, `payload` after it, which only writes use.
  private func perform(_ operation: Operation, _ arguments: Data, _ payload: Data = Data(), path: String? = nil) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let headerLength = Self.headerSize + arguments.count
    var packet = Self.magic
    packet += uint64(UInt64(headerLength + payload.count))
    packet += uint64(UInt64(headerLength))
    packet += uint64(packetNumber)
    packet += uint64(operation.rawValue)
    packet += arguments
    packet += payload
    packetNumber += 1
    try connection.send(packet)

    let header = try connection.receive(Self.headerSize)
    guard header.prefix(8) == Self.magic else { throw PhoneError.badReply }
    let length = Int(header.littleEndianUInt64(at: 8))
    guard length >= Self.headerSize else { throw PhoneError.badReply }
    let reply = try connection.receive(length - Self.headerSize)
    if header.littleEndianUInt64(at: 32) == Operation.status.rawValue {
      guard reply.count >= 8 else { throw PhoneError.badReply }
      let code = reply.littleEndianUInt64(at: 0)
      if code != 0 { throw PhoneError.afc(code, path) }
      return Data()
    }
    return reply
  }

  private func cString(_ string: String) -> Data {
    Data(string.utf8) + [0]
  }

  private func uint64(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  static func errorName(_ code: UInt64) -> String {
    let names: [UInt64: String] = [
      1: "unknown error", 4: "read error", 5: "write error", 7: "invalid argument", 8: "file not found",
      9: "is a folder", 10: "permission denied", 11: "not connected", 12: "timed out", 15: "not supported",
      16: "already exists", 17: "busy", 18: "no space left", 20: "input/output error",
    ]
    return names[code] ?? "AFC error"
  }
}

extension Data {
  func littleEndianUInt64(at offset: Int) -> UInt64 {
    let start = startIndex + offset
    return self[start..<start + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
  }
}
