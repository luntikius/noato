import Testing
@testable import quill

@Suite("Sequential setup")
struct SetupProgressTests {
    @Test func stepsUnlockOnlyAfterTheirPredecessorsSucceed() {
        var progress = SetupProgress()
        #expect(progress.next == .microphone)
        #expect(!progress.canFinish)
        let accepted1 = progress.begin(.models); #expect(accepted1 == false); let accepted2 = progress.begin(.systemAudio); #expect(accepted2 == false)
        let accepted3 = progress.begin(.microphone); #expect(accepted3 == true); let accepted4 = progress.begin(.microphone); #expect(accepted4 == false)
        let accepted5 = progress.complete(.microphone, success: true); #expect(accepted5 == true)
        #expect(progress.phase(.microphone) == .completed)
        #expect(progress.next == .systemAudio)
        let accepted6 = progress.begin(.models); #expect(accepted6 == false)
        let accepted7 = progress.begin(.systemAudio); #expect(accepted7 == true); let accepted8 = progress.complete(.systemAudio, success: true); #expect(accepted8 == true)
        #expect(progress.next == .models); #expect(!progress.canFinish)
        let accepted9 = progress.begin(.models); #expect(accepted9 == true); #expect(!progress.canFinish)
        let accepted10 = progress.complete(.models, success: true, diarization: true); #expect(accepted10 == true)
        #expect(progress.canFinish)
        #expect(SetupStep.allCases.allSatisfy { progress.phase($0) == .completed })
    }
    @Test func denialAndModelErrorsStayRetryableWithoutUnlockingFollowingSteps() {
        var progress = SetupProgress()
        let accepted11 = progress.begin(.microphone); #expect(accepted11 == true)
        let accepted12 = progress.complete(.microphone, success: false, message: "denied"); #expect(accepted12 == true)
        #expect(progress.phase(.microphone) == .failed); #expect(!progress.canBegin(.systemAudio))
        let accepted13 = progress.begin(.microphone); #expect(accepted13 == true); let accepted14 = progress.complete(.microphone, success: true); #expect(accepted14 == true)
        let accepted15 = progress.begin(.systemAudio); #expect(accepted15 == true); let accepted16 = progress.complete(.systemAudio, success: true); #expect(accepted16 == true)
        let accepted17 = progress.begin(.models); #expect(accepted17 == true); progress.report("Whisper", for: .models)
        #expect(progress.message == "Whisper")
        let accepted18 = progress.complete(.models, success: false, message: "download failed"); #expect(accepted18 == true)
        #expect(!progress.canFinish); #expect(progress.canBegin(.models))
        #expect(progress.completed == [.microphone, .systemAudio])
    }
    @Test func existingMicPermissionIsCheckedAndRevocationBlocksFinish() {
        var progress = SetupProgress()
        progress.refresh(microphoneAllowed: true, diarization: true)
        #expect(progress.phase(.microphone) == .completed); #expect(progress.next == .systemAudio)
        let accepted19 = progress.begin(.systemAudio); #expect(accepted19 == true); let accepted20 = progress.complete(.systemAudio, success: true); #expect(accepted20 == true)
        let accepted21 = progress.begin(.models); #expect(accepted21 == true); let accepted22 = progress.complete(.models, success: true, diarization: true); #expect(accepted22 == true)
        #expect(progress.canFinish)
        progress.refresh(microphoneAllowed: false, diarization: true)
        #expect(!progress.canFinish); #expect(progress.next == .microphone)
    }
    @Test func changedModelRequirementsAndStaleRepliesDoNotCompleteSetup() {
        var progress = SetupProgress()
        progress.refresh(microphoneAllowed: true, diarization: false)
        let accepted23 = progress.complete(.models, success: true, diarization: false); #expect(accepted23 == false)
        let accepted24 = progress.begin(.systemAudio); #expect(accepted24 == true); let accepted25 = progress.complete(.systemAudio, success: true); #expect(accepted25 == true)
        let accepted26 = progress.begin(.models); #expect(accepted26 == true); let accepted27 = progress.complete(.models, success: true, diarization: false); #expect(accepted27 == true)
        #expect(progress.canFinish)
        progress.refresh(microphoneAllowed: true, diarization: true)
        #expect(!progress.canFinish); #expect(progress.next == .models)
    }
}
