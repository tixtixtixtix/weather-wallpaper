import Combine
import CoreLocation
import MapKit
import WeatherCore

struct CitySearchResult: Identifiable {
    let item: MKMapItem
    var id: String { "\(item.placemark.coordinate.latitude),\(item.placemark.coordinate.longitude)" }
    var name: String { item.placemark.locality ?? item.name ?? "Unnamed city" }
    var region: String {
        [item.placemark.administrativeArea, item.placemark.country]
            .compactMap { $0 }.filter { $0 != name }.joined(separator: ", ")
    }
}

@MainActor
final class CitySearchModel: ObservableObject {
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published private(set) var results: [CitySearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isResolving = false
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?
    private var search: MKLocalSearch?
    private let geocoder = CLGeocoder()

    private func scheduleSearch() {
        task?.cancel()
        search?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        message = nil
        guard text.count >= 2 else { isSearching = false; return }
        isSearching = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = text
                request.resultTypes = .address
                let search = MKLocalSearch(request: request)
                self.search = search
                let response = try await search.start()
                try Task.checkCancellation()
                var seen = Set<String>()
                self.results = response.mapItems.compactMap { item in
                    let result = CitySearchResult(item: item)
                    let key = "\(result.name)|\(result.region)"
                    return seen.insert(key).inserted ? result : nil
                }
                self.message = self.results.isEmpty ? "No cities found. Try adding a country." : nil
                self.isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = "City search is unavailable. Check your internet connection and try again."
                self?.isSearching = false
            }
        }
    }

    func resolve(_ result: CitySearchResult) async -> City? {
        isResolving = true
        defer { isResolving = false }
        let placemark = result.item.placemark
        do {
            var timeZone = placemark.timeZone
            if timeZone == nil {
                let location = CLLocation(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude)
                timeZone = try await geocoder.reverseGeocodeLocation(location).first?.timeZone
            }
            guard let timeZone else {
                message = "Couldn't determine this city's time zone. Try a nearby city."
                return nil
            }
            return City(name: result.name, region: result.region,
                        latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude,
                        timeZoneIdentifier: timeZone.identifier)
        } catch {
            message = "Couldn't look up this city. Please try again."
            return nil
        }
    }

    func cancel() {
        task?.cancel()
        search?.cancel()
        geocoder.cancelGeocode()
    }
}
