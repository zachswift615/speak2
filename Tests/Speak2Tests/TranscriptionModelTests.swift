import XCTest
@testable import Speak2

final class TranscriptionModelTests: XCTestCase {

    func testParakeetVersionsRoundTripThroughRawValue() {
        XCTAssertEqual(TranscriptionModel(rawValue: "parakeet-v2"), .parakeetV2)
        XCTAssertEqual(TranscriptionModel(rawValue: "parakeet-v3"), .parakeetV3)
    }

    func testParakeetVersionsHaveSeparateStoragePaths() {
        let v2 = TranscriptionModel.parakeetV2.storagePath
        let v3 = TranscriptionModel.parakeetV3.storagePath
        XCTAssertNotEqual(v2, v3, "Deleting one Parakeet version must not remove the other")
        XCTAssertEqual(v2.lastPathComponent, "parakeet-tdt-0.6b-v2-coreml")
        XCTAssertEqual(v3.lastPathComponent, "parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(v2.deletingLastPathComponent().lastPathComponent, "Models")
        XCTAssertEqual(v2.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "FluidAudio")
    }

    func testParakeetModelsAreNotWhisperVariants() {
        XCTAssertNil(TranscriptionModel.parakeetV2.whisperVariant)
        XCTAssertNil(TranscriptionModel.parakeetV3.whisperVariant)
        XCTAssertNil(TranscriptionModel.whisperBaseEn.parakeetFolderName)
    }

    func testOnlyMultilingualWhisperSupportsLanguageSelection() {
        XCTAssertFalse(TranscriptionModel.parakeetV2.supportsLanguageSelection)
        XCTAssertFalse(TranscriptionModel.parakeetV3.supportsLanguageSelection)
        XCTAssertTrue(TranscriptionModel.whisperLargeV3.supportsLanguageSelection)
    }
}
