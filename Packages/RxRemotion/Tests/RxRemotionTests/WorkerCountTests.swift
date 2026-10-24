import Testing
@testable import RxRemotion

struct WorkerCountTests {
    private func workers(cores: Int, memoryGB: UInt64, width: Int = 1280, height: Int = 720,
                         frames: Int = 2999, explicit: Int? = nil) -> Int {
        RemotionRenderSettings(concurrency: explicit).workerCount(
            for: RemotionComposition(id: "Main", width: width, height: height, fps: 24, durationInFrames: frames),
            processorCount: cores, physicalMemory: memoryGB * 1024 * 1024 * 1024)
    }

    @Test func scalesWithCores() {
        #expect(workers(cores: 4, memoryGB: 32) == 2)
        #expect(workers(cores: 8, memoryGB: 32) == 4)
        #expect(workers(cores: 12, memoryGB: 32) == 6)
        #expect(workers(cores: 16, memoryGB: 32) == 8)
        #expect(workers(cores: 32, memoryGB: 64) == 8)
    }
    @Test func respectsMemoryResolutionAndFrameCount() {
        #expect(workers(cores: 16, memoryGB: 4) == 1)
        #expect(workers(cores: 16, memoryGB: 8) == 2)
        #expect(workers(cores: 16, memoryGB: 16) == 6)
        #expect(workers(cores: 16, memoryGB: 32, width: 3840, height: 2160) == 4)
        #expect(workers(cores: 16, memoryGB: 32, width: 7680, height: 4320) == 1)
        #expect(workers(cores: 16, memoryGB: 32, frames: 3) == 3)
        #expect(workers(cores: 1, memoryGB: 32) == 1)
    }
    @Test func preservesExplicitSelection() {
        #expect(workers(cores: 16, memoryGB: 32, explicit: 1) == 1)
        #expect(workers(cores: 4, memoryGB: 8, explicit: 8) == 8)
        #expect(workers(cores: 16, memoryGB: 32, frames: 2, explicit: 8) == 2)
    }
}
