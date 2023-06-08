//
//  ContentView.swift
//  tether
//
//  Created by Zack Radisic on 06/06/2023.
//

import SwiftUI
import EditorKit
import CoreText

struct ContentView: View {
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundColor(.accentColor)
            Text("HEY")
            Button("Hello, world!") {
            }
//            EditorViewRepresentable()
//            ZigTestViewRepresentable()
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
