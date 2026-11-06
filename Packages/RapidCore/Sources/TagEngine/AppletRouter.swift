import Foundation

/// Sits between the transport and one applet. Every input gets a response of at least a status word.
public actor AppletRouter {
    private let applet: any CardApplet
    private var isSelected = false
    // Bumped by `reset()` so a SELECT still in flight can't re-select after the reader has left.
    private var generation = 0

    public init(applet: any CardApplet) {
        self.applet = applet
    }

    public func handle(_ rawCommand: Data) async -> Data {
        guard let command = CommandAPDU(raw: rawCommand) else {
            return ResponseAPDU(status: .wrongLength).raw
        }

        if command.cla == 0x00, command.ins == 0xA4, command.p1 == 0x04 {
            // A failed SELECT leaves the current selection in place, as on a physical card.
            guard command.data == applet.aid else {
                return ResponseAPDU(status: .fileNotFound).raw
            }
            let startedIn = generation
            let response = await applet.select()
            if startedIn == generation {
                isSelected = response.status == .success
            }
            return response.raw
        }

        guard isSelected else {
            return ResponseAPDU(status: .conditionsNotSatisfied).raw
        }
        return await applet.process(command).raw
    }

    public func reset() async {
        generation += 1
        isSelected = false
        await applet.reset()
    }
}
