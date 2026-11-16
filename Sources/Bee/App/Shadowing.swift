import SwiftUI

// Two names need help in this module.
//
// `@State`: the macOS 27 SDK declares it both as a property wrapper and as a macro, and the macro's
// compiler plugin ships only with Xcode. Bee builds with the Command Line Tools alone, so views use
// `@ViewState`, an alias of the property wrapper that the macro lookup cannot see. Never write `@State`.
//
// `@Environment`: BeeCore has its own `Environment` model. Declaring the name here makes the SwiftUI
// property wrapper win unqualified lookup; the model is spelled `BeeCore.Environment`.
typealias ViewState<Value> = SwiftUI.State<Value>
typealias Environment<Value> = SwiftUI.Environment<Value>
