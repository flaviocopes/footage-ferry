// Checks the importer and the app model against made-up iPhone files (DemoFiles): copying,
// checking, name clashes, corrupted copies, cancelling, and above all that nothing is deleted
// from the iPhone unless the copy on the Mac matches it. Run it with scripts/test.sh. It only
// writes to a temporary folder.
import CryptoKit
import Foundation

@main
enum Tests {
  @MainActor
  static func main() async {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
      print(condition ? "ok   \(message)" : "FAIL \(message)")
      if !condition { failures.append(message) }
    }

    let root = URL.temporaryDirectory.appending(path: "blackmagic-importer-test-\(UUID().uuidString)")
    let day = Date(timeIntervalSince1970: 1_780_000_000)
    func phone() -> DemoFiles {
      DemoFiles(clips: [
        "A001_08021711_C033.mov": .init(size: 3_500_123, recorded: day),
        "A001_08021711_C034.mov": .init(size: 1_048_576, recorded: day + 60),
        "A001_08021735_C035.mov": .init(size: 9_437_185, recorded: day + 120),
        "A001_08041048_C036.mov": .init(size: 12, recorded: day + 180),
      ])
    }
    func files(in folder: URL) -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
    func expectError(_ message: String, _ work: () async throws -> Void, matches: (Error) -> Bool) async {
      do {
        try await work()
        check(false, "\(message) (no error)")
      } catch {
        check(matches(error), "\(message) (\(error.localizedDescription))")
      }
    }

    // Importer
    do {
      let iphone = phone()
      let importer = Importer(files: iphone)
      let folder = root.appending(path: "importer")
      let videos = try await importer.videos()
      check(videos.map(\.name) == ["A001_08021711_C033.mov", "A001_08021711_C034.mov", "A001_08021735_C035.mov", "A001_08041048_C036.mov"],
            "lists the clips oldest first and skips the Proxy folder")
      let first = videos[0]

      var whole = Data()
      try iphone.read(videos[2].path) { whole += $0 }
      var range = Data()
      try iphone.read(videos[2].path, offset: 1_048_476, length: 2_000_200) { range += $0 }
      check(range == whole[1_048_476..<3_048_676], "a range read returns the same bytes as the whole file, across chunks")

      let copy = try await importer.copy(first, to: folder, cancellation: Cancellation()) { _ in }
      check(copy.downloaded && copy.url == folder.appending(path: first.name), "copies a clip under its own name")
      check(Importer.size(of: copy.url) == first.size, "the copy has the clip's size")
      check(try Importer.sha1(of: copy.url) == iphone.sha1(first.path), "the copy has the clip's SHA-1")
      let created = try FileManager.default.attributesOfItem(atPath: copy.url.path)[.creationDate] as? Date
      check(created == first.recorded, "the copy keeps the recording date")
      check(files(in: folder) == [first.name], "no temporary file is left behind")

      let again = try await importer.copy(first, to: folder, cancellation: Cancellation()) { _ in }
      check(!again.downloaded && again.url == copy.url && files(in: folder) == [first.name],
            "an identical file already in the folder is kept, not copied again")

      let second = videos[1]
      let other = folder.appending(path: second.name)
      try Data("someone else's file".utf8).write(to: other)
      let renamed = try await importer.copy(second, to: folder, cancellation: Cancellation()) { _ in }
      check(renamed.url.lastPathComponent == "A001_08021711_C034 2.mov", "a different file with the same name gets a new name")
      check(try Data(contentsOf: other) == Data("someone else's file".utf8), "the other file is left alone")

      let third = videos[2]
      let sameSize = folder.appending(path: third.name)
      try Data(count: Int(third.size)).write(to: sameSize)
      let renamedAgain = try await importer.copy(third, to: folder, cancellation: Cancellation()) { _ in }
      check(renamedAgain.downloaded && renamedAgain.url.lastPathComponent == "A001_08021735_C035 2.mov",
            "a file with the same name and size but other bytes isn't taken for the clip")

      let fourth = videos[3]
      iphone.corrupted = [fourth.name]
      await expectError("a corrupted copy is thrown away", {
        _ = try await importer.copy(fourth, to: folder, cancellation: Cancellation()) { _ in }
      }, matches: { if case ImportError.mismatch = $0 { true } else { false } })
      check(!files(in: folder).contains { $0.contains("C036") }, "nothing of the corrupted copy is left")
      iphone.corrupted = []

      let cancelled = Cancellation()
      cancelled.cancel()
      await expectError("a cancelled copy stops", {
        _ = try await importer.copy(fourth, to: folder, cancellation: cancelled) { _ in }
      }, matches: { $0 is CancellationError })
      check(!files(in: folder).contains { $0.contains("C036") }, "nothing of the cancelled copy is left")

      try Data().write(to: folder.appending(path: ".A001_08041048_C036.mov.importing"))
      Importer.removeLeftovers(in: folder)
      check(!files(in: folder).contains { $0.hasSuffix(".importing") } && files(in: folder).contains(first.name),
            "leftover temporary files are removed and nothing else")

      // Deleting
      let tampered = folder.appending(path: renamed.url.lastPathComponent)
      var bytes = try Data(contentsOf: tampered)
      bytes[bytes.count / 2] ^= 1
      try bytes.write(to: tampered)
      await expectError("a copy changed on the Mac stops the delete", {
        try await importer.deleteOriginal(second, copy: tampered)
      }, matches: { if case ImportError.copyChanged = $0 { true } else { false } })
      check(iphone.contains(second.name), "the clip is still on the iPhone")

      await expectError("a missing copy stops the delete", {
        try await importer.deleteOriginal(fourth, copy: folder.appending(path: fourth.name))
      }, matches: { if case ImportError.copyMissing = $0 { true } else { false } })
      check(iphone.contains(fourth.name), "the clip is still on the iPhone")

      let truncated = folder.appending(path: "truncated.mov")
      try Data(try Data(contentsOf: copy.url).dropLast()).write(to: truncated)
      await expectError("a shorter copy stops the delete", {
        try await importer.deleteOriginal(first, copy: truncated)
      }, matches: { if case ImportError.copyChanged = $0 { true } else { false } })

      try await importer.deleteOriginal(first, copy: copy.url)
      check(!iphone.contains(first.name), "a matching copy lets the delete through")
      check(FileManager.default.fileExists(atPath: copy.url.path), "the copy on the Mac stays")
    } catch {
      check(false, "importer: \(error.localizedDescription)")
    }

    // USB speed
    check(USBLink.needsFasterCable(model: "iPhone17,1", speed: 3), "an iPhone 16 Pro on a USB 2 link gets the slow cable notice")
    check(!USBLink.needsFasterCable(model: "iPhone17,1", speed: 5), "an iPhone 16 Pro on a 10 Gb/s link doesn't")
    check(!USBLink.needsFasterCable(model: "iPhone17,3", speed: 3), "an iPhone 16, which only has USB 2, doesn't")
    check(!USBLink.needsFasterCable(model: "iPhone17,1", speed: nil), "an unknown link speed doesn't")

    // AppModel
    let suite = "blackmagic-importer-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let folder = root.appending(path: "model")
    let model = AppModel(defaults: defaults)
    check(model.destination == AppModel.defaultDestination, "imports into ~/Movies/Blackmagic Camera by default")
    model.setDestination(folder)
    check(AppModel(defaults: defaults).destination.path == folder.path, "remembers the import folder")

    let iphone = phone()
    await model.connect(name: "iPhone 16 Pro", files: iphone)
    check(model.phase == .ready && model.videos.count == 4, "connects and lists 4 videos")
    check(model.videos.allSatisfy { model.state(of: $0) == .onPhone }, "nothing is on the Mac yet")

    let byDate = model.videos.map(\.name)
    model.sortOrder = [KeyPathComparator(\.size, order: .reverse)]
    check(model.videos.map(\.size) == [9_437_185, 3_500_123, 1_048_576, 12], "sorts by size, largest first")
    await model.reload()
    check(model.videos.map(\.size) == [9_437_185, 3_500_123, 1_048_576, 12], "keeps the sort after a reload")
    check(AppModel(defaults: defaults).sortOrder == [KeyPathComparator(\Video.size, order: .reverse)], "remembers the sort")
    model.sortOrder = [KeyPathComparator(\.recorded)]
    check(model.videos.map(\.name) == byDate, "sorts by recording date, oldest first")

    await model.importVideos(Array(model.videos.prefix(2)))
    check(model.videos.prefix(2).allSatisfy { model.state(of: $0) == .imported }, "imported videos are marked imported")
    check(model.deleteOffer?.videos.count == 2 && model.deleteOffer?.failed == 0, "offers to delete the 2 imported videos")
    check(model.notice == "Imported 2 videos into model.", "says what it imported")
    check(model.batch == nil, "the import is over")

    if let offer = model.deleteOffer {
      model.deleteOffer = nil
      await model.deleteFromPhone(offer.videos)
    }
    check(model.videos.count == 2 && !iphone.contains("A001_08021711_C033.mov"), "deletes them from the iPhone")
    check(files(in: folder) == ["A001_08021711_C033.mov", "A001_08021711_C034.mov"], "the copies stay on the Mac")
    check(model.notice == "Deleted 2 videos from the iPhone.", "says what it deleted")

    let third = model.videos[0]
    let placed = folder.appending(path: third.name)
    var contents = Data()
    try? iphone.read(third.path) { contents.append($0) }
    try? contents.write(to: placed)
    model.setDestination(folder)
    check(model.state(of: third) == .onMac, "a matching file already in the folder shows as on the Mac")

    iphone.corrupted = [model.videos[1].name]
    await model.importVideos(model.videos)
    check(model.state(of: third) == .imported && files(in: folder).filter { $0.contains("C035") }.count == 1,
          "a video already on the Mac is checked, not copied again")
    check(model.state(of: model.videos[1]).isFailed, "a corrupted copy shows as failed")
    check(model.deleteOffer?.videos.map(\.name) == [third.name] && model.deleteOffer?.failed == 1,
          "only the checked video is offered for deletion")
    model.deleteOffer = nil

    var bytes = (try? Data(contentsOf: placed)) ?? Data()
    bytes[0] ^= 1
    try? bytes.write(to: placed)
    await model.deleteFromPhone([third])
    check(iphone.contains(third.name) && model.videos.contains(third), "a copy changed after the import keeps the video on the iPhone")
    check(model.alert?.hasPrefix("Kept 1 video on the iPhone.") == true, "and says why")

    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
    print(failures.isEmpty ? "all tests passed" : "\(failures.count) tests failed")
    exit(failures.isEmpty ? 0 : 1)
  }
}

extension VideoState {
  var isFailed: Bool {
    if case .failed = self { true } else { false }
  }
}
