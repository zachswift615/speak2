import Foundation
import XCTest
@testable import Speak2

final class ObjCExceptionsTests: XCTestCase {

    func testReturnsValueWhenNoExceptionRaised() throws {
        let value = try withObjCExceptionsCaught { 42 }
        XCTAssertEqual(value, 42)
    }

    func testObjCExceptionBecomesSwiftError() {
        XCTAssertThrowsError(
            try withObjCExceptionsCaught {
                NSException(name: .internalInconsistencyException,
                            reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                            userInfo: nil).raise()
            }
        ) { error in
            guard let objc = error as? ObjCExceptionError else {
                return XCTFail("expected ObjCExceptionError, got \(error)")
            }
            XCTAssertEqual(objc.name, NSExceptionName.internalInconsistencyException.rawValue)
            XCTAssertEqual(objc.reason, "required condition is false: format.sampleRate == hwFormat.sampleRate")
            XCTAssertTrue(objc.localizedDescription.contains("hwFormat"))
        }
    }

    func testSwiftErrorsAreRethrownUnchanged() {
        struct Boom: Error, Equatable {}
        XCTAssertThrowsError(try withObjCExceptionsCaught { throw Boom() }) { error in
            XCTAssertEqual(error as? Boom, Boom())
        }
    }
}
