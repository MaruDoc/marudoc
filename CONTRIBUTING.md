# Contributing

Issues and pull requests are welcome. Japanese or English is fine.

Before sending a pull request:

1. Build with `swift build` (Command Line Tools are enough, Xcode is not required).
2. Run `swift run ensocli selftest /tmp/marudoc-selftest` and make sure every check passes. If you change a converter or editor, add a check for it in `Sources/ensocli/SelfTest.swift`.
3. Keep the change small and say what it fixes or adds.

MaruDoc works entirely offline. Code that talks to the network (URLSession, sockets, WebKit, analytics, update checks) will not be accepted, however small. System frameworks that ship with macOS are fine; new third-party dependencies are not, unless there is a strong reason.

For a security problem, do not open a public issue. See SECURITY.md.
