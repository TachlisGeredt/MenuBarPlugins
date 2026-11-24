import Foundation

/// Token returned by `PluginScheduler` allowing callers to cancel a scheduled timer.
@objc public final class PluginTimerToken: NSObject {
    public let id: UUID
    private weak var scheduler: PluginScheduler?

    internal init(id: UUID, scheduler: PluginScheduler) {
        self.id = id
        self.scheduler = scheduler
    }

    @objc public func cancel() {
        scheduler?.cancel(id: id)
    }
}

/// Power-aware coalesced timer scheduler using `DispatchSourceTimer`.
/// Supports global pause/resume (e.g., when macOS sleeps or turns off the display).
public final class PluginScheduler {
    private struct Entry {
        let timer: DispatchSourceTimer
        var isSuspended: Bool
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var isPaused: Bool = false

    public init(label: String = "com.menubarplugins.scheduler") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        cancelAll()
    }

    /// Schedules a repeating timer with generous leeway so macOS coalesces CPU wakeups.
    /// The handler is always invoked on the main queue for safe AppKit updates.
    @discardableResult
    public func scheduleRepeating(
        interval: TimeInterval,
        leeway: TimeInterval? = nil,
        fireImmediately: Bool = false,
        handler: @escaping () -> Void
    ) -> PluginTimerToken {
        let clampedInterval = max(0.5, interval)
        let effectiveLeeway = max(0.1, leeway ?? (clampedInterval * 0.15))

        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        let startDeadline: DispatchTime = fireImmediately ? .now() : .now() + clampedInterval
        timer.schedule(
            deadline: startDeadline,
            repeating: clampedInterval,
            leeway: .milliseconds(Int(effectiveLeeway * 1000))
        )
        timer.setEventHandler {
            DispatchQueue.main.async(execute: handler)
        }

        let id = UUID()
        lock.lock()
        let shouldStartSuspended = isPaused
        entries[id] = Entry(timer: timer, isSuspended: shouldStartSuspended)
        if !shouldStartSuspended {
            timer.resume()
        }
        lock.unlock()

        return PluginTimerToken(id: id, scheduler: self)
    }

    public func cancel(id: UUID) {
        lock.lock()
        guard let entry = entries.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if entry.isSuspended {
            entry.timer.resume()
        }
        entry.timer.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let snapshot = entries
        entries.removeAll()
        lock.unlock()

        for (_, entry) in snapshot {
            if entry.isSuspended {
                entry.timer.resume()
            }
            entry.timer.cancel()
        }
    }

    /// Suspends all active timers (e.g., when the display turns off or the Mac sleeps).
    public func pauseAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused else { return }
        isPaused = true
        for (id, var entry) in entries {
            if !entry.isSuspended {
                entry.timer.suspend()
                entry.isSuspended = true
                entries[id] = entry
            }
        }
    }

    /// Resumes all previously suspended timers.
    public func resumeAll() {
        lock.lock()
        defer { lock.unlock() }
        guard isPaused else { return }
        isPaused = false
        for (id, var entry) in entries {
            if entry.isSuspended {
                entry.timer.resume()
                entry.isSuspended = false
                entries[id] = entry
            }
        }
    }

    public var activeTimerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var paused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }
}
