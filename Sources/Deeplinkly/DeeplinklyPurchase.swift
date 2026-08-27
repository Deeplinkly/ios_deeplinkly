// DeeplinklyPurchase.swift
import Foundation

/// The parameter contract behind `Deeplinkly.logPurchase`.
///
/// A port of Android's `DeeplinklyPurchase`, deliberately kept close enough to
/// read side by side. Split out of `Deeplinkly` for the same reason
/// `DeeplinklyEvent` was: the rules have to be identical for a native caller
/// and a Flutter or React Native one, and the only way to guarantee that is for
/// all four to reach the same code rather than each re-implementing it a layer
/// up.
///
/// The keys here are reserved but *not* `_dl_`-prefixed, and that is
/// deliberate. A prefixed key is hidden from the tenant's dashboard and exempt
/// from the parameter budget, which is right for the SDK's own bookkeeping and
/// wrong for revenue: the amount of a sale is the first thing someone reading
/// their own purchase events wants to see. They cost a parameter each and they
/// show up, like any other parameter — the backend simply also lifts `value`
/// and `currency` into typed columns on the way in.
enum DeeplinklyPurchase {

    /// Meta's standard event is `Purchase` and Google's is `purchase`.
    /// Lowercase here; a forwarder maps to each destination's spelling.
    static let eventName = "purchase"

    static let keyValue = "value"
    static let keyCurrency = "currency"
    static let keyOrderId = "order_id"
    static let keyQuantity = "quantity"
    static let keyProductId = "product_id"

    /// Keys `build` writes, which a caller's own parameters may not collide
    /// with.
    static let reservedKeys: Set<String> = [
        keyValue, keyCurrency, keyOrderId, keyQuantity, keyProductId,
    ]

    /// Why a purchase was rejected. Surfaced only in debug logs.
    struct Rejection: Equatable {
        let reason: String
    }

    /// Either the assembled parameters or the reason there are none.
    struct Result {
        let parameters: [String: Any]?
        let rejection: Rejection?
    }

    static func build(
        value: Double,
        currency: String,
        orderId: String? = nil,
        quantity: Int? = nil,
        productId: String? = nil,
        parameters: [String: Any] = [:]
    ) -> Result {
        if value.isNaN || value.isInfinite {
            return Result(parameters: nil, rejection: Rejection(reason: "value must be a finite number"))
        }
        // Zero is allowed — a free trial conversion is worth reporting — but
        // negative is not. A refund is a different event, and sending it as a
        // purchase would net it off the campaign's revenue in a way no
        // destination expects.
        if value < 0 {
            return Result(
                parameters: nil,
                rejection: Rejection(reason: "value must not be negative; got \(value)"))
        }

        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return Result(
                parameters: nil,
                rejection: Rejection(
                    reason: "currency must be a 3-letter ISO-4217 code; got \"\(currency)\""))
        }

        if let quantity, quantity < 0 {
            return Result(
                parameters: nil,
                rejection: Rejection(reason: "quantity must not be negative; got \(quantity)"))
        }

        let collisions = parameters.keys
            .filter { reservedKeys.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted()
        if !collisions.isEmpty {
            return Result(
                parameters: nil,
                rejection: Rejection(
                    reason: "parameters may not contain \(collisions.joined(separator: ", ")); "
                        + "pass them as arguments instead"))
        }

        var out = parameters
        out[keyValue] = value
        out[keyCurrency] = code.uppercased()
        if let orderId = orderId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !orderId.isEmpty
        {
            out[keyOrderId] = orderId
        }
        if let quantity { out[keyQuantity] = quantity }
        if let productId = productId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !productId.isEmpty
        {
            out[keyProductId] = productId
        }
        return Result(parameters: out, rejection: nil)
    }
}
