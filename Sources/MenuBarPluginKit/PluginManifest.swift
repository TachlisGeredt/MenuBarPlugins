import Foundation

/// Determines when a plugin should be active in the menu bar.
public enum ActivationMode: String, Codable, Equatable {
    /// Always active whenever enabled by the user.
    case always
    /// Active only while at least one of `bundleIdentifiers` is running.
    case whenAppRunning
    /// Active only while one of `bundleIdentifiers` is the frontmost (focused) app.
    case whenAppActive
}

/// Conditional activation rule for a plugin.
public struct ActivationRule: Codable, Equatable {
    public var mode: ActivationMode
    public var bundleIdentifiers: [String]

    public init(mode: ActivationMode = .always, bundleIdentifiers: [String] = []) {
        self.mode = mode
        self.bundleIdentifiers = bundleIdentifiers
    }

    public static let always = ActivationRule(mode: .always, bundleIdentifiers: [])

    /// Evaluates whether this activation rule is currently satisfied.
    public func isSatisfied(runningBundleIDs: Set<String>, activeBundleID: String?) -> Bool {
        switch mode {
        case .always:
            return true
        case .whenAppRunning:
            guard !bundleIdentifiers.isEmpty else { return false }
            return bundleIdentifiers.contains { runningBundleIDs.contains($0) }
        case .whenAppActive:
            guard let active = activeBundleID, !bundleIdentifiers.isEmpty else { return false }
            return bundleIdentifiers.contains(active)
        }
    }
}

/// Metadata stored in each `.mbplugin/manifest.json`.
public struct PluginManifest: Codable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let executable: String
    public let author: String?
    public let description: String?
    public let activation: ActivationRule?

    public init(
        id: String,
        name: String,
        version: String,
        executable: String,
        author: String? = nil,
        description: String? = nil,
        activation: ActivationRule? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.executable = executable
        self.author = author
        self.description = description
        self.activation = activation
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case emptyField(String)
        case invalidExecutablePath(String)

        public var errorDescription: String? {
            switch self {
            case .emptyField(let field):
                return "Manifest field '\(field)' must not be empty."
            case .invalidExecutablePath(let path):
                return "Manifest executable '\(path)' must be a simple filename inside the plugin bundle."
            }
        }
    }

    /// Validates required fields and prevents directory traversal in `executable`.
    public func validate() throws {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyField("id")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyField("name")
        }
        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyField("version")
        }
        if executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyField("executable")
        }
        if executable.contains("/") || executable.contains("..") {
            throw ValidationError.invalidExecutablePath(executable)
        }
    }

    /// Loads and validates a `manifest.json` from disk.
    public static func load(from url: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        return manifest
    }
}
