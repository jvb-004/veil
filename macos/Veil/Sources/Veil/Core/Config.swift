//  Bring your own keys. Nothing phones home, nothing is bundled.
//
//  Resolution order: environment, then ~/.config/veil/config.json. Keys never
//  touch the repo and never touch the overlay.

import Foundation

struct Config: Codable {
    var anthropicAPIKey: String?
    var deepgramAPIKey: String?
    var model: String = "claude-opus-5"
    var sttModel: String = "nova-3"
    var language: String = "en"
    /// Free-form context: your CV, the product docs, the brief. Read once at launch.
    var contextFilePath: String?
    var persona: String = "You are assisting the user during a live conversation."

    static let configURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/veil/config.json")

    static func load() -> Config {
        var config = Config()
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
        }
        let env = ProcessInfo.processInfo.environment
        if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { config.anthropicAPIKey = k }
        if let k = env["DEEPGRAM_API_KEY"], !k.isEmpty { config.deepgramAPIKey = k }
        if let m = env["VEIL_MODEL"], !m.isEmpty { config.model = m }
        return config
    }

    var userContext: String {
        guard let path = contextFilePath,
              let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath,
                                     encoding: .utf8)
        else { return "" }
        return String(text.prefix(20_000))
    }
}
