import Foundation

/// Watches config.json so edits (the README's documented way to change
/// settings) apply live instead of requiring a restart or manual refresh.
/// Two complementary sources are needed:
///
/// - the file's own vnode catches in-place writes (TextEdit, scripts);
/// - the directory catches creates/renames (editors that save atomically),
///   which also replace the file's inode.
///
/// The file source is one-shot and re-opened after every event — otherwise a
/// save-by-rename would leave it watching a dead inode. The callback fires
/// on all of this churn; the model reloads only when the decoded file
/// differs from its in-memory config, which also makes the app's own saves
/// a no-op here.
final class ConfigWatcher {
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        watchFile()
        watchDirectory()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(Config.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }   // missing file: the directory source catches its creation
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.fileSource?.cancel()   // one-shot: re-armed by schedule()
            self?.fileSource = nil
            self?.schedule()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func watchDirectory() {
        let fd = open(Config.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func schedule() {
        // Editors emit a burst of events per save; collapse them.
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.watchFile()
            self?.onChange?()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}
