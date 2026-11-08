import Foundation

/// A `multipart/form-data` body (RFC 7578): the framing `dictate`'s audio mode reads with Deno's
/// `formData()`. That reads a part without a filename as text, so a file part always names one.
struct MultipartBody {
    let boundary: String
    private var parts = Data()

    init(boundary: String = "murmur-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// The request's Content-Type.
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// A field, such as a JSON part, which the server reads as a string.
    mutating func appendField(name: String, contentType: String, _ value: Data) {
        appendPart(disposition: "form-data; name=\"\(name)\"", contentType: contentType, value)
    }

    /// A file part, which the server reads as a `File`.
    mutating func appendFile(name: String, filename: String, contentType: String, _ value: Data) {
        appendPart(disposition: "form-data; name=\"\(name)\"; filename=\"\(filename)\"", contentType: contentType, value)
    }

    /// The parts and the closing boundary.
    func finalized() -> Data {
        parts + Data("--\(boundary)--\r\n".utf8)
    }

    private mutating func appendPart(disposition: String, contentType: String, _ value: Data) {
        parts.append(Data("--\(boundary)\r\nContent-Disposition: \(disposition)\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        parts.append(value)
        parts.append(Data("\r\n".utf8))
    }
}
