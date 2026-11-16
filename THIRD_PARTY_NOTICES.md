# Third-party notices

AgentTerm is released under the [MIT License](LICENSE). It is built with the
open source software below, each under its own license. The versions are the
ones `Package.resolved` pins.

## Swift packages

| Package | Used for | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | The terminal emulator | MIT |
| [Highlightr](https://github.com/raspu/Highlightr) | Syntax coloring in the editor and in previews | MIT |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | The Markdown preview | MIT |
| [NetworkImage](https://github.com/gonzalezreal/NetworkImage) | Pictures in the Markdown preview; a dependency of swift-markdown-ui | MIT |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | Markdown parsing; a dependency of swift-markdown-ui | BSD 2-Clause, with parts under MIT and other permissive licenses listed in its `COPYING` |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | A dependency of SwiftTerm's tools | Apache 2.0 |
| [swift-png](https://github.com/tayloraswift/swift-png) and [h](https://github.com/rarestype/h) | Dependencies of SwiftTerm | Apache 2.0 |

The released apps also link [Firebase](https://github.com/firebase/firebase-ios-sdk)
(Analytics and Crashlytics, Apache 2.0) and the libraries it brings with it,
each under the license in its own repository: GoogleAppMeasurement,
GoogleUtilities, GoogleDataTransport, nanopb (zlib license), Promises and
others listed in `Package.resolved`.

## Bundled files

| File | What | License |
|---|---|---|
| `highlight.js`, inside Highlightr | [highlight.js](https://highlightjs.org), the syntax highlighter Highlightr runs | BSD 3-Clause |
| `Sources/AgentTermEditor/Resources/mermaid.min.js` | [Mermaid](https://github.com/mermaid-js/mermaid) 11.4.1, draws diagrams from text; the unmodified build | MIT |

## The browser (Mac app)

The Mac app ships the [Chromium Embedded Framework](https://github.com/chromiumembedded/cef)
(CEF) 156.0.30, built on [Chromium](https://www.chromium.org) 156.0.8078.96,
for its browser (#76). Nothing of it is kept in this repository:
`scripts/fetch-cef.sh` fetches the binary distribution, pinned with its
checksum, from `cef-builds.spotifycdn.com`.

| Part | License |
|---|---|
| CEF: its framework, headers and helper code | BSD 3-Clause (`LICENSE.txt` of the distribution) |
| Chromium and the software it includes | BSD 3-Clause, with parts under other licenses, each listed in Chromium's own credits, which the browser shows at `about:credits` |

The full text of each license is in that project's repository, at the links
above.
