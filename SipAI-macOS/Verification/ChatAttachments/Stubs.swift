// Stand-ins for what APIClient.swift reaches for outside itself, so the
// REAL file can be compiled and its request bodies asserted without the
// config layer, the network, or the app.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product. Keep the
// shapes minimal — a stub that grows a second implementation of a rule
// is a harness that can pass while the app is broken.

import Foundation

struct ProviderConfig {
    var key: String
    var name: String
    var baseURL: String
    var apiStyle: String
    var apiKey: String?
    var envVar: String?
    var authHeader: String
    var authPrefix: String
}

struct ModelConfig {
    var id: String
    var name: String
    var providerKey: String
    var apiStyle: String?
}

struct BuiltinProvider {
    var name: String
    var baseURL: String
    var apiStyle: String
    var env: String
    var authHeader: String
    var authPrefix: String
}

final class ConfigManager {
    var models: [String: ModelConfig] = [:]
    var providers: [String: ProviderConfig] = [:]
    var keys: [String: String] = [:]

    static let builtInProviders: [String: BuiltinProvider] = [:]

    func model(for id: String) -> ModelConfig? { models[id] }
    func provider(for key: String) -> ProviderConfig? { providers[key] }
    func apiKey(for key: String) -> String? { keys[key] }
}

enum ProviderHTTP {
    static let session = URLSession.shared
}

enum SipaiPaths {
    /// Redirected to a throwaway directory: `UsageLog` writes on every
    /// reply, and the harness must never touch the real usage file.
    static var dataDir: URL {
        let base = ProcessInfo.processInfo.environment["SIPAI_TEST_DATA_DIR"]
            ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base, isDirectory: true)
    }
}

// The real ChatMessage lives in ChatManager.swift, which drags in the
// whole chat store. Only these fields reach a request body.
struct ChatMessage {
    var id = UUID()
    var role: String
    var content: String
    var model: String? = nil
    var time: Double? = nil
    var tokens: Int? = nil
    var files: String? = nil
}
