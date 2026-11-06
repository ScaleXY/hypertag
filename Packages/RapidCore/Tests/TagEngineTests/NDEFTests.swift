import Foundation
import Testing
import TagEngine

@Suite struct NDEFEncodingTests {
    private func encoded(_ records: NDEFRecordDraft...) throws -> String {
        try NDEFMessageBuilder.encode(records).engineHex
    }

    private func hex(_ text: String) -> String { Data(text.utf8).engineHex }

    // Examples from the NFC Forum URI Record Type Definition.
    @Test func uriSpecificationExamples() throws {
        #expect(try encoded(.url("http://www.nfc.com")) == "D1010855016E66632E636F6D")
        #expect(try encoded(.url("tel:+35891234567")) == "D1010D55052B3335383931323334353637")
    }

    @Test func httpsURL() throws {
        #expect(try encoded(.url("https://example.com")) == "D1010C55046578616D706C652E636F6D")
    }

    @Test(arguments: [
        ("http://www.a.io", "01", "a.io"),
        ("https://www.a.io", "02", "a.io"),
        ("http://a.io", "03", "a.io"),
        ("https://a.io/p?q=1#f", "04", "a.io/p?q=1#f"),
        ("tel:+15551234", "05", "+15551234"),
        ("mailto:a@b.io", "06", "a@b.io"),
        ("sms:+15551234", "00", "sms:+15551234"),
        ("sms:+15551234?body=hi", "00", "sms:+15551234?body=hi"),
        ("HTTPS://a.io", "00", "HTTPS://a.io"),
    ])
    func uriPrefixCompression(url: String, code: String, rest: String) throws {
        let length = String(format: "%02X", rest.utf8.count + 1)
        #expect(try encoded(.url(url)) == "D101\(length)55\(code)\(hex(rest))")
    }

    @Test func textRecord() throws {
        #expect(try encoded(.text("Hello, world!", language: "en")) == "D101105402656E48656C6C6F2C20776F726C6421")
    }

    @Test func textRecordWithRegionAndUnicode() throws {
        // "é" is two bytes in UTF-8, and the status byte counts the 5-byte language code.
        #expect(try encoded(.text("é", language: "fr-CA")) == "D10108540566722D4341C3A9")
    }

    @Test func vCardRecord() throws {
        let card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ann\r\nEND:VCARD\r\n"
        let expected = "D20C2D" + hex("text/x-vcard") + hex(card)
        #expect(card.utf8.count == 0x2D)
        #expect(try encoded(.contact(vCard: card)) == expected)
    }

    @Test func customMIMERecord() throws {
        let record = NDEFRecordDraft.mime(type: "application/vnd.rapid+json", payload: Data([0x7B, 0x7D]))
        #expect(try encoded(record) == "D21A02" + hex("application/vnd.rapid+json") + "7B7D")
    }

    @Test func twoRecordsSetBeginAndEndFlags() throws {
        let message = try NDEFMessageBuilder.encode([.url("https://a.io"), .text("hi", language: "en")])
        #expect(message == Data(engineHex: "91 01 05 55 04 612E696F  51 01 05 54 02 656E 6869"))
    }

    @Test func threeRecordsClearFlagsInTheMiddle() throws {
        let message = try NDEFMessageBuilder.encode([
            .text("a", language: "en"), .text("b", language: "en"), .text("c", language: "en"),
        ])
        #expect(message == Data(engineHex: "91 01 04 54 02 656E 61  11 01 04 54 02 656E 62  51 01 04 54 02 656E 63"))
    }

    @Test func payloadOf255UsesShortForm() throws {
        let payload = Data(repeating: 0xAB, count: 255)
        let message = try NDEFMessageBuilder.encode([.mime(type: "a/b", payload: payload)])
        #expect(message == Data(engineHex: "D2 03 FF 612F62") + payload)
    }

    @Test func payloadOf256UsesLongForm() throws {
        let payload = Data(repeating: 0xAB, count: 256)
        let message = try NDEFMessageBuilder.encode([.mime(type: "a/b", payload: payload)])
        #expect(message == Data(engineHex: "C2 03 00000100 612F62") + payload)
    }

    @Test func longURLUsesLongForm() throws {
        let path = String(repeating: "a", count: 300)
        let message = try NDEFMessageBuilder.encode([.url("https://a.io/" + path)])
        // Payload: 1 prefix byte, then "a.io/" and the path.
        #expect(message.prefix(7) == Data(engineHex: "C1 01 00000132 55"))
        #expect(message.count == 7 + 306)
        #expect(message[7] == 0x04)
    }

    @Test func longRecordKeepsFlagsInMultiRecordMessage() throws {
        let long = NDEFRecordDraft.mime(type: "a/b", payload: Data(repeating: 1, count: 300))
        let message = try NDEFMessageBuilder.encode([.text("a", language: "en"), long])
        #expect(message[0] == 0x91)
        #expect(message[8] == 0x42)
    }

    @Test func mimePayloadSliceEncodesItsOwnBytes() throws {
        let slice = Data([0x00, 0x11, 0x22, 0x33])[2...]
        let message = try NDEFMessageBuilder.encode([.mime(type: "a/b", payload: slice)])
        #expect(message == Data(engineHex: "D2 03 02 612F62 2233"))
    }
}

@Suite struct NDEFValidationTests {
    @Test func emptyMessage() {
        #expect(throws: NDEFError.empty) { try NDEFMessageBuilder.encode([]) }
    }

    @Test(arguments: [
        NDEFRecordDraft.url(""),
        .text("", language: "en"),
        .contact(vCard: ""),
        .mime(type: "a/b", payload: Data()),
    ])
    func draftsWithNoContent(draft: NDEFRecordDraft) {
        #expect(throws: NDEFError.empty) { try NDEFMessageBuilder.validate(draft) }
    }

    @Test(arguments: [
        "https://example.com", "http://example.com/a?b=c", "HTTPS://example.com", "https://münchen.de",
        "tel:+15551234", "mailto:a@b.io", "sms:+15551234", "sms:+15551234?body=hi",
    ])
    func acceptedURLs(url: String) throws {
        try NDEFMessageBuilder.validate(.url(url))
    }

    @Test(arguments: [
        "not a url", "example.com", "https://", "https:foo", "http://", "tel:", "mailto:", "sms:",
        "https://exa mple.com", "tel:+1 555", "https://a.io/a b", "https://a.io/\n", "https://%zz",
    ])
    func invalidURLs(url: String) {
        #expect(throws: NDEFError.invalidURL) { try NDEFMessageBuilder.validate(.url(url)) }
    }

    @Test(arguments: [
        "ftp://example.com", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "myapp://open",
    ])
    func disallowedSchemes(url: String) {
        #expect(throws: NDEFError.disallowedScheme) { try NDEFMessageBuilder.validate(.url(url)) }
    }

    @Test(arguments: ["en", "EN", "en-US", "zh-Hans-CN", "de-1996", "fil"])
    func acceptedLanguages(code: String) throws {
        try NDEFMessageBuilder.validate(.text("x", language: code))
    }

    @Test(arguments: [
        "", "e", "en_US", "en-", "-en", "en--US", "e1", "abcdefghi", "en-abcdefghi", "日本", "en US",
        "en-" + Array(repeating: "abcdefgh", count: 8).joined(separator: "-"),
    ])
    func invalidLanguages(code: String) {
        #expect(throws: NDEFError.invalidLanguageCode) { try NDEFMessageBuilder.validate(.text("x", language: code)) }
    }

    @Test(arguments: [
        "text/plain", "application/vnd.api+json", "text/x-vcard", "a/b", "application/x.y_z-1",
    ])
    func acceptedMIMETypes(type: String) throws {
        try NDEFMessageBuilder.validate(.mime(type: type, payload: Data([1])))
    }

    @Test(arguments: [
        "", "text", "/plain", "text/", "a/b/c", "text/plain; charset=utf-8", "te xt/plain", "*/*", "téxt/plain",
        ".a/b", String(repeating: "a", count: 128) + "/b",
    ])
    func invalidMIMETypes(type: String) {
        #expect(throws: NDEFError.invalidMIMEType) { try NDEFMessageBuilder.validate(.mime(type: type, payload: Data([1]))) }
    }

    @Test func longestMIMETypeFitsTheTypeLengthByte() throws {
        let name = String(repeating: "a", count: 127)
        let message = try NDEFMessageBuilder.encode([.mime(type: "\(name)/\(name)", payload: Data([1]))])
        #expect(message[1] == 255)
    }

    @Test func messageAtTheCapIsAccepted() throws {
        // A long-form header is 6 bytes and the type 3, which leaves 4087 of payload.
        let message = try NDEFMessageBuilder.encode([.mime(type: "a/b", payload: Data(count: 4087))])
        #expect(message.count == NDEFMessageBuilder.maximumMessageSize)
    }

    @Test func oneByteOverTheCapIsRefused() {
        #expect(throws: NDEFError.tooLarge) {
            try NDEFMessageBuilder.encode([.mime(type: "a/b", payload: Data(count: 4088))])
        }
    }

    @Test func capAppliesAcrossRecords() {
        let half = NDEFRecordDraft.mime(type: "a/b", payload: Data(count: 2100))
        #expect(throws: NDEFError.tooLarge) { try NDEFMessageBuilder.encode([half, half]) }
    }

    @Test func validateAppliesTheCapToOneRecord() {
        #expect(throws: NDEFError.tooLarge) {
            try NDEFMessageBuilder.validate(.text(String(repeating: "x", count: 5000), language: "en"))
        }
    }

    @Test func encodeReportsABadRecordAnywhereInTheList() {
        #expect(throws: NDEFError.disallowedScheme) {
            try NDEFMessageBuilder.encode([.text("a", language: "en"), .url("ftp://a.io")])
        }
    }
}
