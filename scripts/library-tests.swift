import Foundation

@main struct LibraryTests {
    @MainActor static func main() async throws {
        precondition(!Recall.usesConversationMemory("Why is the sky blue?"))
        precondition(Recall.usesConversationMemory("When did I screenshot my messages?"))
        precondition(Recall.usesConversationMemory("What did we discuss earlier?"))
        let prior = UserDefaults.standard.data(forKey: "conduit.libraries")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "conduit.libraries") }
            else { UserDefaults.standard.removeObject(forKey: "conduit.libraries") }
        }
        var library = Library(name: "Photo migration fixture")
        library.galleryAssetIDs = ["fixture-photo-a", "fixture-photo-b"]
        UserDefaults.standard.set(try JSONEncoder().encode([library]), forKey: "conduit.libraries")
        let store = LibraryStore()
        PhotoLibraryIndex.shared.fixtures = [
            "fixture-photo-a": .init(date: Date(timeIntervalSince1970: 1_700_000_000),
                text: "Rickie: bring your science notes tomorrow", labels: ["screenshot"]),
            "fixture-photo-b": .init(date: nil, text: "Rickie: the appointment is Monday", labels: ["text"])
        ]
        try await store.indexGallery(library)
        var documents = try await KnowledgeIndex.shared.documents(collection: library.collection)
        precondition(documents.count == 2)
        precondition(store.libraries.first?.galleryIndexVersion == 1)
        try await store.indexGallery(library)
        documents = try await KnowledgeIndex.shared.documents(collection: library.collection)
        precondition(documents.count == 2, "Migration retries must not duplicate passages")
        let unrelated = "fixture-other:" + UUID().uuidString
        for index in 0..<70 {
            try await KnowledgeIndex.shared.add(id: unrelated + "/\(index)", source: .library,
                collection: unrelated, title: "Unrelated photo", text: "Rickie")
        }
        let hits = try await KnowledgeIndex.shared.search("Rickie", sources: [.library], collections: [library.collection], limit: 4)
        precondition(Set(hits.map(\.documentID)).count == 2,
            "Unrelated photos must not crowd the selected library out before filtering")
        precondition(hits.allSatisfy { $0.collection == library.collection })
        await store.delete(library)
        try await KnowledgeIndex.shared.remove(collection: unrelated)
        print("Gallery migration, duplicate-free retries and scoped SQLite retrieval passed")
    }
}
