import AppKit

/// Automatically pauses plugin timers when macOS sleeps or turns off the display,
/// and resumes them upon wake. Uses zero polling.
final class PowerStateMonitor {
    private var observers: [NSObjectProtocol] = []

    init(onSuspend: @escaping () -> Void, onResume: @escaping () -> Void) {
        let nc = NSWorkspace.shared.notificationCenter

        let suspendNames: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        for name in suspendNames {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                onSuspend()
            }
            observers.append(token)
        }

        let resumeNames: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in resumeNames {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                onResume()
            }
            observers.append(token)
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for token in observers {
            nc.removeObserver(token)
        }
    }
}
