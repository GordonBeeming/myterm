# Browser engines

MyTerm ships with one browser engine: WebKit. It is built into macOS, supports native website data stores, and keeps the main app small. Chromium is intentionally not bundled with the app.

`BrowserSessionFactory` is the construction boundary between the app model and the current WebKit implementation. A future engine package can use the same `BrowserDataProfile` identity, so the user's app-wide, workspace, and project-folder choices remain consistent across engines.

## Optional Chromium package

The intended distribution is a separate **MyTerm Chromium Engine** download, based on CEF. It should be installed only when a user chooses Chromium and removed without affecting the main app.

Before that package can ship, the browser controller and view need a type-erased runtime contract covering navigation state, the hosted AppKit view, lifecycle, and website-data profiles. The package loader must then enforce:

- a versioned manifest and browser-runtime API version;
- a compatible MyTerm version and architecture;
- a matching Apple Developer Team identifier;
- hardened-runtime signing and notarization;
- an integrity check before loading; and
- installation under MyTerm's Application Support directory, never inside the app bundle.

MyTerm should keep library validation enabled. The optional engine and its helper processes must be signed by the same team as MyTerm rather than weakening the host app's runtime protections.

The first release does not include a placeholder downloader or an unsigned plug-in loader. Those add security and maintenance cost without delivering a usable second engine.
