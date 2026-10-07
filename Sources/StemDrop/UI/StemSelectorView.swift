import SwiftUI

/// Model stems plus optional frequency-isolated drum detail stems, bound to
/// the remembered selection.
struct StemSelectorView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(StemType.allCases, id: \.self) { stem in
                Toggle(stem.displayName, isOn: binding(for: stem))
                    .toggleStyle(.checkbox)
            }
            Text("Instrumental is the full track with the vocals removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Text("Kick, Snare, and Cymbals are frequency-isolated from the Drums stem.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .borderedBox()
    }

    private func binding(for stem: StemType) -> Binding<Bool> {
        Binding(
            get: { prefs.selectedStems.contains(stem) },
            set: { isOn in
                if isOn {
                    prefs.selectedStems.insert(stem)
                } else {
                    prefs.selectedStems.remove(stem)
                }
            }
        )
    }
}
