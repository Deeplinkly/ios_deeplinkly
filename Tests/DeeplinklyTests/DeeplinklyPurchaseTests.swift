import XCTest

@testable import Deeplinkly

final class DeeplinklyPurchaseTests: XCTestCase {

    private func build(
        value: Double = 49.99,
        currency: String = "usd",
        orderId: String? = nil,
        quantity: Int? = nil,
        productId: String? = nil,
        parameters: [String: Any] = [:]
    ) -> DeeplinklyPurchase.Result {
        DeeplinklyPurchase.build(
            value: value, currency: currency, orderId: orderId,
            quantity: quantity, productId: productId, parameters: parameters)
    }

    func testUppercasesTheCurrencyAndKeepsTheValueANumber() {
        let result = build()
        XCTAssertNil(result.rejection)
        XCTAssertEqual(result.parameters?[DeeplinklyPurchase.keyCurrency] as? String, "USD")
        // Not "49.99". The service stores this as a Decimal, and a value that
        // arrives as a string is one the JSON has already made ambiguous.
        XCTAssertEqual(result.parameters?[DeeplinklyPurchase.keyValue] as? Double, 49.99)
    }

    func testOmitsTheOptionalFieldsThatWereNotSupplied() {
        let params = build().parameters ?? [:]
        XCTAssertNil(params[DeeplinklyPurchase.keyOrderId])
        XCTAssertNil(params[DeeplinklyPurchase.keyQuantity])
        XCTAssertNil(params[DeeplinklyPurchase.keyProductId])
    }

    func testCarriesTheCallersOwnParametersThrough() {
        let params = build(parameters: ["coupon": "SPRING"]).parameters ?? [:]
        XCTAssertEqual(params["coupon"] as? String, "SPRING")
        XCTAssertEqual(params[DeeplinklyPurchase.keyCurrency] as? String, "USD")
    }

    /// Zero is a real conversion — a free trial that converted.
    func testAcceptsAZeroValue() {
        XCTAssertNil(build(value: 0).rejection)
    }

    /// A refund is a different event. Sent as a purchase it would net off the
    /// campaign's revenue, which is not what any destination does with it.
    func testRejectsANegativeValue() {
        XCTAssertNotNil(build(value: -1).rejection)
    }

    func testRejectsAValueThatIsNotFinite() {
        XCTAssertNotNil(build(value: .nan).rejection)
        XCTAssertNotNil(build(value: .infinity).rejection)
    }

    func testRejectsACurrencyThatIsNotThreeLetters() {
        XCTAssertNotNil(build(currency: "US").rejection)
        XCTAssertNotNil(build(currency: "US$").rejection)
        XCTAssertNotNil(build(currency: "").rejection)
    }

    func testRejectsANegativeQuantity() {
        XCTAssertNotNil(build(quantity: -1).rejection)
    }

    /// Silently letting the caller's map win would send a purchase whose value
    /// is not the value they passed; silently overwriting it would discard data
    /// they meant to keep. Neither is recoverable, so the call is refused.
    func testRejectsACallerParameterThatCollidesWithAReservedKey() {
        let result = build(parameters: ["value": 1.0])
        XCTAssertNotNil(result.rejection)
        XCTAssertNil(result.parameters)
    }

    /// What every event this produces is named, on both platforms.
    func testIsNamedPurchase() {
        XCTAssertEqual(DeeplinklyPurchase.eventName, "purchase")
    }
}
