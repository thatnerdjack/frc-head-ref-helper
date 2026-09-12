//
//  Item.swift
//  FRC Head Ref Helper
//
//  Created by Jack Doherty on 9/12/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
