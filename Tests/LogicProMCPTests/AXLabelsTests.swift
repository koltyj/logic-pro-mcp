import XCTest
@testable import LogicProMCP

final class AXLabelsTests: XCTestCase {
    func testMatchesEveryVariantIgnoringCaseAndWhitespace() {
        let label = AXLabel(key: "mute", variants: ["Mute", "靜音"])
        XCTAssertTrue(label.matches("Mute"))
        XCTAssertTrue(label.matches(" mute "))
        XCTAssertTrue(label.matches("靜音"))
        XCTAssertFalse(label.matches("Muted"))
        XCTAssertFalse(label.matches(nil))
        XCTAssertFalse(label.matches(""))
    }

    func testPrefixAndContainment() {
        let label = AXLabel(key: "mute", variants: ["Mute", "靜音"])
        XCTAssertTrue(label.isPrefix(of: "Mute (M)"))
        XCTAssertTrue(label.isPrefix(of: "靜音，開啟"))
        XCTAssertFalse(label.isPrefix(of: "Unmute"))
        XCTAssertTrue(label.isContained(in: "Track 1 Mute"))
        XCTAssertFalse(label.isContained(in: nil))
    }

    func testTraditionalChineseSpellingsFromLogic12() {
        // Read from Logic Pro 12.4 running in zh-Hant.
        XCTAssertTrue(AXLabels.controlBar.matches("控制列"))
        XCTAssertTrue(AXLabels.tracksHeader.matches("音軌 標題"))
        XCTAssertTrue(AXLabels.mixer.matches("混音器"))
        XCTAssertTrue(AXLabels.volumeFader.matches("音量推子"))
        XCTAssertTrue(AXLabels.pan.matches("聲像"))
        XCTAssertTrue(AXLabels.bypass.matches("略過"))
        XCTAssertTrue(AXLabels.hasFocus.matches("包含焦點"))
        XCTAssertTrue(AXLabels.metronome.matches("節拍器卡嗒聲"))
        XCTAssertTrue(AXLabels.onState.matches("開啟"))
        XCTAssertFalse(AXLabels.onState.matches("關閉"))
    }

    func testEnglishSpellingsStillMatch() {
        XCTAssertTrue(AXLabels.controlBar.matches("Control Bar"))
        XCTAssertTrue(AXLabels.volumeFader.matches("volume fader"))
        XCTAssertTrue(AXLabels.volumeFader.matches("volumeFader"), "Mixer window spelling")
        XCTAssertTrue(AXLabels.onState.matches("on"))
    }

    func testLegacyEnglishNamesResolveToLocalizedLabels() {
        XCTAssertEqual(AXLabels.label(forEnglishName: "Cycle"), AXLabels.cycle)
        XCTAssertEqual(AXLabels.label(forEnglishName: "metronome"), AXLabels.metronome)
        let unknown = AXLabels.label(forEnglishName: "Something Else")
        XCTAssertEqual(unknown.variants, ["Something Else"])
    }

    func testParseOverridesAcceptsListsAndSingleStrings() throws {
        let json = #"{"mute": ["Stumm", "Muet"], "mixer": "Mischpult", "bad": 3}"#
        let parsed = try XCTUnwrap(AXLabels.parseOverrides(Data(json.utf8)))
        XCTAssertEqual(parsed["mute"], ["Stumm", "Muet"])
        XCTAssertEqual(parsed["mixer"], ["Mischpult"])
        XCTAssertNil(parsed["bad"])
        XCTAssertNil(AXLabels.parseOverrides(Data("[1,2]".utf8)))
    }

    func testMergeKeepsBuiltInsFirstAndDropsDuplicates() {
        let label = AXLabels.merge(key: "mute", builtIn: ["Mute", "靜音"], extra: ["mute", "Stumm"])
        XCTAssertEqual(label.variants, ["Mute", "靜音", "Stumm"])
    }

    func testMasterStripMatchingIsLabelBased() {
        let indices = AXLogicProElements.masterStripCandidateIndices(
            descriptions: ["Audio 1", "Stereo Out", nil, " master "]
        )
        XCTAssertEqual(indices, [3, 1])
    }
}
