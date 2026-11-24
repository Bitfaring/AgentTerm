#if os(macOS)
import Foundation

extension Data {
    /// Writes as `.atomic` does, to the file a symbolic link names rather
    /// than over the link (#263): the user's configuration or file kept as a
    /// link into another folder (dotfiles) stays a link, and what it names
    /// is what changes. An atomic write puts a new file in the place of
    /// what it is given, which for a link is the link itself (macOS 27.2.1).
    func writeKeepingLinks(to file: URL) throws {
        try write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
#endif
