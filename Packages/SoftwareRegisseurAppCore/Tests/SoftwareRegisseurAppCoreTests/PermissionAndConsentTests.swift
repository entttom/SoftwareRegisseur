import Foundation
import Testing
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain

@Suite("Permission flow (Q4) and upload consent (H2)")
@MainActor
struct PermissionAndConsentTests {
    @Test func explanationOffersOnlyWeiterAndTriggersPromptImmediately() async {
        let authorizer = FakeAuthorizer(statuses: [:], answers: [.microphone: .granted, .speechRecognition: .granted])
        let flow = PermissionFlow(required: [.microphone, .speechRecognition], authorizer: authorizer)

        flow.begin()
        #expect(flow.step == .explaining(.microphone))
        #expect(flow.availableActions == [.continueToSystemPrompt])
        #expect(authorizer.requests.isEmpty)

        // Closing or skipping is impossible on the explanation screen.
        flow.close()
        #expect(flow.step == .explaining(.microphone))

        await flow.continueTapped()
        #expect(authorizer.requests == [.microphone])
        #expect(flow.step == .explaining(.speechRecognition))

        await flow.continueTapped()
        #expect(authorizer.requests == [.microphone, .speechRecognition])
        #expect(flow.step == .granted)
        #expect(flow.systemPromptCount == 2)
    }

    @Test func denialShowsSettingsLinkAndNeverAsksAgain() async {
        let authorizer = FakeAuthorizer(statuses: [:], answers: [.microphone: .denied])
        let flow = PermissionFlow(required: [.microphone], authorizer: authorizer)
        flow.begin()
        await flow.continueTapped()
        #expect(flow.step == .denied(.microphone))
        #expect(flow.availableActions == [.openSettings, .close])

        // Next attempt: straight to the denied screen, no second system prompt.
        flow.close()
        #expect(flow.step == .idle)
        flow.begin()
        #expect(flow.step == .denied(.microphone))
        await flow.continueTapped()
        #expect(authorizer.requests == [.microphone])
    }

    @Test func alreadyGrantedSkipsExplanationAndRestrictedIsDenied() {
        let granted = PermissionFlow(required: [.microphone], authorizer: FakeAuthorizer(statuses: [.microphone: .granted]))
        granted.begin()
        #expect(granted.step == .granted)

        let restricted = PermissionFlow(required: [.microphone, .speechRecognition],
                                        authorizer: FakeAuthorizer(statuses: [.microphone: .granted, .speechRecognition: .restricted]))
        restricted.begin()
        #expect(restricted.step == .denied(.speechRecognition))
    }

    @Test func methodsRequireTheRightPermissionsAndConsent() {
        #expect(TranscriptionMethod.appleSpeech.requiredPermissions == [.microphone, .speechRecognition])
        #expect(TranscriptionMethod.openAI.requiredPermissions == [.microphone])
        #expect(UploadConsentGate(method: .appleSpeech).needsDecision == false)
        #expect(UploadConsentGate(method: .openAI).needsDecision)
        #expect(TranscriptionMethod.openAI.uploadProvider == .openai)
    }

    @Test func uploadIsRefusedWithoutConsent() async throws {
        let provider = StubTranscriptionProvider()
        let service = ConsentedTranscriptionService(transcriber: ChunkedTranscriber(provider: provider, segmenter: NoSegmenter()))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("consent-\(UUID().uuidString).m4a")
        try Data(repeating: 1, count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let template = TranscriptionRequest(audio: AudioPayload(data: Data(), fileName: "x.m4a", format: .m4a))

        var gate = UploadConsentGate(method: .openAI)
        await #expect(throws: UploadConsentError.consentMissing(provider: "openai")) {
            try await service.transcribe(file: file, duration: 3, template: template, gate: gate)
        }
        gate.deny(at: now)
        await #expect(throws: UploadConsentError.consentDenied(provider: "openai")) {
            try await service.transcribe(file: file, duration: 3, template: template, gate: gate)
        }
        #expect(provider.callCount == 0)

        gate.grant(at: now)
        let result = try await service.transcribe(file: file, duration: 3, template: template, gate: gate)
        #expect(result.text == "Hallo Welt")
        #expect(provider.callCount == 1)
    }

    @Test func retentionAndHints() {
        #expect(AudioRetention.shouldDelete(policy: .deleteAfterTranscription, transcriptionSucceeded: true, recordedAt: now, now: now))
        #expect(!AudioRetention.shouldDelete(policy: .deleteAfterTranscription, transcriptionSucceeded: false, recordedAt: now, now: now))
        #expect(!AudioRetention.shouldDelete(policy: .keepLocally, transcriptionSucceeded: true, recordedAt: now, now: now))
        #expect(AudioRetention.shouldDelete(policy: .keepForDays(2), transcriptionSucceeded: true, recordedAt: now,
                                            now: now.addingTimeInterval(3 * 86_400)))
        #expect(TranscriptionHints.parse("GRDB, CloudKit\n<x>, grdb; ADR") == ["GRDB", "CloudKit", "ADR"])
    }
}
