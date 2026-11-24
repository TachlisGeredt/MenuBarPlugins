import Foundation

/// Zero-polling kernel-level (`kqueue`) directory watcher for the `Plugins/` folder.
final class DirectoryWatcher {
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.menubarplugins.dirwatcher", qos: .utility)
    private var pendingDebounce: DispatchWorkItem?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(watching: url)
    }

    deinit {
        stop()
    }

    func restart(watching url: URL) {
        stop()
        start(watching: url)
    }

    private func start(watching url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            self?.scheduleDebouncedCallback()
        }

        src.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = src
        src.resume()
    }

    private func scheduleDebouncedCallback() {
        pendingDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.onChange()
            }
        }
        pendingDebounce = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func stop() {
        pendingDebounce?.cancel()
        pendingDebounce = nil
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
