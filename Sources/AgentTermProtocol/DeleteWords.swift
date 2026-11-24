/// The questions both apps ask before what cannot be undone with one click
/// (#308, the owner's decision of 2026-11-23, principle 2): deleting a
/// schedule, removing a paired device.
public enum DeleteWords {
    public static func scheduleTitle(_ name: String) -> String { "Delete the schedule “\(name)”?" }
    public static let scheduleMessage = "Its runs and the changes made to it go with it, on every device. This cannot be undone."
    public static let deleteSchedule = "Delete Schedule"

    public static func deviceTitle(_ name: String) -> String { "Remove “\(name)”?" }
    public static let deviceMessage = "It can no longer reach this Mac, and has to be paired again to come back."
    public static let removeDevice = "Remove"
}
