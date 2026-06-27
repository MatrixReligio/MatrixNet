import SwiftUI

extension View {
    /// Persists a `Table`'s user column customization — width, order and
    /// visibility — across launches, stored under `key` in `UserDefaults`.
    /// Columns must each carry a stable `.customizationID(_:)` for this to apply.
    func persistTableColumns<Row>(
        _ customization: Binding<TableColumnCustomization<Row>>,
        key: String
    ) -> some View {
        onAppear {
            if let data = UserDefaults.standard.data(forKey: key),
               let decoded = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data) {
                customization.wrappedValue = decoded
            }
        }
        .onChange(of: customization.wrappedValue) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
