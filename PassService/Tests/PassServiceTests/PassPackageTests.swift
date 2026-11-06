import PassBuilder
import PassServiceCore
import Testing

@Suite("Pass Builder validation")
struct PassPackageTests {
    @Test(arguments: [PassRequest.Kind.normal, .signer], [nil, "https://example.com"])
    func packageHasNoValidationErrors(kind: PassRequest.Kind, qr: String?) {
        let request = PassRequest(
            serial: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            kind: kind,
            title: "Office Wi-Fi",
            details: "Normal",
            qr: qr
        )
        let issues = PassValidator().validate(request.makePackage()).issues
        #expect(issues.filter { $0.severity == .error }.isEmpty, "\(issues)")
    }
}
