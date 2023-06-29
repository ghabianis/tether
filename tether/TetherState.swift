//
//  TetherState.swift
//  tether
//
//  Created by Zack Radisic on 27/05/2023.
//


import Foundation
import Cocoa
import Accessibility
import SwiftUI

class TextState {
    var element: AXUIElement
    var role: TextElementRole
    
    init(element: AXUIElement, role: TextElementRole) {
        self.element = element
        self.role = role
    }
    
    func getSelectedText() throws -> CFRange? {
        // Prints the whole text
        //        guard let value: CFString = try self.element.get(.value) else {
        //            return nil
        //        }
        guard let selection: CFRange = try self.element.get(.selectedTextRange) else {
            return nil
        }
        
        return selection
    }
    
    func getVisibleCharacters() throws -> CFRange? {
        guard let visibleCharacters: CFRange = try self.element.get(.visibleCharacterRange) else {
            return nil
        }
        
        print("NICE \(visibleCharacters)")
        return visibleCharacters
    }
}

enum TextElementRole {
    case TextField
    case TextArea
    
    
    static func fromString(_ value: String) -> Self? {
        switch value {
        case "AXTextField":
            return Self.TextField
        case "AXTextArea":
            return Self.TextArea
        default:
            return nil
        }
    }
}

class TetherState: ObservableObject {
    var mouseEventHandler: Any?
    var keyDownEventHandler: Any?
    @Published var isOverlayVisible: Bool = false
    @Published var position: CGPoint?
    @Published var size: CGSize?
    
    var textState: TextState?
    
    func start() {
        mouseEventHandler = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
            self.handleMouseMovement(event: event)
        }
        
        let keyModifierShiftCmdSpace: NSEvent.ModifierFlags = [.shift, .command]
        let keySpace: UInt16 = 49 // spacebar keycode
        
        //        let eventMask = NSEvent.EventTypeMask.flagsChanged.rawValue | NSEvent.EventTypeMask.keyDown.rawValue
        let eventMask = NSEvent.EventTypeMask.keyDown.rawValue
        keyDownEventHandler = NSEvent.addGlobalMonitorForEvents(matching: NSEvent.EventTypeMask(rawValue: eventMask)) {
            (event: NSEvent?) in
            guard let event = event else {
                return
            }
            
            // on SHIFT + CMD + SPACE
            if event.modifierFlags.contains(keyModifierShiftCmdSpace) && event.keyCode == keySpace {
                self.handleToggleTether(event: event)
                return
            }
            
            if self.isOverlayVisible {
                print("Keycode \(event.keyCode)")
            }
        }
        
    }
    
    func setTextState(_ textState: TextState?) {
        self.textState = textState
        self.isOverlayVisible = textState != nil
//        self.isOverlayVisible.toggle()
    }
    
    func handleToggleTether(event: NSEvent) {
        if self.textState != nil {
            self.setTextState(nil)
            return
        }
        
        guard let selectedTextField = try! self.getSelectedTextField() else {
            return
        }
        
        var roleRef: CFTypeRef? = "HI" as CFString
        AXUIElementCopyAttributeValue(selectedTextField, kAXRoleAttribute as CFString, &roleRef);
        let role = roleRef as! String
        
        print("NICE!! \(selectedTextField)")
        print("Nice bro \(role)")
        
        guard let textElementRole = TextElementRole.fromString(role) else {
            print("Not textbox thingy")
            return
        }
        
        var textState = TextState(element: selectedTextField, role: textElementRole)
        self.setTextState(textState)
        let _ = try! self.textState?.getSelectedText()
        let _ = try! self.textState?.getVisibleCharacters()
        print("It is indeed a text box thingy")
        
        self.position = try! self.textState!.element.get(.position)!;
        self.size = try! self.textState!.element.get(.size)!;
        
        print("Pos=\(position) Size=\(size)")
    }
    
    
    func handleMouseMovement(event: NSEvent) {
        let screenPoint = event.locationInWindow
        
        //        print("NICE \(screenPoint)")
        // Get the accessibility element at the mouse position
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(screenPoint.x), Float(screenPoint.y), &element)
        
        if status == .success, let targetElement = element {
            // Perform actions on the selected element
            // For example, you can retrieve its attributes or modify its properties
            //            print("Selected element: \(targetElement)")
        }
    }
    
    
    //    func getSelectedTextField() -> AXUIElement? {
    //        let systemWideElement = AXUIElementCreateSystemWide()
    //
    //        var focusedElement: CFTypeRef?
    //        AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    //
    //
    //        var elementType: AnyObject?
    //        if AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXRoleAttribute as CFString, &elementType) == .success,
    //           (elementType as? String == kAXTextFieldRole || elementType as? String == kAXTextAreaRole) {
    //            return (focusedElement as! AXUIElement)
    //        }
    //
    //        return nil
    //    }
    
    func getSelectedTextField() throws -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        
        print("Trying to get focused UI element")
        guard let focusedElement: AXUIElement = try systemWideElement.get(.focusedUIElement) else {
            return nil
        }
        
        guard let role: String = try focusedElement.get(.role) else {
            return nil
        }
        
        print("ROLE \(role)")
        if role == kAXTextFieldRole || role == kAXTextAreaRole {
            return focusedElement
        }
        
        return nil
    }
}
