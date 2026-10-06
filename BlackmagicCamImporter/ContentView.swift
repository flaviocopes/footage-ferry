import AppKit
import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    content
      .navigationTitle("Importer for Blackmagic Camera")
      .navigationSubtitle(subtitle)
      .toolbar { toolbar }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if model.phase == .ready {
          StatusBar(model: model)
        }
      }
      .alert(deleteTitle, isPresented: isOfferingDelete, presenting: model.deleteOffer) { offer in
        Button("Delete from iPhone", role: .destructive) {
          Task { await model.deleteFromPhone(offer.videos) }
        }
        Button("Keep on iPhone", role: .cancel) {}
          .keyboardShortcut(.defaultAction)
      } message: { offer in
        Text(deleteMessage(offer))
      }
      .alert("Something Went Wrong", isPresented: isShowingAlert) {
        Button("OK") {}
      } message: {
        Text(model.alert ?? "")
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .waiting:
      ContentUnavailableView {
        Label("Connect Your iPhone", systemImage: "cable.connector")
      } description: {
        Text("Plug it into this Mac with a USB cable and unlock it. The videos you recorded with Blackmagic Camera show up here.")
      }
    case .connecting:
      ProgressView("Opening Blackmagic Camera…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .needsTrust:
      ContentUnavailableView {
        Label("Trust This Mac", systemImage: "lock.iphone")
      } description: {
        Text("Unlock your iPhone and tap Trust when it asks whether to trust this computer. The videos show up right after.")
      }
    case .failed(let message):
      ContentUnavailableView {
        Label("Can't Open Blackmagic Camera", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { model.retry() }
      }
    case .ready where model.videos.isEmpty:
      ContentUnavailableView {
        Label("No Videos", systemImage: "film.stack")
      } description: {
        Text("Blackmagic Camera on \(model.phoneName ?? "the iPhone") has no videos in its own storage. Clips it saved to Photos or to an external drive don't show up here.")
      }
    case .ready:
      VideoTable(model: model)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem {
      Menu {
        Button("Choose Folder…") { FolderPicker.choose(for: model) }
        Button("Show in Finder") { NSWorkspace.shared.open(model.destination) }
          .disabled(!FileManager.default.fileExists(atPath: model.destination.path))
      } label: {
        Label(model.destination.lastPathComponent, systemImage: "folder")
          .labelStyle(.titleAndIcon)
      }
      .help("Videos are saved in \(model.destination.path)")
      .disabled(model.isBusy)
    }
    ToolbarItem {
      Button("Reload", systemImage: "arrow.clockwise") {
        Task { await model.reload() }
      }
      .help("Read the list of videos from the iPhone again")
      .disabled(model.phase != .ready || model.isBusy)
    }
    ToolbarItem {
      Button(model.selection.isEmpty ? "Import Selected" : "Import \(model.selection.count) Selected") {
        Task { await model.importVideos(model.selectedVideos) }
      }
      .disabled(model.selection.isEmpty || model.isBusy)
    }
    ToolbarItem {
      Button("Import All") {
        Task { await model.importVideos(model.videos) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.videos.isEmpty || model.isBusy)
    }
  }

  private var subtitle: String {
    guard let name = model.phoneName, model.phase == .ready else { return "" }
    let count = model.videos.count == 1 ? "1 video" : "\(model.videos.count) videos"
    return "\(name) · \(count) · \(model.totalBytes.formatted(.byteCount(style: .file)))"
  }

  private var isOfferingDelete: Binding<Bool> {
    Binding(get: { model.deleteOffer != nil }, set: { if !$0 { model.deleteOffer = nil } })
  }

  private var isShowingAlert: Binding<Bool> {
    Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
  }

  private var deleteTitle: String {
    guard let offer = model.deleteOffer else { return "" }
    let size = offer.bytes.formatted(.byteCount(style: .file))
    return offer.videos.count == 1
      ? "Delete 1 video (\(size)) from the iPhone?"
      : "Delete \(offer.videos.count) videos (\(size)) from the iPhone?"
  }

  private func deleteMessage(_ offer: DeleteOffer) -> String {
    let folder = model.destination.lastPathComponent
    var message = switch offer.videos.count {
    case 1: "It's in \(folder) on your Mac."
    case 2: "Both are in \(folder) on your Mac."
    default: "All \(offer.videos.count) are in \(folder) on your Mac."
    }
    message += " Right before deleting each one, the app checks that the copy on the Mac matches the iPhone's file byte for byte. If it doesn't, the video stays on the iPhone. You can't undo this."
    if offer.failed > 0 {
      message += offer.failed == 1
        ? "\n\n1 video couldn't be imported and stays on the iPhone."
        : "\n\n\(offer.failed) videos couldn't be imported and stay on the iPhone."
    }
    return message
  }
}

struct VideoTable: View {
  @Bindable var model: AppModel

  var body: some View {
    Table(model.videos, selection: $model.selection, sortOrder: $model.sortOrder) {
      TableColumn("Name", value: \.name) { video in
        HStack(spacing: 10) {
          Thumbnail(image: model.thumbnails[video.id])
          Text(video.name)
        }
        .task(id: video.id) { await model.loadThumbnail(for: video) }
      }
      .width(min: 260, ideal: 320)
      TableColumn("Recorded", value: \.recorded) { video in
        Text(video.recorded, format: .dateTime.day().month(.abbreviated).year().hour().minute())
      }
      .width(min: 130, ideal: 170)
      TableColumn("Size", value: \.size) { video in
        Text(video.size.formatted(.byteCount(style: .file)))
          .monospacedDigit()
      }
      .width(min: 70, ideal: 80)
      TableColumn("Status") { video in
        StatusCell(state: model.state(of: video))
      }
      .width(min: 150, ideal: 190)
    }
    .onKeyPress(.space) {
      guard !model.selection.isEmpty else { return .ignored }
      model.preview(model.selection)
      return .handled
    }
    .sheet(item: $model.previewing) { video in
      if let files = model.previewFiles {
        PreviewView(video: video, files: files)
      }
    }
    .contextMenu(forSelectionType: Video.ID.self) { ids in
      let videos = model.videos.filter { ids.contains($0.id) }
      let copies = videos.compactMap { model.copy(of: $0) }
      Button("Preview") {
        model.preview(ids)
      }
      Divider()
      Button(videos.count == 1 ? "Import" : "Import \(videos.count) Videos") {
        Task { await model.importVideos(videos) }
      }
      .disabled(model.isBusy)
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting(copies)
      }
      .disabled(copies.isEmpty)
      Divider()
      Button("Delete from iPhone…") {
        model.offerDelete(videos)
      }
      .disabled(copies.isEmpty || model.isBusy)
    } primaryAction: { ids in
      model.preview(ids)
    }
  }
}

struct Thumbnail: View {
  let image: NSImage?

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.quaternary)
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "film")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 64, height: 36)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

struct StatusCell: View {
  let state: VideoState
  @Environment(\.backgroundProminence) private var prominence

  /// Colored labels turn white on a selected row, like the rest of the row's text.
  private var isOnSelection: Bool { prominence == .increased }

  var body: some View {
    switch state {
    case .onPhone:
      Text("Only on iPhone")
        .foregroundStyle(.secondary)
    case .onMac:
      Label("On Mac", systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)
        .help("A file with the same name and size is in the import folder")
    case .waiting:
      Text("Waiting")
        .foregroundStyle(.secondary)
    case .copying(let fraction):
      HStack(spacing: 8) {
        ProgressView(value: fraction)
          .controlSize(.small)
        Text(fraction, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 36, alignment: .trailing)
      }
    case .checking:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
        Text("Checking")
          .foregroundStyle(.secondary)
      }
    case .imported:
      Label("Imported", systemImage: "checkmark.seal.fill")
        .foregroundStyle(isOnSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(.green))
        .help("Copied, and the copy matches the iPhone's file byte for byte")
    case .failed(let message):
      Label("Failed", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(isOnSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
        .help(message)
    case .deleting:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
        Text("Deleting from iPhone")
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct StatusBar: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.slowCable {
        Label {
          Text("Connected at USB 2 speed. A USB 3 cable, plugged straight into the Mac, can make imports much faster.")
        } icon: {
          Image(systemName: "cable.connector")
            .foregroundStyle(.orange)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help("This iPhone supports USB 3, up to 10 Gb/s. Its connection runs at USB 2 speed, up to 480 Mb/s, because of the cable, the port or a hub in between.")
      }
      content
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .top) { Divider() }
  }

  @ViewBuilder
  private var content: some View {
    HStack(spacing: 12) {
      if let batch = model.batch {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: batch.fraction)
          HStack {
            Text("Importing \(batch.current) (\(batch.index + 1) of \(batch.count))")
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Text(speed(batch))
              .monospacedDigit()
          }
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Button("Cancel") { model.cancelImport() }
      } else {
        Text(model.notice ?? summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
      }
    }
  }

  private var summary: String {
    let onMac = model.onMacCount
    let saved = onMac == model.videos.count ? "All on your Mac" : "\(onMac) of \(model.videos.count) on your Mac"
    return "\(saved), in \(model.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
  }

  private func speed(_ batch: Batch) -> String {
    guard let bytesPerSecond = batch.bytesPerSecond, let secondsLeft = batch.secondsLeft else { return "" }
    let rate = "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s"
    let left = Duration.seconds(max(secondsLeft, 1))
      .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
    return "\(rate) · about \(left) left"
  }
}

enum FolderPicker {
  @MainActor
  static func choose(for model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = model.destination
    panel.prompt = "Choose"
    panel.message = "Choose the folder to import the videos into."
    if panel.runModal() == .OK, let url = panel.url {
      model.setDestination(url)
    }
  }
}
