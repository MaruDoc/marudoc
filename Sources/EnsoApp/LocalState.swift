import SwiftUI

/// Stand-in for SwiftUI's `@State`. In the macOS 27 SDK `@State` is a macro whose plugin ships only with Xcode,
/// and MaruDoc builds with the Command Line Tools, so view-local state goes through a StateObject box instead.
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

@propertyWrapper
struct LocalState<T>: DynamicProperty {
    @StateObject private var box: StateBox<T>

    init(wrappedValue: T) { _box = StateObject(wrappedValue: StateBox(wrappedValue)) }

    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<T> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
