import AppKit

// Parse optional `--plugins-dir <path>` argument before starting AppKit.
func parsePluginsDirectoryArg() -> String? {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--plugins-dir"), idx + 1 < args.count {
        return args[idx + 1]
    }
    return nil
}

let app = NSApplication.shared
// Pure background menu bar agent: no Dock icon, no app switcher entry.
app.setActivationPolicy(.accessory)

let delegate = AppDelegate(cliPluginsDirectory: parsePluginsDirectoryArg())
app.delegate = delegate
app.run()
