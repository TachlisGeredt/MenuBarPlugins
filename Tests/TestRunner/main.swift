import Foundation
import MenuBarPluginKit

var passed = 0
var failed = 0

func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: expected \(b), got \(a). \(message)\n", stderr)
    }
}

// 1. Manifest decoding & validation
do {
    let json = """
    {
      "id": "com.test.demo",
      "name": "Demo Plugin",
      "version": "1.2.3",
      "executable": "libDemo.dylib",
      "author": "Tester",
      "activation": {
        "mode": "whenAppActive",
        "bundleIdentifiers": ["com.apple.Safari"]
      }
    }
    """
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("manifest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try Data(json.utf8).write(to: tempURL)
    let manifest = try PluginManifest.load(from: tempURL)
    assertEqual(manifest.id, "com.test.demo")
    assertEqual(manifest.name, "Demo Plugin")
    assertEqual(manifest.version, "1.2.3")
    assertEqual(manifest.executable, "libDemo.dylib")
    assertEqual(manifest.activation?.mode, .whenAppActive)
    assertEqual(manifest.activation?.bundleIdentifiers, ["com.apple.Safari"])
} catch {
    failed += 1
    fputs("FAIL: Manifest valid decode threw: \(error)\n", stderr)
}

// 2. Manifest rejects empty fields & path traversal
do {
    let emptyID = PluginManifest(id: "  ", name: "Name", version: "1.0", executable: "libX.dylib")
    do {
        try emptyID.validate()
        failed += 1
        fputs("FAIL: Expected emptyID.validate() to throw\n", stderr)
    } catch let err as PluginManifest.ValidationError {
        assertEqual(err, .emptyField("id"))
    } catch {
        failed += 1
        fputs("FAIL: Unexpected error: \(error)\n", stderr)
    }

    let traversal = PluginManifest(id: "com.test.bad", name: "Bad", version: "1.0", executable: "../evil.dylib")
    do {
        try traversal.validate()
        failed += 1
        fputs("FAIL: Expected traversal.validate() to throw\n", stderr)
    } catch let err as PluginManifest.ValidationError {
        assertEqual(err, .invalidExecutablePath("../evil.dylib"))
    } catch {
        failed += 1
        fputs("FAIL: Unexpected error: \(error)\n", stderr)
    }
}

// 3. Activation rules
do {
    assertTrue(ActivationRule.always.isSatisfied(runningBundleIDs: [], activeBundleID: nil), "always should match empty")

    let runningRule = ActivationRule(mode: .whenAppRunning, bundleIdentifiers: ["com.apple.Safari", "com.apple.Xcode"])
    assertTrue(!runningRule.isSatisfied(runningBundleIDs: ["com.apple.Finder"], activeBundleID: "com.apple.Finder"), "whenAppRunning false")
    assertTrue(runningRule.isSatisfied(runningBundleIDs: ["com.apple.Finder", "com.apple.Safari"], activeBundleID: "com.apple.Finder"), "whenAppRunning true")

    let activeRule = ActivationRule(mode: .whenAppActive, bundleIdentifiers: ["com.apple.Safari"])
    assertTrue(!activeRule.isSatisfied(runningBundleIDs: ["com.apple.Safari"], activeBundleID: "com.apple.Finder"), "whenAppActive false when background")
    assertTrue(activeRule.isSatisfied(runningBundleIDs: ["com.apple.Safari"], activeBundleID: "com.apple.Safari"), "whenAppActive true when frontmost")
    assertTrue(!activeRule.isSatisfied(runningBundleIDs: ["com.apple.Safari"], activeBundleID: nil), "whenAppActive false when nil")
}

// 4. Scheduler fire, pause, resume, cancel
do {
    let scheduler = PluginScheduler(label: "com.test.scheduler")
    var fired = false
    let token = scheduler.scheduleRepeating(interval: 0.5, leeway: 0.05, fireImmediately: true) {
        fired = true
    }
    assertEqual(scheduler.activeTimerCount, 1)

    let deadline = Date().addingTimeInterval(1.0)
    while !fired && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    assertTrue(fired, "Scheduler timer should fire")

    scheduler.pauseAll()
    assertTrue(scheduler.paused, "Scheduler should be paused")
    scheduler.resumeAll()
    assertTrue(!scheduler.paused, "Scheduler should be resumed")

    token.cancel()
    assertEqual(scheduler.activeTimerCount, 0)
}

print("Tests finished: \(passed) passed, \(failed) failed.")
exit(failed == 0 ? 0 : 1)
