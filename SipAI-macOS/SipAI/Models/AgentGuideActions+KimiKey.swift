import Foundation

/// The models a kimi key can start on, as kimi's own catalog lists them
/// for its provider (`kimi provider catalog list <id>`), for the sign-in
/// sheet to ask which one — as kimi's own key login asks. The list is
/// models.dev's, in an order that is no ranking, so no entry of it is
/// taken as the default.
enum KimiKeyModels: Equatable {
    case listed([String])
    case failed(String)
}

extension AgentGuideActions {
    /// One listing, read-only: nothing is written, and the key is not
    /// involved. kimi falls back to its own built-in copy of the catalog
    /// when models.dev cannot be reached, so a failure here is kimi's own
    /// (its words, when it said any).
    nonisolated func kimiKeyModels(providerId: String) async -> KimiKeyModels {
        guard let binary = AgentManager.binaryPath(for: "kimi") else {
            return .failed(Self.kimiModelsNotListed)
        }
        let listing = await AgentCLIProbe.run(
            binary: binary,
            arguments: ["provider", "catalog", "list", providerId],
            ceiling: 60,
            outputCap: AgentCLIProbe.outputTailCap,
            onSpawn: { _ in })
        let ids = KimiCatalogListing.modelIds(from: listing.output)
        guard listing.exitCode == 0, !ids.isEmpty else {
            let said = listing.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(said.isEmpty ? Self.kimiModelsNotListed : said)
        }
        return .listed(ids)
    }

    nonisolated private static var kimiModelsNotListed: String {
        String(localized: "This provider's models could not be listed.",
               comment: "Agent Guide: kimi's catalog listing of a key provider's models failed, on the sign-in sheet")
    }
}
