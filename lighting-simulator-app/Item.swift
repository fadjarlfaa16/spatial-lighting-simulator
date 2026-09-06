//
//  Item.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 06/09/26.
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
