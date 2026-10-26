import Testing
@testable import TapeCore

struct NoticeTests {
    @Test func permissionNoticesOfferThePrivacyPane() {
        #expect(Notice.microphoneDenied.privacyPane == .microphone)
        #expect(Notice.systemAudioDenied.privacyPane == .systemAudio)
        #expect(Notice.noSystemAudio.privacyPane == .systemAudio)
        #expect(Notice.stopped(.sleep).privacyPane == nil)
    }

    @Test func stopReasonsNameTheVolume() {
        #expect(Notice.stopped(.diskFull(volume: "Macintosh HD")).text == "Recording stopped: “Macintosh HD” is full.")
        #expect(Notice.recovered(name: "Tape 2026-10-26 at 14.03.05").text == "Recovered “Tape 2026-10-26 at 14.03.05”.")
        #expect(Notice.reduceEchoUnavailable.text == "Reduce Echo couldn’t start, so this recording doesn’t use it.")
        #expect(Notice.reduceEchoUnavailable.privacyPane == nil)
    }

    @Test func privacyPaneURLs() {
        #expect(PrivacyPane.microphone.url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(PrivacyPane.systemAudio.url.absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }
}
