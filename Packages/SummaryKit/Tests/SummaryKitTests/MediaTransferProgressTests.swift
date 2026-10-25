import Testing
@testable import SummaryKit

struct MediaTransferProgressTests {
    @Test func missingLengthRemainsIndeterminate() {
        for total: Int64? in [nil, -1, 0] {
            let progress = MediaTransferProgress(completedBytes: 1_500_000, totalBytes: total)
            #expect(progress.fraction == nil)
            #expect(!progress.detail.contains("/"))
        }
    }

    @Test func reportsBytesAndBoundsFraction() {
        let progress = MediaTransferProgress(completedBytes: 5_000_000, totalBytes: 10_000_000)
        #expect(progress.fraction == 0.5)
        #expect(progress.detail.contains(" / "))
        #expect(progress.detail.hasSuffix(" MB"))
        #expect(MediaTransferProgress(completedBytes: 12, totalBytes: 10).fraction == 1)
        #expect(MediaTransferProgress(completedBytes: -2, totalBytes: 10).fraction == 0)
    }
}
