import Darwin
import Foundation

protocol ProcessWorkingDirectoryProviding: Sendable {
    func workingDirectory(for processID: pid_t) -> String?
}

struct MacOSProcessWorkingDirectoryProvider: ProcessWorkingDirectoryProviding {
    func workingDirectory(for processID: pid_t) -> String? {
        guard processID > 0 else { return nil }

        var pathInfo = proc_vnodepathinfo()
        let result = proc_pidinfo(
            processID,
            PROC_PIDVNODEPATHINFO,
            0,
            &pathInfo,
            Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        )
        guard result == MemoryLayout<proc_vnodepathinfo>.stride else { return nil }

        let path = withUnsafePointer(to: &pathInfo.pvi_cdir.vip_path.0) {
            String(cString: $0)
        }
        return path.isEmpty ? nil : path
    }
}

final class ProcessWorkingDirectoryPoller: @unchecked Sendable {
    typealias DirectoryChangedHandler = @Sendable (URL) -> Void

    private let processID: pid_t
    private let provider: any ProcessWorkingDirectoryProviding
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let onDirectoryChanged: DirectoryChangedHandler
    private var timer: DispatchSourceTimer?
    private var lastDirectory: URL?
    private var isStopped = false

    init(
        processID: pid_t,
        provider: any ProcessWorkingDirectoryProviding,
        interval: TimeInterval = 0.5,
        onDirectoryChanged: @escaping DirectoryChangedHandler
    ) {
        self.processID = processID
        self.provider = provider
        self.interval = max(interval, 0.1)
        queue = DispatchQueue(
            label: "com.gordonbeeming.myterm.terminal-working-directory",
            qos: .utility
        )
        self.onDirectoryChanged = onDirectoryChanged
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(initialDirectory: URL?) {
        performOnQueue {
            guard self.timer == nil, !self.isStopped else { return }

            self.lastDirectory = initialDirectory?.standardizedFileURL
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + self.interval,
                repeating: self.interval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func updateCurrentDirectory(_ directory: URL) {
        performOnQueue {
            self.lastDirectory = directory.standardizedFileURL
        }
    }

    func stop() {
        performOnQueue {
            guard !self.isStopped else { return }

            self.isStopped = true
            guard let timer = self.timer else { return }
            self.timer = nil
            timer.setEventHandler {}
            timer.cancel()
        }
    }

    deinit {
        stop()
    }

    private func poll() {
        guard let directory = provider.workingDirectory(for: processID),
              let normalizedDirectory = TerminalWorkingDirectoryNormalizer.normalize(directory)
        else {
            return
        }

        guard !isStopped, lastDirectory != normalizedDirectory else { return }

        lastDirectory = normalizedDirectory
        onDirectoryChanged(normalizedDirectory)
    }

    private func performOnQueue(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }
}
