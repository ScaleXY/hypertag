import Foundation
import TagEngine

/// Reader scripts for the in-app test bench.
public enum ReaderScripts {
    /// Bytes per READ BINARY. Stays under the 255-byte MLe in the Capability Container.
    public static let type4ReadChunk = 250

    private static let type4AID = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])
    private static let capabilityContainerFile = Data([0xE1, 0x03])
    private static let ndefFile = Data([0xE1, 0x04])
    private static let ndefLengthPrefix = 2
    private static let maximumLabelLength = 64

    /// Covers any message up to `NDEFMessageBuilder.maximumMessageSize`. For a shorter message the reads past
    /// its end return `6B 00`. Use `type4Read(messageLength:)` when the length is known.
    public static var type4Read: [Data] {
        type4Read(messageLength: NDEFMessageBuilder.maximumMessageSize)
    }

    /// The same read, with exactly the READ BINARY commands that a message of `messageLength` bytes needs.
    /// The length is clamped to `0...NDEFMessageBuilder.maximumMessageSize`.
    public static func type4Read(messageLength: Int) -> [Data] {
        var script = [
            selectApplication(type4AID),
            selectFile(capabilityContainerFile),
            readBinary(offset: 0, length: 15),
            selectFile(ndefFile),
            readBinary(offset: 0, length: ndefLengthPrefix),
        ]
        var offset = ndefLengthPrefix
        let end = ndefLengthPrefix + min(max(messageLength, 0), NDEFMessageBuilder.maximumMessageSize)
        while offset < end {
            let length = min(type4ReadChunk, end - offset)
            script.append(readBinary(offset: offset, length: length))
            offset += length
        }
        return script
    }

    public static func signerAuthenticate(nonce: Data) -> [Data] {
        [selectApplication(SignerApplet.defaultAID), command(cla: 0x80, ins: 0x30, data: nonce, le: 0x00)]
    }

    public static func signerSign(digest: Data, format: SignatureFormat, label: String?) -> [Data] {
        var body = digest
        if let label, !label.isEmpty {
            let bytes = truncatedLabel(label)
            body += [0xA0, UInt8(bytes.count)]
            body += bytes
        }
        return [
            selectApplication(SignerApplet.defaultAID),
            command(cla: 0x80, ins: 0x40, p1: format.rawValue, data: body, le: 0x00),
        ]
    }

    /// Cuts at a character boundary, because the applet refuses a label that isn't valid UTF-8.
    private static func truncatedLabel(_ label: String) -> Data {
        var bytes = Data()
        for character in label {
            let encoded = Data(String(character).utf8)
            guard bytes.count + encoded.count <= maximumLabelLength else { break }
            bytes += encoded
        }
        return bytes
    }

    private static func selectApplication(_ aid: Data) -> Data {
        command(ins: 0xA4, p1: 0x04, data: aid, le: 0x00)
    }

    private static func selectFile(_ id: Data) -> Data {
        command(ins: 0xA4, p2: 0x0C, data: id)
    }

    private static func readBinary(offset: Int, length: Int) -> Data {
        command(ins: 0xB0, p1: UInt8(offset >> 8), p2: UInt8(offset & 0xFF), le: UInt8(length))
    }

    /// Short-form APDU. Data past the 255-byte limit of the form is dropped.
    private static func command(
        cla: UInt8 = 0x00, ins: UInt8, p1: UInt8 = 0x00, p2: UInt8 = 0x00, data: Data = Data(), le: UInt8? = nil
    ) -> Data {
        var apdu = Data([cla, ins, p1, p2])
        if !data.isEmpty {
            let body = data.prefix(255)
            apdu.append(UInt8(body.count))
            apdu.append(body)
        }
        if let le { apdu.append(le) }
        return apdu
    }
}
