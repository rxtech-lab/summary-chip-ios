import Foundation
import Observation

/// Visible progress while the (synchronous, up to ~90 s) create call runs.
public enum GenerationStage: Int, CaseIterable, Sendable, Comparable {
    case uploading
    case reading
    case summarising
    case designing
    case finishing

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .uploading: "Uploading PDF"
        case .reading: "Reading the source"
        case .summarising: "Writing the summary"
        case .designing: "Designing the preview image"
        case .finishing: "Finishing up"
        }
    }

    public var systemImage: String {
        switch self {
        case .uploading: "arrow.up.doc"
        case .reading: "doc.text.magnifyingglass"
        case .summarising: "text.badge.star"
        case .designing: "paintpalette"
        case .finishing: "checkmark.seal"
        }
    }

    /// Seconds after upload at which the UI enters this stage (server gives no progress).
    public var estimatedSeconds: Double {
        switch self {
        case .uploading: 0
        case .reading: 0
        case .summarising: 4
        case .designing: 18
        case .finishing: 50
        }
    }
}

@MainActor
@Observable
public final class GenerationSession {
    public enum State: Equatable {
        case idle
        case generating(GenerationStage)
        case finished(Summary)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var stages: [GenerationStage] = []
    private var task: Task<Void, Never>?

    public init() {}

    public var summary: Summary? {
        if case .finished(let summary) = state { return summary }
        return nil
    }

    public var isGenerating: Bool {
        if case .generating = state { return true }
        return false
    }

    public func start(input: SummaryInput, options: GenerationOptions, api: SummaryAPIClient, onFinish: (@MainActor (Summary) -> Void)? = nil) {
        task?.cancel()
        let isPDF: Bool = if case .pdf = input { true } else { false }
        stages = isPDF ? GenerationStage.allCases : GenerationStage.allCases.filter { $0 != .uploading }
        state = .generating(stages[0])
        task = Task {
            let ticker = Task {
                await self.advanceStages(startingAfterUpload: !isPDF)
            }
            defer { ticker.cancel() }
            do {
                let summary = try await api.createSummary(from: input, options: options) {
                    Task { @MainActor in self.uploadFinished() }
                }
                guard !Task.isCancelled else { return }
                self.state = .finished(summary)
                onFinish?(summary)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as URLError where error.code == .cancelled {
                self.state = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    public func reset() { cancel() }

    private var uploadDone = false

    private func uploadFinished() {
        uploadDone = true
        if case .generating(.uploading) = state { state = .generating(.reading) }
    }

    private func advanceStages(startingAfterUpload: Bool) async {
        uploadDone = startingAfterUpload
        while !uploadDone {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        let start = Date()
        for stage in GenerationStage.allCases where stage > .reading {
            let waitUntil = stage.estimatedSeconds
            while Date().timeIntervalSince(start) < waitUntil {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard case .generating(let current) = state, current < stage else { continue }
            state = .generating(stage)
        }
    }
}
