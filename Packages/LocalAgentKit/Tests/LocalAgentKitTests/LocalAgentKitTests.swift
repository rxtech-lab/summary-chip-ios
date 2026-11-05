import Foundation
import Testing
@testable import LocalAgentKit

private func line(_ text: String) -> Data { Data(text.utf8) }
private let launch = LocalAgentLaunch(kind: .claudeCode, mcpURL: URL(string: "https://example.com/api/mcp")!,
                                      mcpToken: "secret-token", instructions: "Be brief.")

@Suite struct EngineTests {
    @Test func savedPickIsRestoredAndUnknownFallsBackToCloud() {
        #expect(LiveVoiceEngine(saved: "codex") == .codex)
        #expect(LiveVoiceEngine(saved: "claudeCode").localAgent == .claudeCode)
        #expect(LiveVoiceEngine(saved: "gone") == .chippy)
        #expect(LiveVoiceEngine(saved: nil).localAgent == nil)
    }

    @Test func languageResolution() {
        #expect(LocalVoiceLanguage.resolve(saved: "fr-FR", preferred: ["en-US"]).kokoroVoice == "ff_siwis")
        #expect(LocalVoiceLanguage.resolve(saved: nil, preferred: ["zh-Hans-US"]).localeIdentifier == "zh-CN")
        #expect(LocalVoiceLanguage.resolve(saved: nil, preferred: ["en-AU"]).localeIdentifier == "en-US")
        #expect(LocalVoiceLanguage.resolve(saved: nil, preferred: ["zh-Hant-HK", "fr-CA"]).localeIdentifier == "fr-FR")
        #expect(LocalVoiceLanguage.resolve(saved: nil, preferred: ["ko-KR"]).localeIdentifier == "en-US")
    }
}

@Suite struct CommandTests {
    @Test func tokenStaysOutOfArgumentsForBothAgents() {
        for kind in LocalAgentKind.allCases {
            var request = launch
            request.kind = kind
            let arguments = LocalAgentCommand.arguments(for: request)
            #expect(!arguments.joined(separator: " ").contains("secret-token"))
            #expect(LocalAgentCommand.environment(for: request)[LocalAgentCommand.tokenEnvironmentKey] == "secret-token")
        }
    }

    @Test func claudeDoesNotBypassPermissions() {
        let arguments = LocalAgentCommand.arguments(for: launch)
        #expect(arguments.contains("--permission-mode"))
        #expect(arguments[arguments.firstIndex(of: "--permission-mode")! + 1] == "default")
        let allowed = arguments[arguments.firstIndex(of: "--allowedTools")! + 1]
        #expect(!allowed.contains("Bash") && !allowed.contains("Edit") && !allowed.contains("Write"))
        #expect(!arguments.contains("--resume"))
    }

    @Test func claudeResumes() {
        var request = launch
        request.resumeSessionID = "abc"
        let arguments = LocalAgentCommand.arguments(for: request)
        #expect(arguments[arguments.firstIndex(of: "--resume")! + 1] == "abc")
    }

    @Test func codexConfiguresOnlyChippyApproval() {
        var request = launch
        request.kind = .codex
        let arguments = LocalAgentCommand.arguments(for: request)
        #expect(arguments.contains("mcp_servers.chippy_app.url=\"https://example.com/api/mcp\""))
        #expect(arguments.contains("mcp_servers.chippy_app.default_tools_approval_mode=\"approve\""))
        let thread = CodexRPC.threadStartParams(cwd: "/tmp", instructions: "x")
        #expect(thread["approvalPolicy"] as? String == "never")
        #expect(thread["sandbox"] as? String == "read-only")
    }

    @Test func chosenModelReachesClaudeOnlyWhenItCantReadAsAnOption() {
        var request = launch
        #expect(!LocalAgentCommand.arguments(for: request).contains("--model"))
        request.model = "claude-fable-5-1[1m]"
        let arguments = LocalAgentCommand.arguments(for: request)
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "claude-fable-5-1[1m]")
        for bad in ["--dangerously-skip-permissions", "", "a b", "a\nb"] {
            request.model = bad
            #expect(!LocalAgentCommand.arguments(for: request).contains("--model"), "\(bad)")
        }
    }

    @Test func codexTakesTheChosenModelWithTheTurnNotTheCommandLine() {
        var request = launch
        request.kind = .codex
        request.model = "gpt-6-luna"
        #expect(!LocalAgentCommand.arguments(for: request).joined().contains("gpt-6-luna"))
        #expect(CodexRPC.turnStartParams(threadID: "t", text: "hi", model: request.model)["model"] as? String == "gpt-6-luna")
    }

    @Test func runtimeVersionIsPinned() {
        #expect(LocalVoiceManifest.requirements.contains("mlx-audio==0.6.3"))
    }

}

@Suite struct ClaudeParserTests {
    @Test func fullTurn() {
        var parser = ClaudeStreamParser()
        #expect(parser.parse(line(#"{"type":"system","subtype":"init","session_id":"s1"}"#)) == [.sessionStarted("s1")])
        #expect(parser.parse(line(#"{"type":"system","subtype":"hook_started"}"#)) == [])
        #expect(parser.parse(line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#)) == [.textDelta("Hi")])
        #expect(parser.parse(line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}}"#)) == [])
        let tool = parser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__chippy_app__search_summaries","input":{"query":"a"}}]}}"#))
        guard case .toolStarted(let id, let name, let input)? = tool.first else { Issue.record("no tool"); return }
        #expect(id == "t1" && name == "search_summaries")
        #expect(String(decoding: input, as: UTF8.self).contains("query"))
        #expect(parser.parse(line(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"done"}]}]}}"#)) == [.toolFinished(id: "t1", output: "done", isError: false)])
        #expect(parser.parse(line(#"{"type":"stream_event","event":{"type":"message_stop"}}"#)) == [.textEnded])
        #expect(parser.parse(line(#"{"type":"result","subtype":"success","is_error":false}"#)) == [.turnFinished])
    }

    @Test func unreachableLibraryIsAFailureNotASilentGap() {
        var parser = ClaudeStreamParser()
        let failed = parser.parse(line(#"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"other","status":"failed"},{"name":"chippy_app","status":"failed"}]}"#))
        #expect(failed == [.sessionStarted("s"), .failed(libraryUnavailableMessage)])
        let fine = parser.parse(line(#"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"other","status":"failed"},{"name":"chippy_app","status":"connected"}]}"#))
        #expect(fine == [.sessionStarted("s")])
    }

    @Test func hidesToolSearchAndDeduplicatesRepeatedMessages() {
        var parser = ClaudeStreamParser()
        #expect(parser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"h","name":"ToolSearch","input":{}}]}}"#)) == [])
        #expect(parser.parse(line(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"h","content":"x"}]}}"#)) == [])
        let use = line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{}}]}}"#)
        #expect(parser.parse(use).count == 1)
        #expect(parser.parse(use).isEmpty)
    }

    @Test func reportsErrorsAndIgnoresNoise() {
        var parser = ClaudeStreamParser()
        #expect(parser.parse(line(#"{"type":"result","is_error":true,"result":"Not logged in"}"#)) == [.failed("Not logged in")])
        #expect(parser.parse(line("not json")) == [])
        #expect(parser.parse(line(#"{"type":"user","message":{"content":"plain"}}"#)) == [])
    }
}

@Suite struct CodexParserTests {
    var rpc = CodexRPC()

    @Test mutating func messageThatArrivesWholeIsStillHeard() {
        #expect(rpc.parse(line(#"{"method":"item/completed","params":{"item":{"id":"w","type":"agentMessage","text":"All done."}}}"#)) == .events([.textDelta("All done."), .textEnded]))
        #expect(rpc.parse(line(#"{"method":"item/agentMessage/delta","params":{"itemId":"s","delta":"Hi"}}"#)) == .events([.textDelta("Hi")]))
        #expect(rpc.parse(line(#"{"method":"item/completed","params":{"item":{"id":"s","type":"agentMessage","text":"Hi"}}}"#)) == .events([.textEnded]))
    }

    @Test mutating func toolAndTextFlow() {
        #expect(rpc.parse(line(#"{"method":"turn/started","params":{"turn":{"id":"u1"}}}"#)) == .turnStarted("u1"))
        #expect(rpc.parse(line(#"{"method":"item/agentMessage/delta","params":{"itemId":"m","delta":"Hi"}}"#)) == .events([.textDelta("Hi")]))
        #expect(rpc.parse(line(#"{"method":"item/completed","params":{"item":{"id":"m","type":"agentMessage","text":"Hi"}}}"#)) == .events([.textEnded]))
        guard case .events(let started)? = rpc.parse(line(#"{"method":"item/started","params":{"item":{"id":"c","type":"mcpToolCall","tool":"list_things","arguments":{"a":1}}}}"#)),
              case .toolStarted(let id, let name, _)? = started.first else { Issue.record("no tool"); return }
        #expect(id == "c" && name == "list_things")
        #expect(rpc.parse(line(#"{"method":"item/completed","params":{"item":{"id":"c","type":"mcpToolCall","status":"completed","error":null,"result":{"content":[{"type":"text","text":"ok"}]}}}}"#)) == .events([.toolFinished(id: "c", output: "ok", isError: false)]))
        #expect(rpc.parse(line(#"{"method":"item/completed","params":{"item":{"id":"c","type":"mcpToolCall","status":"failed","error":{"message":"nope"}}}}"#)) == .events([.toolFinished(id: "c", output: "nope", isError: true)]))
        #expect(rpc.parse(line(#"{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}"#)) == .events([.turnFinished]))
    }

    @Test mutating func extractsNestedProviderErrorAndRecognizesUnsupportedModel() {
        let raw = #"{"method":"turn/completed","params":{"turn":{"status":"failed","error":{"message":"{\"error\":{\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\",\"code\":\"model_not_found\"}}"}}}}"#
        guard case .events(let events)? = rpc.parse(line(raw)), case .failed(let message)? = events.first else { Issue.record("no failure"); return }
        #expect(message.hasPrefix("The 'x' model"))
        #expect(CodexRPC.isUnsupportedModel(message))
        #expect(!CodexRPC.isUnsupportedModel("Rate limit reached"))
    }

    @Test mutating func tracksOnlyTheChippyServerStartup() {
        #expect(rpc.parse(line(#"{"method":"mcpServer/startupStatus/updated","params":{"name":"chippy_app","status":"ready"}}"#)) == .libraryReady(true))
        #expect(rpc.parse(line(#"{"method":"mcpServer/startupStatus/updated","params":{"name":"chippy_app","status":"failed"}}"#)) == .libraryReady(false))
        #expect(rpc.parse(line(#"{"method":"mcpServer/startupStatus/updated","params":{"name":"chippy_app","status":"starting"}}"#)) == nil)
        #expect(rpc.parse(line(#"{"method":"mcpServer/startupStatus/updated","params":{"name":"other","status":"failed"}}"#)) == nil)
    }

    @Test func modelListAndThreadStartResults() {
        let list = line(#"{"data":[{"id":"hidden","isDefault":true,"hidden":true},{"id":"a","isDefault":false},{"id":"b","isDefault":true}]}"#)
        #expect(CodexRPC.defaultModel(fromModelList: list) == "b")
        #expect(CodexRPC.threadID(fromThreadStart: line(#"{"thread":{"id":"t"}}"#)) == "t")
    }

    @Test mutating func serverRequestsAreSurfacedSoTheyCanBeRejected() {
        guard case .serverRequest(let id, let method)? = rpc.parse(line(#"{"id":"r1","method":"item/commandExecution/requestApproval","params":{}}"#)) else { Issue.record("no request"); return }
        #expect(method == "item/commandExecution/requestApproval")
        let reply = String(decoding: CodexRPC.rejectRequest(id: id), as: UTF8.self)
        #expect(reply.contains("r1") && reply.contains("error") && reply.hasSuffix("\n"))
    }

    @Test mutating func responses() {
        #expect(rpc.parse(line(#"{"id":7,"error":{"message":"bad"}}"#)) == .responseError(id: 7, message: "bad"))
        guard case .response(let id, _)? = rpc.parse(line(#"{"id":2,"result":{"thread":{"id":"t"}}}"#)) else { Issue.record("no response"); return }
        #expect(id == 2)
    }
}

@Suite struct ChunkerTests {
    @Test func splitsAcrossDeltasAndKeepsDecimalsAndDomainsWhole() {
        var chunker = SpokenTextChunker()
        #expect(chunker.append("The price is 3.5 dollars at exam") == [])
        #expect(chunker.append("ple.com today. And") == ["The price is 3.5 dollars at example.com today."])
        #expect(chunker.flush() == ["And"])
        #expect(chunker.flush() == [])
    }

    @Test func handlesChinesePunctuationWithoutSpaces() {
        var chunker = SpokenTextChunker()
        #expect(chunker.append("你好，我找到了三条摘要。第二句") == ["你好，我找到了三条摘要。"])
    }

    @Test func stripsMarkdownUrlsAndSkipsCode() {
        var chunker = SpokenTextChunker()
        let output = chunker.append("## Results\n- **Bold** [link](https://a.b) item\nsee https://x.y/z now\n```swift\nlet a = 1\n```\nDone now\n")
        #expect(output == ["Results", "Bold link item", "see  now", "Done now"])
    }

    @Test func doesNotSpeakPunctuationOnly() {
        var chunker = SpokenTextChunker()
        #expect(chunker.append("---\n***\n").isEmpty)
    }
}

@Suite struct UtteranceDetectorTests {
    /// Runs loudness values through in 100 ms steps, returning the events.
    private func run(_ detector: inout UtteranceDetector, _ rms: Double, seconds: Double) -> [UtteranceDetector.Event] {
        (0..<Int(seconds * 10)).compactMap { _ in detector.process(rms: rms, duration: 0.1) }
    }

    @Test func speechThenQuietEndsAnUtteranceOnce() {
        var detector = UtteranceDetector(silence: 1)
        #expect(run(&detector, 0.001, seconds: 1).isEmpty)
        #expect(run(&detector, 0.05, seconds: 2).isEmpty)
        #expect(run(&detector, 0.001, seconds: 0.5).isEmpty)
        #expect(run(&detector, 0.001, seconds: 1) == [.utteranceEnded])
        #expect(run(&detector, 0.001, seconds: 2).isEmpty)
    }

    @Test func pausesBetweenWordsDoNotEndIt() {
        var detector = UtteranceDetector(silence: 1)
        for _ in 0..<4 {
            #expect(run(&detector, 0.05, seconds: 0.5).isEmpty)
            #expect(run(&detector, 0.001, seconds: 0.5).isEmpty)
        }
    }

    @Test func aClickIsNotSpeech() {
        var detector = UtteranceDetector(silence: 1)
        _ = run(&detector, 0.001, seconds: 1)
        #expect(detector.process(rms: 0.2, duration: 0.1) == nil)
        #expect(run(&detector, 0.001, seconds: 3).isEmpty)
    }

    @Test func aNoisyRoomRaisesTheBar() {
        var detector = UtteranceDetector(silence: 1, idleLimit: 100)
        #expect(run(&detector, 0.02, seconds: 5).isEmpty)
        // Steady fan noise never counted as speech, so there's nothing to end.
        #expect(run(&detector, 0.02, seconds: 5).isEmpty)
        #expect(run(&detector, 0.2, seconds: 1).isEmpty)
        #expect(run(&detector, 0.02, seconds: 1.1) == [.utteranceEnded])
    }

    @Test func mutedCaptureCountsAsQuietButLeavesTheNoiseFloorAlone() {
        var detector = UtteranceDetector(silence: 1)
        _ = run(&detector, 0.02, seconds: 2)
        _ = run(&detector, 0, seconds: 5)
        // 0.03 stays under three times the room's 0.02, even after all those zeros.
        #expect(run(&detector, 0.03, seconds: 2).isEmpty)
        #expect(run(&detector, 0, seconds: 2).isEmpty)
    }

    @Test func endlessSpeechIsCappedAndLongSilenceReportsIdle() {
        var detector = UtteranceDetector(silence: 1, maximumUtterance: 5, idleLimit: 3)
        #expect(run(&detector, 0.001, seconds: 3.1) == [.idle])
        // Loud enough to stay above the noise floor as it slowly rises.
        #expect(run(&detector, 0.5, seconds: 5.5) == [.utteranceEnded])
    }

    @Test func rmsOfSamples() {
        #expect(UtteranceDetector.rms(pcm16: Data()) == 0)
        #expect(UtteranceDetector.rms(pcm16: Data(count: 8)) == 0)
        let full = withUnsafeBytes(of: Int16(-32768).littleEndian) { Data($0) }
        #expect(UtteranceDetector.rms(pcm16: full + full) == 1)
    }
}

@Suite struct ToolOutputTests {
    private func decoded(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // These are the exact shapes server/lib/graph/mcp.ts returns.
    @Test func selectionBecomesWhatTheOpenGraphApplies() {
        let raw = #"{"selection":{"mode":"highlight","nodeIds":["a","b"],"edgeIds":[],"query":null}}"#
        let output = decoded(LocalToolOutput.chatOutput(toolName: "selectGraphElements", output: raw))
        let selection = output["graphSelection"] as? [String: Any]
        #expect(selection?["mode"] as? String == "highlight")
        #expect(selection?["nodeIds"] as? [String] == ["a", "b"])
    }

    @Test func clearingKeepsItsNullBehindTheLeadingSentence() {
        let raw = "Cleared the selection.\n{\"selection\":null}"
        let output = decoded(LocalToolOutput.chatOutput(toolName: "selectGraphElements", output: raw))
        #expect(output["graphSelection"] is NSNull)
    }

    @Test func otherToolsAndPlainTextPassThrough() {
        #expect(decoded(LocalToolOutput.chatOutput(toolName: "getGraph", output: #"{"selection":1}"#))["graphSelection"] == nil)
        #expect(decoded(LocalToolOutput.chatOutput(toolName: "Read", output: "a {b\nc"))["text"] as? String == "a {b\nc")
    }

    @Test func toolNames() {
        #expect(LocalToolOutput.chatToolName("select_graph_elements") == "selectGraphElements")
        #expect(LocalToolOutput.chatToolName("Read") == "Read")
    }

    @Test func documentChanges() {
        for name in ["update_graph", "update_trip", "update_place", "add_to_trip_from_source", "choose_plan_option", "restore_version"] {
            #expect(LocalToolOutput.changesOpenDocument(toolName: LocalToolOutput.chatToolName(name)), "\(name)")
        }
        for name in ["get_graph", "query_graph", "search_summaries", "select_graph_elements"] {
            #expect(!LocalToolOutput.changesOpenDocument(toolName: LocalToolOutput.chatToolName(name)), "\(name)")
        }
    }

    @Test mutating func codexReportsAToolErrorEvenWhenTheCallCompleted() {
        var rpc = CodexRPC()
        #expect(rpc.parse(line(#"{"method":"item/completed","params":{"item":{"id":"c","type":"mcpToolCall","status":"completed","error":null,"result":{"isError":true,"content":[{"type":"text","text":"Graph not found"}]}}}}"#)) == .events([.toolFinished(id: "c", output: "Graph not found", isError: true)]))
    }
}

@Suite struct SpeechWorkerTests {
    @Test func parsesProtocol() {
        #expect(SpeechWorkerEvent(line: line(#"{"type":"ready"}"#)) == .ready)
        #expect(SpeechWorkerEvent(line: line(#"{"type":"audio","id":"a","pcm":"AAE=","sampleRate":24000}"#)) == .audio(id: "a", pcm: Data([0, 1])))
        #expect(SpeechWorkerEvent(line: line(#"{"type":"done","id":"a"}"#)) == .done(id: "a"))
        #expect(SpeechWorkerEvent(line: line(#"{"type":"fatal","message":"x"}"#)) == .fatal("x"))
        #expect(SpeechWorkerEvent(line: line("noise")) == nil)
    }
}

@Suite struct VoiceModelTests {
    @Test func newInstallHasNoPredeterminedModels() {
        let status = LocalAgentRunnerStatus(agents: [], hasUV: true, voiceReady: false, isAppleSilicon: true)
        #expect(status.voiceModels.isEmpty)
        #expect(status.selectedVoiceModel.isEmpty)
    }
    @Test func selectedAndDownloadedModelsRoundTripIndependently() throws {
        var status = LocalAgentRunnerStatus(agents: [], hasUV: true, voiceReady: false, isAppleSilicon: true)
        status.selectedVoiceModel = "author/chosen-model"
        status.downloadedVoiceModels = ["another/downloaded-model"]
        status.storedVoiceModels = ["author/chosen-model", "another/downloaded-model"]
        let decoded = try JSONDecoder().decode(LocalAgentRunnerStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
        #expect(!decoded.downloadedVoiceModels.contains(decoded.selectedVoiceModel))
    }
}

@Suite struct VoiceHubTests {
    @Test func rejectsRepositoryAndDownloadPathTraversal() {
        for value in ["../model", "owner/..", "owner/model/extra", "owner/model?token=x", "https://example.com/model"] {
            #expect(!VoiceModelHub.validRepository(value))
        }
        #expect(VoiceModelHub.validRepository("mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit"))
        for value in ["../config.json", "/config.json", "voices/../../secret", "voices\\secret", "voices//file"] {
            #expect(!VoiceModelHub.safeFile(value))
        }
        #expect(VoiceModelHub.safeFile("speech_tokenizer/config.json"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHIPPY_TEST_HUB"] == "1"))
    func liveSearchReadmeAndModelSizes() async throws {
        let page = try await VoiceModelHub.search("Kokoro")
        #expect(!page.models.isEmpty)
        let kokoro = try await VoiceModelHub.resolve("mlx-community/Kokoro-82M-bf16", revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c")
        #expect(kokoro.id == "mlx-community/Kokoro-82M-bf16")
        #expect((kokoro.sizeBytes ?? 0) > 100_000_000)
        #expect(kokoro.files.contains("config.json"))
        #expect(kokoro.files.contains("voices/af_heart.safetensors"))
        let readme = try await VoiceModelHub.readme(kokoro.repository, revision: kokoro.revision)
        #expect(!readme.isEmpty)
        let qwen = try await VoiceModelHub.resolve("mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit")
        #expect(qwen.family == "qwen3_tts")
        #expect((qwen.sizeBytes ?? 0) > 100_000_000)
        #expect(qwen.files.contains("speech_tokenizer/config.json"))
        let base = try await VoiceModelHub.resolve("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit")
        #expect(base.files.contains("config.json"))
        #expect((base.sizeBytes ?? 0) > 0)
        let other = try await VoiceModelHub.resolve("mlx-community/chatterbox-turbo-4bit")
        #expect(other.files.contains { $0.hasSuffix(".safetensors") })
        print("Hugging Face verified: Kokoro \(kokoro.sizeBytes ?? 0) bytes, Qwen3 \(qwen.sizeBytes ?? 0) bytes")
    }
}

@Suite struct VoiceCatalogTests {
    @Test func presetsComeFromVoiceFilesAndSpeakerIDs() {
        let files = ["config.json", "voices/af_heart.safetensors", "voices/zf_xiaobei.safetensors", "kokoro.safetensors"]
        #expect(VoiceCatalog.presetVoices(files: files, config: [:]) == ["af_heart", "zf_xiaobei"])
        let config: [String: Any] = ["talker_config": ["spk_id": ["vivian": 1, "ryan": 2]]]
        #expect(VoiceCatalog.presetVoices(files: ["model.safetensors"], config: config) == ["ryan", "vivian"])
        #expect(VoiceCatalog.presetVoices(files: ["model.safetensors"], config: [:]).isEmpty)
    }

    @Test func excerptKeepsVoiceLinesAndIsEmptyWithoutThem() {
        let readme = (0..<50).map { "filler \($0)" }.joined(separator: "\n") + "\n## Voices\n- Serena\n- Ryan\n"
        let excerpt = VoiceCatalog.readmeExcerpt(readme)
        #expect(excerpt.contains("Serena"))
        #expect(!excerpt.contains("filler 10"))
        #expect(VoiceCatalog.readmeExcerpt("Nothing relevant here.").isEmpty)
        #expect(VoiceCatalog.readmeExcerpt("voice\n" + String(repeating: "x", count: 9000), limit: 100).count == 100)
    }

    @Test func onlyNamesInTheReadmeSurvive() {
        let readme = "Voices: `Serena`, Ryan and uncle_fu."
        let names = VoiceCatalog.grounded(["`Serena`", "ryan", "RYAN", "uncle_fu", "Invented", "rm -rf /", ""], in: readme)
        #expect(names == ["Serena", "ryan", "uncle_fu"])
    }

    @Test func speakLineCarriesTheChosenVoiceOnlyWhenThereIsOne() throws {
        let language = LocalVoiceLanguage.resolve(saved: "fr-FR", preferred: ["en-US"])
        let chosen = try JSONSerialization.jsonObject(with: SpeechWorkerEvent.speakLine(id: "1", text: "a", language: language, voice: "ryan")) as? [String: String]
        #expect(chosen?["voice"] == "ryan")
        #expect(chosen?["defaultVoice"] == "ff_siwis")
        let unset = try JSONSerialization.jsonObject(with: SpeechWorkerEvent.speakLine(id: "1", text: "a", language: language)) as? [String: String]
        #expect(unset?["voice"] == nil)
    }

    @Test func speakLineCarriesTheSeedOnlyWhenGiven() throws {
        let language = LocalVoiceLanguage.all[0]
        let seeded = try JSONSerialization.jsonObject(with: SpeechWorkerEvent.speakLine(id: "1", text: "a", language: language, seed: 42)) as? [String: Any]
        #expect(seeded?["seed"] as? Int == 42)
        let unset = try JSONSerialization.jsonObject(with: SpeechWorkerEvent.speakLine(id: "1", text: "a", language: language)) as? [String: Any]
        #expect(unset?["seed"] == nil)
    }

    @Test func everyLanguageHasItsOwnSample() {
        #expect(Set(LocalVoiceLanguage.all.map(\.sampleText)).count == Set(LocalVoiceLanguage.all.map { $0.localeIdentifier.prefix(2) }).count)
    }
}
