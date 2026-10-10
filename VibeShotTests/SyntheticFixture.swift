import Foundation

enum SyntheticFixture {
    /// Privacy-safe RGB grid generated in memory; it never reads screen pixels.
    static func colorGrid(width: Int, height: Int) -> Data {
        precondition(width >= 0 && height >= 0)
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 3)

        for y in 0..<height {
            for x in 0..<width {
                bytes.append(UInt8((x * 37) % 256))
                bytes.append(UInt8((y * 53) % 256))
                bytes.append(UInt8(((x + y) * 29) % 256))
            }
        }
        return Data(bytes)
    }
}

