// DomainConfig.swift
enum DomainConfig {
    static let base = "https://deeplinkly.com"
    static let enrich = "\(base)/api/v1/enrich"
    static let logEvent = "\(base)/api/v1/log-event"
    static let sdkError = "\(base)/api/v1/sdk-error"
    static let resolveClick = "\(base)/api/v1/resolve"
    static let generateLink = "\(base)/api/v1/generate-url"
}
