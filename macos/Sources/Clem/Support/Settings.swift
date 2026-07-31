import Foundation

final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var captureInterval: TimeInterval {
        didSet { d.set(captureInterval, forKey: "captureInterval") }
    }
    @Published var keepThumbnails: Bool {
        didSet { d.set(keepThumbnails, forKey: "keepThumbnails") }
    }
    @Published var thumbnailQuality: Double {
        didSet { d.set(thumbnailQuality, forKey: "thumbnailQuality") }
    }
    @Published var pauseOnLowBattery: Bool {
        didSet { d.set(pauseOnLowBattery, forKey: "pauseOnLowBattery") }
    }
    @Published var blockedApps: [String] {
        didSet { d.set(blockedApps, forKey: "blockedApps") }
    }
    @Published var blockedDomains: [String] {
        didSet { d.set(blockedDomains, forKey: "blockedDomains") }
    }

    @Published var supermemoryURL: String {
        didSet { d.set(supermemoryURL, forKey: "supermemoryURL") }
    }
    @Published var supermemoryKey: String {
        didSet {
            if supermemoryKey.isEmpty {
                Keychain.delete(account: "supermemoryKey")
            } else {
                Keychain.set(supermemoryKey, account: "supermemoryKey")
            }
            d.removeObject(forKey: "supermemoryKey")
        }
    }
    @Published var ollamaURL: String {
        didSet { d.set(ollamaURL, forKey: "ollamaURL") }
    }
    @Published var ollamaModel: String {
        didSet { d.set(ollamaModel, forKey: "ollamaModel") }
    }
    @Published var llmProvider: String {
        didSet { d.set(llmProvider, forKey: "llmProvider") }
    }
    @Published var cloudAPIKey: String {
        didSet {
            if cloudAPIKey.isEmpty {
                Keychain.delete(account: "cloudAPIKey")
            } else {
                Keychain.set(cloudAPIKey, account: "cloudAPIKey")
            }
            d.removeObject(forKey: "cloudAPIKey")
        }
    }
    @Published var cloudModel: String {
        didSet { d.set(cloudModel, forKey: "cloudModel") }
    }
    @Published var cloudBaseURL: String {
        didSet { d.set(cloudBaseURL, forKey: "cloudBaseURL") }
    }
    @Published var engineAutoStart: Bool {
        didSet { d.set(engineAutoStart, forKey: "engineAutoStart") }
    }
    @Published var engineBinary: String {
        didSet { d.set(engineBinary, forKey: "engineBinary") }
    }
    @Published var engineWorkdir: String {
        didSet { d.set(engineWorkdir, forKey: "engineWorkdir") }
    }
    @Published var containerTag: String {
        didSet { d.set(containerTag, forKey: "containerTag") }
    }
    @Published var thumbnailRetentionDays: Int {
        didSet { d.set(thumbnailRetentionDays, forKey: "thumbnailRetentionDays") }
    }
    @Published var autoStartMonitoring: Bool {
        didSet { d.set(autoStartMonitoring, forKey: "autoStartMonitoring") }
    }
    @Published var distractingLabels: [String] {
        didSet { d.set(distractingLabels, forKey: "distractingLabels") }
    }
    @Published var gazeCheckEnabled: Bool {
        didSet { d.set(gazeCheckEnabled, forKey: "gazeCheckEnabled") }
    }

    static let savedTag = "saved"

    var supermemoryURLValue: URL { URL(string: supermemoryURL) ?? URL(string: "http://localhost:6767")! }
    var ollamaURLValue: URL { URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")! }
    var cloudBaseURLValue: URL { URL(string: cloudBaseURL) ?? URL(string: "https://api.openai.com/v1")! }

    var llmProviderValue: LLMProvider { LLMProvider(rawValue: llmProvider) ?? .ollama }

    var llm: LLMClient {
        switch llmProviderValue {
        case .ollama:
            return .ollama(OllamaClient(baseURL: ollamaURLValue, model: ollamaModel))
        case .openai:
            return .openAI(OpenAIChatClient(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: cloudAPIKey, model: cloudModel))
        case .anthropic:
            return .anthropic(AnthropicClient(apiKey: cloudAPIKey, model: cloudModel))
        case .custom:
            return .openAI(OpenAIChatClient(baseURL: cloudBaseURLValue, apiKey: cloudAPIKey, model: cloudModel))
        }
    }

    /// Tags used when searching across the user's full memory surface.
    func allMemoryTags() -> [String] {
        Array(Set([Settings.savedTag, containerTag, ConnectorImport.tag]))
    }

    static let defaultBlockedApps = [
        "1password", "bitwarden", "keychain access", "com.apple.keychainaccess",
    ]
    static let defaultBlockedDomains = [
        "*.bank*", "accounts.google.com", "*.paypal.*", "signin", "checkout",
    ]

    static let defaultDistractingLabels = [
        "youtube.com", "x.com", "twitter.com", "instagram.com", "reddit.com",
        "facebook.com", "tiktok.com", "netflix.com", "twitch.tv", "primevideo.com",
        "linkedin.com", "news.ycombinator.com",
        "whatsapp", "telegram", "discord", "messages",
    ]

    init() {
        captureInterval = d.object(forKey: "captureInterval") as? TimeInterval ?? 5
        keepThumbnails = d.object(forKey: "keepThumbnails") as? Bool ?? true
        thumbnailQuality = d.object(forKey: "thumbnailQuality") as? Double ?? 0.4
        pauseOnLowBattery = d.object(forKey: "pauseOnLowBattery") as? Bool ?? true
        blockedApps = d.stringArray(forKey: "blockedApps") ?? Settings.defaultBlockedApps
        blockedDomains = d.stringArray(forKey: "blockedDomains") ?? Settings.defaultBlockedDomains
        supermemoryURL = d.string(forKey: "supermemoryURL") ?? "http://localhost:6767"
        ollamaURL = d.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = d.string(forKey: "ollamaModel") ?? "qwen3:8b"
        llmProvider = d.string(forKey: "llmProvider") ?? LLMProvider.ollama.rawValue
        cloudModel = d.string(forKey: "cloudModel") ?? ""
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? "https://api.openai.com/v1"
        engineAutoStart = d.object(forKey: "engineAutoStart") as? Bool ?? true
        engineBinary = d.string(forKey: "engineBinary") ?? "~/.local/bin/supermemory-server"
        engineWorkdir = d.string(forKey: "engineWorkdir") ?? ""
        let tag = d.string(forKey: "containerTag") ?? "clem"
        containerTag = (tag == "recall" || tag == "muze") ? "clem" : tag
        thumbnailRetentionDays = d.object(forKey: "thumbnailRetentionDays") as? Int ?? 30
        autoStartMonitoring = d.object(forKey: "autoStartMonitoring") as? Bool ?? false
        distractingLabels = d.stringArray(forKey: "distractingLabels") ?? Settings.defaultDistractingLabels
        gazeCheckEnabled = d.object(forKey: "gazeCheckEnabled") as? Bool ?? false

        // Secrets: Keychain first; migrate plaintext UserDefaults (didSet skips init).
        if let key = Keychain.get(account: "supermemoryKey") {
            supermemoryKey = key
        } else if let legacy = d.string(forKey: "supermemoryKey"), !legacy.isEmpty {
            supermemoryKey = legacy
            Keychain.set(legacy, account: "supermemoryKey")
            d.removeObject(forKey: "supermemoryKey")
        } else {
            supermemoryKey = ""
        }
        if let key = Keychain.get(account: "cloudAPIKey") {
            cloudAPIKey = key
        } else if let legacy = d.string(forKey: "cloudAPIKey"), !legacy.isEmpty {
            cloudAPIKey = legacy
            Keychain.set(legacy, account: "cloudAPIKey")
            d.removeObject(forKey: "cloudAPIKey")
        } else {
            cloudAPIKey = ""
        }
    }
}
