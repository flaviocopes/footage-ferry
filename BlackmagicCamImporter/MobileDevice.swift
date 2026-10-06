import Foundation

enum PhoneError: LocalizedError {
  case frameworkMissing
  case notPaired
  case mobileDevice(Int32, String)
  case appNotInstalled
  case vendFailed(String)
  case disconnected
  case badReply
  case afc(UInt64, String?)
  case truncated(String)

  var errorDescription: String? {
    switch self {
    case .frameworkMissing:
      "MobileDevice.framework isn't on this Mac."
    case .notPaired:
      "Unlock your iPhone and tap Trust when it asks whether to trust this computer."
    case .mobileDevice(let code, let text):
      "The iPhone didn't answer (\(text), \(String(format: "0x%08x", UInt32(bitPattern: code))). Unlock it and try again."
    case .appNotInstalled:
      "Blackmagic Cam isn't installed on this iPhone."
    case .vendFailed(let error):
      "The iPhone refused to share Blackmagic Cam's files (\(error))."
    case .disconnected:
      "The iPhone was disconnected."
    case .badReply:
      "The iPhone sent a reply the app doesn't understand."
    case .afc(let code, let path):
      "The iPhone reported error \(code) (\(AFCClient.errorName(code)))\(path.map { " for \(($0 as NSString).lastPathComponent)" } ?? "")."
    case .truncated(let path):
      "\((path as NSString).lastPathComponent) ended before its full size was read."
    }
  }
}

/// MobileDevice.framework, the private framework Finder and Xcode use to talk to iPhones. It
/// has no public headers, so the functions are looked up at runtime.
struct MobileDevice: @unchecked Sendable {
  typealias DeviceRef = UnsafeMutableRawPointer
  typealias ConnectionRef = UnsafeMutableRawPointer
  typealias NotificationCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

  let subscribe: @convention(c) (NotificationCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
  let connect: @convention(c) (DeviceRef) -> Int32
  let disconnect: @convention(c) (DeviceRef) -> Int32
  let isPaired: @convention(c) (DeviceRef) -> Int32
  let pair: @convention(c) (DeviceRef) -> Int32
  let validatePairing: @convention(c) (DeviceRef) -> Int32
  let startSession: @convention(c) (DeviceRef) -> Int32
  let stopSession: @convention(c) (DeviceRef) -> Int32
  let interfaceType: @convention(c) (DeviceRef) -> Int32
  let copyValue: @convention(c) (DeviceRef, CFString?, CFString) -> Unmanaged<CFTypeRef>?
  let copyIdentifier: @convention(c) (DeviceRef) -> Unmanaged<CFString>?
  let startService: @convention(c) (DeviceRef, CFString, CFDictionary?, UnsafeMutablePointer<ConnectionRef?>) -> Int32
  let send: @convention(c) (ConnectionRef, UnsafeRawPointer, Int) -> Int32
  let receive: @convention(c) (ConnectionRef, UnsafeMutableRawPointer, Int) -> Int32
  let socket: @convention(c) (ConnectionRef) -> Int32
  let invalidate: @convention(c) (ConnectionRef) -> Void
  let errorText: @convention(c) (Int32) -> Unmanaged<CFString>?

  static let shared = MobileDevice()

  private struct Missing: Error {}

  private init?() {
    guard let library = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else {
      return nil
    }
    func load<T>(_ name: String) throws -> T {
      guard let symbol = dlsym(library, name) else { throw Missing() }
      return unsafeBitCast(symbol, to: T.self)
    }
    do {
      subscribe = try load("AMDeviceNotificationSubscribe")
      connect = try load("AMDeviceConnect")
      disconnect = try load("AMDeviceDisconnect")
      isPaired = try load("AMDeviceIsPaired")
      pair = try load("AMDevicePair")
      validatePairing = try load("AMDeviceValidatePairing")
      startSession = try load("AMDeviceStartSession")
      stopSession = try load("AMDeviceStopSession")
      interfaceType = try load("AMDeviceGetInterfaceType")
      copyValue = try load("AMDeviceCopyValue")
      copyIdentifier = try load("AMDeviceCopyDeviceIdentifier")
      startService = try load("AMDeviceSecureStartService")
      send = try load("AMDServiceConnectionSend")
      receive = try load("AMDServiceConnectionReceive")
      socket = try load("AMDServiceConnectionGetSocket")
      invalidate = try load("AMDServiceConnectionInvalidate")
      errorText = try load("AMDCopyErrorText")
    } catch {
      return nil
    }
  }

  func check(_ code: Int32) throws {
    guard code != 0 else { return }
    let text = errorText(code)?.takeRetainedValue() as String? ?? "unknown error"
    throw PhoneError.mobileDevice(code, text)
  }
}

/// An iPhone plugged in with a USB cable.
final class Phone: @unchecked Sendable {
  let id: String
  private let api: MobileDevice
  private let device: MobileDevice.DeviceRef

  init(api: MobileDevice, device: MobileDevice.DeviceRef) {
    self.api = api
    self.device = device
    _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
    id = api.copyIdentifier(device)?.takeRetainedValue() as String? ?? UUID().uuidString
  }

  deinit {
    Unmanaged<AnyObject>.fromOpaque(device).release()
  }

  /// Opens the Documents folder of an app that shares its files, the folder Finder shows under
  /// Files. Returns the iPhone's name too, which needs the same session. An iPhone that never
  /// trusted this Mac gets asked to, and this throws `notPaired` until someone taps Trust on it.
  func openDocuments(of bundleID: String) throws -> (name: String, files: AFCClient) {
    try api.check(api.connect(device))
    defer { _ = api.disconnect(device) }
    if api.isPaired(device) != 1 && api.pair(device) != 0 {
      throw PhoneError.notPaired
    }
    try api.check(api.validatePairing(device))
    try api.check(api.startSession(device))
    defer { _ = api.stopSession(device) }

    let name = api.copyValue(device, nil, "DeviceName" as CFString)?.takeRetainedValue() as? String ?? "iPhone"
    var handle: MobileDevice.ConnectionRef?
    let options = ["CloseOnInvalidate": true, "InvalidateOnDetach": true] as CFDictionary
    try api.check(api.startService(device, "com.apple.mobile.house_arrest" as CFString, options, &handle))
    guard let handle else { throw PhoneError.badReply }
    let connection = ServiceConnection(api: api, handle: handle)

    try connection.sendPlist(["Command": "VendDocuments", "Identifier": bundleID])
    let reply = try connection.receivePlist()
    if let error = reply["Error"] as? String {
      throw error == "ApplicationLookupFailed" ? PhoneError.appNotInstalled : PhoneError.vendFailed(error)
    }
    return (name, AFCClient(connection: connection))
  }
}

/// A connection to one service on the iPhone. MobileDevice adds TLS when the service asks for it.
final class ServiceConnection: @unchecked Sendable {
  private let api: MobileDevice
  private let handle: MobileDevice.ConnectionRef

  init(api: MobileDevice, handle: MobileDevice.ConnectionRef) {
    self.api = api
    self.handle = handle
    var timeout = timeval(tv_sec: 60, tv_usec: 0)
    let fd = api.socket(handle)
    if fd >= 0 {
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
  }

  deinit {
    api.invalidate(handle)
    Unmanaged<AnyObject>.fromOpaque(handle).release()
  }

  func send(_ data: Data) throws {
    try data.withUnsafeBytes { buffer in
      var sent = 0
      while sent < buffer.count {
        let count = api.send(handle, buffer.baseAddress! + sent, buffer.count - sent)
        guard count > 0 else { throw PhoneError.disconnected }
        sent += Int(count)
      }
    }
  }

  func receive(_ count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
      var received = 0
      while received < count {
        let read = api.receive(handle, buffer.baseAddress! + received, count - received)
        guard read > 0 else { throw PhoneError.disconnected }
        received += Int(read)
      }
    }
    return data
  }

  /// Lockdown services frame each property list with its length as a big-endian 32-bit number.
  func sendPlist(_ plist: [String: Any]) throws {
    let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    var length = UInt32(body.count).bigEndian
    try send(Data(bytes: &length, count: 4) + body)
  }

  func receivePlist() throws -> [String: Any] {
    let length = try receive(4).reduce(0) { $0 << 8 | Int($1) }
    let body = try receive(length)
    guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
      throw PhoneError.badReply
    }
    return plist
  }
}

/// Tells the app when an iPhone is plugged in or unplugged over USB. Wi-Fi connections are
/// ignored: they're slow, and the Apple TV shows up there too.
@MainActor
final class DeviceWatcher {
  enum Event {
    case connected(Phone)
    case disconnected(id: String)
  }

  private let onEvent: (Event) -> Void
  private var subscription: UnsafeMutableRawPointer?

  init(onEvent: @escaping (Event) -> Void) {
    self.onEvent = onEvent
  }

  func start() throws {
    guard let api = MobileDevice.shared else { throw PhoneError.frameworkMissing }
    let context = Unmanaged.passUnretained(self).toOpaque()
    try api.check(api.subscribe({ info, context in
      guard let info, let context, let api = MobileDevice.shared else { return }
      let device = info.load(as: MobileDevice.DeviceRef.self)
      let message = info.load(fromByteOffset: 8, as: UInt32.self)
      let watcher = Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue()
      let event: Event
      switch message {
      case 1:
        guard api.interfaceType(device) == 1 else { return }
        event = .connected(Phone(api: api, device: device))
      case 2:
        guard api.interfaceType(device) == 1,
              let id = api.copyIdentifier(device)?.takeRetainedValue() as String? else { return }
        event = .disconnected(id: id)
      default:
        return
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { watcher.onEvent(event) }
      }
    }, 0, 0, context, &subscription))
  }
}
