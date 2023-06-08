//
//  AX.swift
//  tether
//
//  Created by Zack Radisic on 29/05/2023.
//

import Foundation
import Accessibility
import Cocoa

public extension AXUIElement {
    func get<Value>(_ attribute: AXAttribute, logErrors: Bool = true) throws -> Value? {
        precondition(Thread.isMainThread)
        var value: AnyObject?
        let code = AXUIElementCopyAttributeValue(self, attribute.rawValue as CFString, &value)
        if let error = AXError(code: code) {
            switch error {
            case .attributeUnsupported, .noValue, .cannotComplete:
                return nil
            default:
//                if logErrors {
//                    axLogger?.e(error, "get(\(attribute))")
//                }
                throw error
            }
        }
        return try unpack(value!) as? Value
    }
    
    private func unpack(_ value: AnyObject) throws -> Any {
        switch CFGetTypeID(value) {
        case AXUIElementGetTypeID():
            return value as! AXUIElement
        case CFArrayGetTypeID():
            return try (value as! [AnyObject]).map(unpack)
        case AXValueGetTypeID():
            return unpackValue(value as! AXValue)
        default:
            return value
        }
    }

    private func unpackValue(_ value: AXValue) -> Any {
        func getValue<Value>(_ value: AnyObject, type: AXValueType, in result: inout Value) {
            let success = AXValueGetValue(value as! AXValue, type, &result)
            assert(success)
        }

        let type = AXValueGetType(value)
        switch type {
        case .cgPoint:
            var result: CGPoint = .zero
            getValue(value, type: .cgPoint, in: &result)
            return result
        case .cgSize:
            var result: CGSize = .zero
            getValue(value, type: .cgSize, in: &result)
            return result
        case .cgRect:
            var result: CGRect = .zero
            getValue(value, type: .cgRect, in: &result)
            return result
        case .cfRange:
            var result: CFRange = .init()
            getValue(value, type: .cfRange, in: &result)
            return result
        case .axError:
            var result: ApplicationServices.AXError = .success
            getValue(value, type: .axError, in: &result)
            return AXError(code: result) as Any
        case .illegal:
            return value
        @unknown default:
            return value
        }
    }

}
