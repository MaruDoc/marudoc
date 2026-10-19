# Security

## Reporting a problem

Please do not open a public issue for a security problem.

- Email support@marudoc.app with what you found and how to reproduce it.
- Or use GitHub private vulnerability reporting on this repository (Security tab, "Report a vulnerability").

Include the MaruDoc version, the macOS version, and a sample file if the problem is triggered by one. You will get a reply within a few days. Because MaruDoc has no auto-update, a fix is released as a new version on https://marudoc.app and users have to install it again.

## What has been checked

The full questions and answers are in [docs/08_セキュリティQ&A.md](docs/08_セキュリティQ&A.md) (Japanese). In short:

- There is no network code. The source uses no URLSession, Network, WebKit or socket APIs and no third-party libraries. The self-test passes with network access denied by the kernel sandbox, and the running app has no open network sockets.
- Parsers for ZIP, Office XML and PDF are written in Swift with limits on sizes and numeric ranges. External XML references are disabled and DOCTYPE in Office parts is rejected.
- The Finder extension and the app talk over a `marudoc://` URL with a one-time token. A request without the token shows a confirmation dialog with the full path and action.
- The release build is signed with Hardened Runtime and notarized.
- An automated multi-agent scan and two re-checks were done. No external human audit has been done.

Known limits: the direct-download build is not sandboxed, so the lack of network access is a property of the code and not enforced by macOS. The Mac App Store build is sandboxed and has no network entitlement.
