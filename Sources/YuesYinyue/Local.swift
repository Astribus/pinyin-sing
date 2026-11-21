import SwiftUI

/// Stand-in for SwiftUI's `@State`. In the macOS 27 SDK `@State` is a macro whose
/// plugin only ships with full Xcode, and this project builds with the Command Line
/// Tools alone. `@StateObject` is not a macro, so we keep view state in one of those.
@propertyWrapper
struct Local<T>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: T
        init(_ v: T) { value = v }
    }

    @StateObject private var box: Box

    init(wrappedValue: T) { _box = StateObject(wrappedValue: Box(wrappedValue)) }

    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<T> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
