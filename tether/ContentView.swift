//
//  ContentView.swift
//  tether
//
//  Created by Zack Radisic on 06/06/2023.
//

import SwiftUI
import EditorKit

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundColor(.accentColor)
            Button("Hello, world!") {
                let cstr = say_hello()
                let str = String(cString: cstr!)
                print("STRING \(str)")
            }
//            EditorViewRepresentable()
            ZigTestViewRepresentable()
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
