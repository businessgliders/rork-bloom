import Foundation
import Supabase

/// The one Supabase client. Every request is made as the signed-in user, so row level security applies.
enum Backend {
    static let url: URL = {
        let configured = Config.EXPO_PUBLIC_SUPABASE_URL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: configured.isEmpty ? "https://bksptqccoirbbfhvjfkh.supabase.co" : configured)!
    }()

    static let key: String = {
        let configured = Config.EXPO_PUBLIC_SUPABASE_ANON_KEY.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "sb_publishable_DA6IVQnAOw8SVSWSlzU9Eg_kKuMaA-s" : configured
    }()

    static let client = SupabaseClient(
        supabaseURL: url,
        supabaseKey: key,
        options: .init(auth: .init(emitLocalSessionAsInitialSession: true))
    )

    static let milestonePhotosBucket = "milestone-photos"
    static let medicationPhotosBucket = "medication-photos"

    /// True for failures that mean "try again later" rather than "the server said no".
    static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain
    }

    /// A short, human message for errors shown in the UI.
    static func message(for error: Error) -> String {
        if isNetworkError(error) { return "You seem to be offline. Try again when you're connected." }
        if let pg = error as? PostgrestError { return pg.message }
        if let auth = error as? AuthError { return auth.message }
        if let storage = error as? StorageError { return storage.message }
        if case FunctionsError.httpError(_, let data) = error,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["error"] as? String {
            return message
        }
        return error.localizedDescription
    }
}
