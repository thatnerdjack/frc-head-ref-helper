//
//  RefWidgetsBundle.swift
//  RefWidgets
//
//  The widget extension's entry point. A Live Activity's UI has to be declared
//  by a Widget in an extension — the app can start and update an activity but
//  cannot draw one — which is why this target exists.
//

import SwiftUI
import WidgetKit

@main
struct RefWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MatchLiveActivity()
    }
}
