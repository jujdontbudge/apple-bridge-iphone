import Foundation

@main
enum BogoReasonPictureProof {
    static func main() {
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        func string(_ value: String) -> Data {
            u32(UInt32(value.utf8.count)) + Data(value.utf8)
        }
        let link = "https://example.com/cube.png"
        let reason = "Buy this cube. Picture: `\(link)`"
        var bytes = Data(RequestBytes.magic) + Data([0, 1])
        bytes += Data([1]) + u32(32) + Data(repeating: 1, count: 32)
        bytes += Data([2]) + string("shop")
        bytes += Data([3]) + string("buy")
        bytes += Data([4, 0])
        bytes += Data([5, 1]) + string(reason)
        bytes += Data([6]) + u32(0)
        bytes += Data([7]) + u32(32) + Data(repeating: 2, count: 32)
        bytes += Data([8]) + string("Shopping agent")
        bytes += Data([9, 0, 10]) + u32(64) + Data(repeating: 3, count: 64)
        bytes += Data([11]) + u32(40) + Data(repeating: 4, count: 40)
        bytes += Data([12]) + Data(repeating: 0, count: 8) + Data([13, 0])
        guard let request = RequestBytes.decode(bytes) else {
            fatalError("Fixture must decode")
        }
        let pictures = Review(request).reasonPictures
        guard pictures == [link] else {
            print("FAIL S1: expected reason picture \(link); got \(pictures)")
            exit(1)
        }
        print("PASS S1")
    }
}
