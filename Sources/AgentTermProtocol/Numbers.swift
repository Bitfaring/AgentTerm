extension Int {
    /// The whole number nearest below `value` that an `Int` holds: the
    /// largest or the smallest one past them, 0 for not a number. For what
    /// is shown of a number a peer sent, which `Int(_:)` would stop the app
    /// on when it is out of range (#296).
    public init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= Double(Int.max) {
            self = .max
        } else if value <= Double(Int.min) {
            self = .min
        } else {
            self = Int(value)
        }
    }
}
