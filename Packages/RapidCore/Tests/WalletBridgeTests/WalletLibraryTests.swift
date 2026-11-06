import Foundation
import Testing
@testable import WalletBridge

@Suite struct WalletLibraryTests {
    private let library = WalletLibrary(passTypeIdentifier: "pass.dev.scalexy.rapidwallet.tag")

    #if os(iOS)
    @Test func garbageDataIsInvalidPass() {
        #expect(throws: WalletError.invalidPass) {
            try library.replacePass(data: Data("not a pass".utf8))
        }
    }

    @Test func unknownSerialIsAbsent() {
        #expect(!library.containsPass(serial: UUID().uuidString))
        library.removePass(serial: UUID().uuidString)
    }

    @Test func isAvailableAnswersOnAndOffTheMainThread() async {
        let library = library
        let onMain = await MainActor.run { library.isAvailable }
        let offMain = await Task.detached { library.isAvailable }.value
        #expect(onMain == offMain)
    }
    #else
    @Test func walletIsUnavailableOffIOS() {
        #expect(!library.isAvailable)
        #expect(!library.containsPass(serial: "serial"))
        library.removePass(serial: "serial")
        #expect(throws: WalletError.walletUnavailable) {
            try library.replacePass(data: Data())
        }
    }
    #endif
}
