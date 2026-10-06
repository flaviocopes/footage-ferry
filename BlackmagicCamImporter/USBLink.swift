import Foundation
import IOKit

/// The speed of the iPhone's USB connection, read from the IORegistry like System Information
/// does. A USB 2 cable, or a USB 2 port or hub, caps a copy at 480 Mb/s, about 40 MB/s.
enum USBLink {
  /// iPhones with a USB 3 port, up to 10 Gb/s with a USB 3 cable: the Pro models since the 15 Pro.
  static let usb3Models: Set<String> = ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone18,1", "iPhone18,2"]

  /// IOUSBHostDevice's USBSpeed: 3 is USB 2's high speed, 4 and 5 are USB 3's 5 and 10 Gb/s.
  private static let firstUSB3Speed = 4

  /// True when the iPhone could copy faster than its connection allows.
  static func needsFasterCable(model: String, speed: Int?) -> Bool {
    guard let speed else { return false }
    return usb3Models.contains(model) && speed < firstUSB3Speed
  }

  /// The USBSpeed of the iPhone with this identifier. iPhones use their identifier as their USB
  /// serial number, without the dash on newer models.
  static func speed(ofDevice identifier: String) -> Int? {
    let serial = identifier.replacingOccurrences(of: "-", with: "")
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
      return nil
    }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
      defer {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }
      guard let number = property(service, "USB Serial Number") as? String,
            number.replacingOccurrences(of: "-", with: "") == serial else { continue }
      return property(service, "USBSpeed") as? Int
    }
    return nil
  }

  private static func property(_ service: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }
}
