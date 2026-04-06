//
//  PTYWriter.swift
//  ClaudeIsland
//
//  Sends text to non-tmux terminals by switching to the correct tab
//  and injecting keystrokes via osascript
//

import Foundation
import os.log

/// Sends text to non-tmux terminal sessions.
/// Finds the correct terminal window/tab, switches to it, and types the message.
/// Requires Accessibility permission.
actor PTYWriter {
    static let shared = PTYWriter()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "PTYWriter")

    private init() {}

    /// Send a message to the terminal running a Claude session.
    /// - Parameters:
    ///   - message: The text to send
    ///   - tty: The TTY name, e.g. "ttys009"
    ///   - projectName: The project/directory name to match the tab title
    /// - Returns: true if the keystrokes were sent
    func sendMessage(_ message: String, toTTY tty: String, projectName: String) async -> Bool {
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")

        guard let terminalInfo = Self.findTerminalForTTY(ttyShort) else {
            Self.logger.error("Could not find terminal app for TTY \(ttyShort, privacy: .public)")
            return false
        }

        Self.logger.debug("Found terminal '\(terminalInfo.appName, privacy: .public)' for TTY \(ttyShort, privacy: .public)")

        let escapedProject = projectName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Use clipboard to paste text (supports CJK and special characters)
        let script = """
        set the clipboard to "\(Self.escapeForAppleScript(message))"

        tell application "\(terminalInfo.appName)" to activate
        delay 0.2

        tell application "System Events"
            tell process "\(terminalInfo.appName)"
                try
                    tell window 1
                        tell tab group 1
                            set tabButtons to every radio button
                            repeat with t in tabButtons
                                if name of t contains "\(escapedProject)" then
                                    click t
                                    delay 0.1
                                    exit repeat
                                end if
                            end repeat
                        end tell
                    end tell
                end try
            end tell

            keystroke "v" using command down
            delay 0.3
            keystroke return
        end tell
        """

        Self.logger.debug("Executing osascript for project '\(projectName, privacy: .public)'")

        // Use osascript process instead of NSAppleScript to avoid main thread / sandbox issues
        do {
            let output = try await ProcessExecutor.shared.run("/usr/bin/osascript", arguments: ["-e", script])
            Self.logger.debug("osascript output: \(output, privacy: .public)")
            return true
        } catch {
            Self.logger.error("osascript failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private struct TerminalInfo {
        let pid: Int
        let appName: String
    }

    /// Find the terminal app name and PID for a given TTY
    private nonisolated static func findTerminalForTTY(_ tty: String) -> TerminalInfo? {
        let builder = ProcessTreeBuilder.shared
        let tree = builder.buildTree()

        for (_, info) in tree {
            if info.tty == tty {
                if let termPid = builder.findTerminalPid(forProcess: info.pid, tree: tree),
                   let termInfo = tree[termPid] {
                    let appName = extractAppName(from: termInfo.command)
                    return TerminalInfo(pid: termPid, appName: appName)
                }
            }
        }
        return nil
    }

    /// Escape a string for embedding in AppleScript double-quoted string
    private nonisolated static func escapeForAppleScript(_ str: String) -> String {
        str .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Extract display name from a command path
    /// e.g. "/Applications/Ghostty.app/Contents/MacOS/ghostty" → "Ghostty"
    private nonisolated static func extractAppName(from command: String) -> String {
        if let range = command.range(of: #"/([\w\s]+)\.app/"#, options: .regularExpression) {
            let match = command[range]
            let name = match.dropFirst(1).dropLast(5)
            return String(name)
        }
        let lastComponent = (command as NSString).lastPathComponent
        return lastComponent.prefix(1).uppercased() + lastComponent.dropFirst()
    }
}
