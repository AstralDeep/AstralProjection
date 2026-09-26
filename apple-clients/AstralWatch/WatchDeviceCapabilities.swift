// Samples watch hardware and current audio routes without starting capture or requesting permission.
// WatchModel combines these facts with live viewport, accessibility, network and permission observations.

import AVFoundation
import Foundation

#if os(watchOS)
    import WatchKit
#endif

struct WatchDeviceCapabilities {
    static var audio: (microphone: Bool, output: Bool) {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS) && !targetEnvironment(simulator)
            let builtInAudio = WKInterfaceDevice.current().model == "Apple Watch"
        #else
            let builtInAudio = false
        #endif
        return (
            builtInAudio || !session.currentRoute.inputs.isEmpty || !(session.availableInputs ?? []).isEmpty,
            builtInAudio || !session.currentRoute.outputs.isEmpty
        )
    }

    static var scale: Double {
        #if os(watchOS)
            Double(WKInterfaceDevice.current().screenScale)
        #else
            1
        #endif
    }
}
