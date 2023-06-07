//
//  tetherApp.swift
//  tether
//
//  Created by Zack Radisic on 06/06/2023.
//

import SwiftUI

@main
struct tetherApp: App {
    @State var currentNumber: String = "1"

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        MenuBarExtra(currentNumber, systemImage: "\(currentNumber).circle") {
            // 3
            Button("One") {
                currentNumber = "1"
            }
            Button("Two") {
                currentNumber = "2"
            }
            Button("Three") {
                currentNumber = "3"
            }
        }
    }
}
