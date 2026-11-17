// Enumerates the child components of a container-like payload, whose children sit under "content" or "children".
// ComponentView renders each child through ComponentChildrenList and the compact layouts share the same item list.

import AstralCore
import SwiftUI

enum ComponentChildren {
    static func key(_ raw: JSONValue) -> String {
        raw["content"]?.arrayValue != nil ? "content" : "children"
    }

    static func items(_ raw: JSONValue) -> [(index: Int, component: AstralComponent)] {
        (raw[key(raw)]?.arrayValue ?? []).enumerated().compactMap { index, value in
            AstralComponent(json: value).map { (index, $0) }
        }
    }
}

struct ComponentChildrenList: View {
    let raw: JSONValue

    var body: some View {
        ForEach(ComponentChildren.items(raw), id: \.index) { item in
            ComponentView(component: item.component)
        }
    }
}
