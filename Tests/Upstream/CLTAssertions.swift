// XCTest-compatible assertion subset: same upstream test bodies, no XCTest runtime dependency.
import Foundation
class XCTestCase {}
func XCTAssertTrue(_ v: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(v(), message, file: file, line: line) }
func XCTAssertFalse(_ v: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(!v(), message, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(a == b, message, file: file, line: line) }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(abs(a-b) <= accuracy, message, file: file, line: line) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(a < b, message, file: file, line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(a > b, message, file: file, line: line) }
func XCTAssertNotNil<T>(_ a: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(a != nil, message, file: file, line: line) }
func XCTUnwrap<T>(_ a: T?, file: StaticString = #file, line: UInt = #line) throws -> T { guard let a else { throw NSError(domain: "UpstreamAssertion", code: Int(line)) }; return a }
