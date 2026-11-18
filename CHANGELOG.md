# Changelog

What changed in each version of Bee, newest first. The first version listed is the version the application is built as, and Bee shows this file under Help › What's New in Bee.

## 1.2.0 — 2026-11-18

### Added

- Forks: try changes on a request of a collection without touching it (Request › Fork). A fork is kept on this Mac only and has a page of its own colour. The parts it has not changed follow the original.
- A fork is merged into its original part by part, with a choice where both changed; it can also be kept as a new request, or discarded. A request can have as many forks as needed.

- Each collection has a file in `~/Documents/Bee`, in Postman's Collection v2.1 format, kept up to date as the collection changes. Send the file as it is; drop one in the folder and its collection appears; edit it elsewhere and Bee takes the change in. Settings › Collections chooses another folder.
- A collection file never holds a secret nor the value of a variable: it holds the names of the variables, and marks where a secret goes. What Bee does not model in a file written by Postman (saved responses, other kinds of authorization, descriptions) is kept as it was.

### Fixed

- A GET request sent with a body now says why macOS refuses to send it.

## 1.1.0 — 2026-11-18

### Added

- Bee asks GitHub once a day whether a newer version is published, and says so when there is one. Bee › Check for Updates… asks at once; Settings › Updates turns the daily question off.
- A release signed by the publisher is installed by Bee itself: it downloads the new version, checks its signature, takes its place and restarts.

### Fixed

- A body or script editor no longer jumps between two heights when scroll bars are always shown, as they are with a mouse connected.

## 1.0.0 — 2026-11-16

First public release.

### Requests

- A request reads as one document in wire order: path variables, parameters, authorization, headers, body, scripts, settings. Its response is the facing page.
- Bodies: JSON and other raw text, URL-encoded and multipart forms, a file, GraphQL.
- Authorization by bearer token, basic credentials or API key, set on a request or inherited from its folder or collection.
- Paste a cURL command in the URL field to fill a request; copy any request as cURL.
- Collections and folders, one-off requests kept outside any collection, and a history of what was sent.

### Variables

- `{{name}}` is replaced by the variable of that name: the active environment first, then the collection, then the globals.
- A path segment written `:name` is a path variable. Its value is set on the request and may use variables; left empty, it takes the variable of the same name.
- Built-in values: `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`.

### Scripts

- Pre-request and post-response scripts in JavaScript, on a request, a folder or a collection.
- The `bee` object (alias `pm` for Postman scripts) reads and writes variables, rewrites the request, reads the response, records tests and sends other requests.

### Secrets

- Secret values are kept in an encrypted vault whose key is in the login Keychain; no file, export, history entry or cURL command holds one.
- A secret is masked wherever it is shown; revealing or copying it asks for Touch ID or the account password.

### Import and export

- Import Postman collections (v2.0 and v2.1) and environments.
- Export a collection or an environment as a Bee archive, without its secret values.
