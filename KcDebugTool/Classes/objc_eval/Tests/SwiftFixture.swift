// Pure Swift fixture: neither the class nor its members are marked @objc.
public final class KCSwiftNativeFixture {
    public let factor: Int
    public init(factor: Int) { self.factor = factor }
    public static func add(_ a: Int, b: Int) -> Int { a + b }
    public static var count: Int { 7 }
    public static func make() -> KCSwiftNativeFixture { KCSwiftNativeFixture(factor: 3) }
    public func multiply(_ value: Int) -> Int { factor * value }
    public static func greet(_ name: String) -> String { "Hello, " + name }
    public func echo(_ value: String) -> String { value }
}
