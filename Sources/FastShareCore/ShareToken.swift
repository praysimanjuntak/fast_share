/// Random identifiers that form the path of a share link.
public enum ShareToken {
    /// Lowercase letters and digits without look-alikes (0/o, 1/i/l), so a link can be typed by hand.
    static let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")
    /// 31^10 ≈ 2^49 possibilities: unguessable for anyone else on the network.
    public static let length = 10

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public static func isWellFormed(_ candidate: some StringProtocol) -> Bool {
        candidate.count == length && candidate.allSatisfy { alphabet.contains($0) }
    }
}
