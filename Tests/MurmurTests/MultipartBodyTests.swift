import Foundation
import Testing
@testable import Murmur

struct MultipartBodyTests {
    /// RFC 7578: each part opens with the boundary and its headers, a blank line, the bytes and a
    /// CRLF; the body closes with the boundary and two dashes.
    @Test func framesEachPartAndClosesTheBody() {
        var body = MultipartBody(boundary: "b0undary")
        body.appendField(name: "metadata", contentType: "application/json", Data(#"{"a":1}"#.utf8))
        body.appendFile(name: "audio", filename: "audio.m4a", contentType: "audio/mp4", Data([0x00, 0xFF, 0x0D, 0x0A]))

        var expected = Data("""
        --b0undary\r
        Content-Disposition: form-data; name="metadata"\r
        Content-Type: application/json\r
        \r
        {"a":1}\r
        --b0undary\r
        Content-Disposition: form-data; name="audio"; filename="audio.m4a"\r
        Content-Type: audio/mp4\r
        \r

        """.utf8)
        expected.append(contentsOf: [0x00, 0xFF, 0x0D, 0x0A])
        expected.append(Data("\r\n--b0undary--\r\n".utf8))
        #expect(body.finalized() == expected)
        #expect(body.contentType == "multipart/form-data; boundary=b0undary")
    }

    @Test func eachBodyHasItsOwnBoundary() {
        #expect(MultipartBody().boundary != MultipartBody().boundary)
        #expect(MultipartBody().boundary.hasPrefix("murmur-"))
    }
}
