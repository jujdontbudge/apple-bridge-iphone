import Foundation

@main
enum BogoReviewExactKeyProof {
    static func main() {
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        func string(_ value: String) -> Data {
            u32(UInt32(value.utf8.count)) + Data(value.utf8)
        }
        func number(_ value: String) -> Data { Data([3]) + string(value) }
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"
        let arguments = Data([6]) + u32(2)
            + string(decomposed) + number("50000")
            + string(composed) + number("500")
        let hint = u32(1) + Data([0]) + string(composed) + Data([1]) + string("USD")
        var bytes = Data(RequestBytes.magic) + Data([0, 1])
        bytes += Data([1]) + u32(32) + Data(repeating: 1, count: 32)
        bytes += Data([2]) + string("stripe")
        bytes += Data([3]) + string("payment")
        bytes += Data([4, 1]) + arguments
        bytes += Data([5, 1]) + string("$5")
        bytes += Data([6]) + u32(1) + hint
        bytes += Data([7]) + u32(32) + Data(repeating: 2, count: 32)
        bytes += Data([8]) + string("Trip planner")
        bytes += Data([9, 0, 10]) + u32(64) + Data(repeating: 3, count: 64)
        bytes += Data([11]) + u32(40) + Data(repeating: 4, count: 40)
        bytes += Data([12]) + Data(repeating: 0, count: 8) + Data([13, 0])
        guard let request = RequestBytes.decode(bytes),
              case .money(let amount, _) = Review(request).highlights.first?.value else {
            fatalError("Fixture must decode and produce a money highlight")
        }
        guard amount.formatted == "$5.00" else {
            print("FAIL S1: hint for UTF-8 c3a9 should show $5.00; got \(amount.formatted)")
            exit(1)
        }
    }
}
