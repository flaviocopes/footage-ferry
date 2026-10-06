import SwiftUI

@main
struct ImporterApp: App {
  @State private var model = AppModel()
  private let arguments = CommandLine.arguments

  init() {
    if !arguments.contains("--demo") {
      AppUpdater.shared.start(repository: "flaviocopes/importer-for-blackmagic-cam")
    }
  }

  /// `--demo-video <path>` makes every demo clip a copy of that video, so previews play.
  private var demoVideo: URL? {
    arguments.firstIndex(of: "--demo-video").flatMap { index in
      arguments.indices.contains(index + 1) ? URL(filePath: arguments[index + 1]) : nil
    }
  }

  var body: some Scene {
    Window("Importer for Blackmagic Cam", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 820, minHeight: 440)
        .task { model.start(demo: arguments.contains("--demo"), demoVideo: demoVideo) }
    }
    .defaultSize(width: 1000, height: 640)
    .commands {
      ImporterCommands(model: model)
    }
  }
}

struct ImporterCommands: Commands {
  let model: AppModel

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") {
        AppUpdater.shared.checkForUpdates()
      }
    }
    CommandGroup(replacing: .newItem) {}
    CommandMenu("Videos") {
      Button("Preview") {
        model.preview(model.selection)
      }
      .keyboardShortcut("y")
      .disabled(model.selection.isEmpty)
      Divider()
      Button("Import Selected") {
        Task { await model.importVideos(model.selectedVideos) }
      }
      .keyboardShortcut("i")
      .disabled(model.selection.isEmpty || model.isBusy)
      Button("Import All") {
        Task { await model.importVideos(model.videos) }
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(model.videos.isEmpty || model.isBusy)
      Button("Cancel Import") {
        model.cancelImport()
      }
      .keyboardShortcut(".")
      .disabled(model.batch == nil)
      Divider()
      Button("Delete Selected from iPhone…") {
        model.offerDelete(model.selectedVideos)
      }
      .keyboardShortcut(.delete)
      .disabled(model.isBusy || !model.selectedVideos.contains { model.copy(of: $0) != nil })
      Divider()
      Button("Reload") {
        Task { await model.reload() }
      }
      .keyboardShortcut("r")
      .disabled(model.phase != .ready || model.isBusy)
      Button("Choose Import Folder…") {
        FolderPicker.choose(for: model)
      }
      .disabled(model.isBusy)
    }
  }
}
