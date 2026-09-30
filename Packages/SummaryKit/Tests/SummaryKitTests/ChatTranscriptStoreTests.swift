import Foundation
import Testing
@testable import SummaryKit

struct ChatTranscriptStoreTests {
    private struct Message: Codable, Equatable {
        var text: String
        var sentAt: Date
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ChatTranscriptStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func persistsEachChatSeparately() {
        let directory = makeDirectory()
        let store = ChatTranscriptStore(directory: directory)
        let library = [Message(text: "hi", sentAt: Date(timeIntervalSince1970: 1_800_000_000))]
        let summary = [Message(text: "explain", sentAt: Date(timeIntervalSince1970: 1_800_000_100))]
        store.save(library, key: ChatTranscriptStore.libraryKey)
        store.save(summary, key: ChatTranscriptStore.key(summaryID: "abc/1"))
        store.flush()

        let reopened = ChatTranscriptStore(directory: directory)
        #expect(reopened.load([Message].self, key: ChatTranscriptStore.libraryKey) == library)
        #expect(reopened.load([Message].self, key: ChatTranscriptStore.key(summaryID: "abc/1")) == summary)
        #expect(reopened.load([Message].self, key: ChatTranscriptStore.key(summaryID: "other")) == nil)
    }

    @Test func removeDeletesOnlyThatChat() {
        let directory = makeDirectory()
        let store = ChatTranscriptStore(directory: directory)
        let messages = [Message(text: "hi", sentAt: Date(timeIntervalSince1970: 1_800_000_000))]
        store.save(messages, key: ChatTranscriptStore.libraryKey)
        store.save(messages, key: ChatTranscriptStore.key(summaryID: "a"))
        store.remove(key: ChatTranscriptStore.libraryKey)
        store.flush()

        #expect(store.load([Message].self, key: ChatTranscriptStore.libraryKey) == nil)
        #expect(store.load([Message].self, key: ChatTranscriptStore.key(summaryID: "a")) == messages)
    }
}
