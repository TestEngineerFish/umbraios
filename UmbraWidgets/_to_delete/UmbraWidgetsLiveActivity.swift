//
//  UmbraWidgetsLiveActivity.swift
//  UmbraWidgets
//
//  Created by 老沙 on 2026/8/6.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct UmbraWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct UmbraWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UmbraWidgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension UmbraWidgetsAttributes {
    fileprivate static var preview: UmbraWidgetsAttributes {
        UmbraWidgetsAttributes(name: "World")
    }
}

extension UmbraWidgetsAttributes.ContentState {
    fileprivate static var smiley: UmbraWidgetsAttributes.ContentState {
        UmbraWidgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: UmbraWidgetsAttributes.ContentState {
         UmbraWidgetsAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: UmbraWidgetsAttributes.preview) {
   UmbraWidgetsLiveActivity()
} contentStates: {
    UmbraWidgetsAttributes.ContentState.smiley
    UmbraWidgetsAttributes.ContentState.starEyes
}
