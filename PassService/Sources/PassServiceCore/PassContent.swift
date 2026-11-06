import Foundation
import PassBuilder

public enum PassIdentity {
    public static let passTypeIdentifier = "pass.dev.scalexy.rapidwallet.tag"
    public static let teamIdentifier = "B2AA43A5CZ"
    public static let organizationName = "ScaleXY"
}

extension PassRequest {
    /// Builds the unsigned pass. `validate()` must have passed, because `serial` is placed in link markup.
    public func makePackage() -> PassPackage {
        var pass = Pass()
        pass.passTypeIdentifier = PassIdentity.passTypeIdentifier
        pass.teamIdentifier = PassIdentity.teamIdentifier
        pass.organizationName = PassIdentity.organizationName
        pass.serialNumber = serial
        pass.description = "Rapid Wallet tag"
        pass.sharingProhibited = true
        pass.generic = fields

        if let qr {
            var barcode = Pass.Barcode()
            barcode.format = .qr
            barcode.message = qr
            barcode.messageEncoding = "utf-8"
            pass.barcodes = [barcode]
        }

        var package = PassPackage()
        package.pass = pass
        package.icon.times1 = PassImageFile(data: Data(PackageResources.icon_png), fileType: .png)
        package.icon.times2 = PassImageFile(data: Data(PackageResources.icon_2x_png), fileType: .png)
        package.logo.times1 = PassImageFile(data: Data(PackageResources.logo_png), fileType: .png)
        return package
    }

    private var kindName: String {
        switch kind {
        case .normal: "Normal"
        case .signer: "Signer"
        }
    }

    private var fields: Pass.Fields {
        var fields = Pass.Fields()
        fields.primaryFields = [field("name", label: "TAG", value: title)]

        // The plan's sample sends the type name as `details`, so only other text gets its own field.
        var secondary = [field("type", label: "TYPE", value: kindName)]
        if !details.isEmpty, details != kindName {
            secondary.append(field("details", label: "DETAILS", value: details))
        }
        fields.secondaryFields = secondary

        var back = [
            field(
                "how",
                label: "How to use",
                value: "Open Rapid Wallet and press Present. Holding this pass near a reader won't work."
            )
        ]
        if kind == .signer {
            back.append(field("key", label: "Signing key", value: "The key stays on the iPhone that created it."))
        }
        var link = field("open", label: "Rapid Wallet", value: "Open in Rapid Wallet")
        link.attributedValue = "<a href='rapidwallet://tag/\(serial)'>Open in Rapid Wallet</a>"
        back.append(link)
        fields.backFields = back

        return fields
    }

    private func field(_ key: String, label: String, value: String) -> Pass.FieldContent {
        var field = Pass.FieldContent(key: key, label: label, value: .text(value))
        field.textAlignment = nil
        return field
    }
}
