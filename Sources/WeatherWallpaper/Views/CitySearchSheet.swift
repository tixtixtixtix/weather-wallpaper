import SwiftUI
import WeatherCore

struct CitySearchSheet: View {
    var onSelect: (City) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = CitySearchModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(search.results) { result in
                    Button {
                        Task {
                            if let city = await search.resolve(result) { onSelect(city); dismiss() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name).font(.headline)
                            Text(result.region).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(search.isResolving)
                }
            }
            .overlay {
                if search.isSearching || search.isResolving { ProgressView() }
                else if let message = search.message {
                    ContentUnavailableView("City Search Unavailable", systemImage: "magnifyingglass", description: Text(message))
                } else if search.results.isEmpty {
                    ContentUnavailableView("Find a City", systemImage: "globe", description: Text("Search by city and country. No location permission is needed."))
                }
            }
            .searchable(text: $search.query, prompt: "City or City, Country")
            .navigationTitle("Choose City")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Search uses Apple Maps. Only the selected city is saved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
        .frame(width: 480, height: 440)
        .onDisappear { search.cancel() }
    }
}
