import Foundation

enum WeatherFailure: Error, Equatable, LocalizedError {
    case offline
    case http(Int)
    case invalidResponse
    case service(domain: String, code: Int)

    init(error: Error) {
        if let failure = error as? WeatherFailure { self = failure; return }
        if error is DecodingError { self = .invalidResponse; return }
        let error = error as NSError
        let connectionCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed]
        if error.domain == NSURLErrorDomain && connectionCodes.contains(error.code) { self = .offline }
        else { self = .service(domain: error.domain, code: error.code) }
    }

    var title: String {
        switch self {
        case .offline: "Weather Connection Unavailable"
        case .http(429): "Weather Request Limit Reached"
        default: "Weather Temporarily Unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .offline: "Check your internet connection. Keeping the last saved conditions until updates resume."
        case .http(429): "Open-Meteo has temporarily limited requests. Automatic updates will resume later."
        case .invalidResponse: "The weather service returned incomplete or unexpected data. Keeping the last saved conditions."
        default: "Open-Meteo couldn't complete this request. Keeping the last saved conditions and retrying later."
        }
    }

    var diagnostics: String {
        switch self {
        case .offline: "URL loading failed. No account, API key or developer team is required."
        case let .http(status): "Open-Meteo HTTP status: \(status)"
        case .invalidResponse: "Open-Meteo response validation failed."
        case let .service(domain, code): "Service error: \(domain), code \(code)"
        }
    }
}
