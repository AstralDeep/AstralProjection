// Describes this device to the kernel so adapted chat surfaces fit its screen and only use components the native renderer draws.
// MeshRuntime passes the JSON in the kernel config and RealMeshKernel hands it to the kernel when it opens.

import AstralCore
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
enum MeshDeviceProfile {
    static func json(kind: MeshDeviceKind, width: Int? = nil, height: Int? = nil) -> String {
        let mac = kind == .desktop
        let disposition = mac ? ClientDispositions.macos : ClientDispositions.ios
        let (w, h) = size(mac: mac, width: width, height: height)
        let fields: [String: JSONValue] = [
            "device_type": .string(mac ? "macos" : "ios"),
            "screen_width": .number(Double(w)), "screen_height": .number(Double(h)),
            "viewport_width": .number(Double(w)), "viewport_height": .number(Double(h)),
            "pixel_ratio": .number(2),
            "has_touch": .bool(!mac),
            "pointer_type": .string(mac ? "fine" : "coarse"),
            "supported_types": .array(disposition.nativeComponentTypes.map { .string($0) }),
        ]
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func size(mac: Bool, width: Int?, height: Int?) -> (Int, Int) {
        if let width, let height { return (width, height) }
        #if os(iOS)
            if !mac {
                let bounds = UIScreen.main.bounds.size
                return (Int(bounds.width), Int(bounds.height))
            }
        #endif
        return mac ? (1280, 800) : (390, 844)
    }
}
