import Testing
@testable import FastShareCore

struct ByteRangeTests {
    @Test(arguments: [
        ("bytes=0-499", ByteRangeSelection.partial(0...499)),
        ("bytes=500-", .partial(500...999)),
        ("bytes=-200", .partial(800...999)),
        ("bytes=-5000", .partial(0...999)), // suffix longer than the file
        ("bytes=900-5000", .partial(900...999)), // end clamps to the last byte
        ("bytes=999-999", .partial(999...999)),
        ("BYTES=0-0", .partial(0...0)),
        ("bytes=1000-", .unsatisfiable), // starts past the end
        ("bytes=-0", .unsatisfiable),
        ("bytes=5-2", .entire), // invalid, so ignored
        ("bytes=0-1,5-6", .entire), // multiple ranges are ignored
        ("items=0-1", .entire),
        ("bytes=abc", .entire),
        ("bytes=+1-2", .entire),
    ])
    func selectsRangeOfThousandByteFile(header: String, expected: ByteRangeSelection) {
        #expect(ByteRange.select(header: header, fileSize: 1000) == expected)
    }

    @Test func missingHeaderMeansEntireFile() {
        #expect(ByteRange.select(header: nil, fileSize: 1000) == .entire)
    }

    @Test func everyRangeOfEmptyFileIsUnsatisfiable() {
        #expect(ByteRange.select(header: "bytes=0-", fileSize: 0) == .unsatisfiable)
        #expect(ByteRange.select(header: "bytes=-10", fileSize: 0) == .unsatisfiable)
    }
}
