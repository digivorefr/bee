# Changelog

What changed in each version of Bee, newest first. The first version listed is the version the application is built as, and Bee shows this file under Help › What's New in Bee.

## 1.3.0 — 2026-11-26

### Added

- Collections and environments can be sorted by name, A to Z or Z to A, from the menu beside the + of their heading, which then reads A–Z or Z–A. A collection or an environment added or renamed takes its place by name.
- Drag a collection or an environment onto another to move it there: a line of honey shows where it would land, and the others move aside once it is dropped. Move Up and Move Down in its menu do the same. A list sorted by name then keeps the order you give it from what you see; the order you arrange is kept when you sort by name and comes back with Manual.
- Requests and folders are ordered in their collection the same way: dragged, one lands before or after the row under the pointer (by its upper or lower half), or into a folder dropped in its middle; Move Up and Move Down in its menu move it among what holds it. Collection files keep that order.
- What a collection holds can be sorted by name too, folders first, from the menu that comes up on its row under the pointer (or Sort Requests in its menu); the row then reads A–Z or Z–A. Sorting changes what Bee shows, not the collection file; moving one of its requests by hand gives the collection the order shown.

## 1.2.0 — 2026-11-18

### Added

- Forks: try changes on a request of a collection without touching it (Request › Fork). A fork is kept on this Mac only and has a page of its own colour. The parts it has not changed follow the original.
- A fork is merged into its original part by part, with a choice where both changed; it can also be kept as a new request, or discarded. A request can have as many forks as needed.

- Each collection has a file in `~/Documents/Bee`, in Postman's Collection v2.1 format, kept up to date as the collection changes. Send the file as it is; drop one in the folder and its collection appears; edit it elsewhere and Bee takes the change in, says so, and keeps what you changed in Bee meanwhile. Settings › Collections chooses another folder.
- A collection file never holds a secret nor the value of a variable: it holds the names of the variables, and marks where a secret goes. What Bee does not model in a file written by Postman (saved responses, other kinds of authorization, descriptions) is kept as it was.

- AI agents can use Bee through the MCP relay shipped in the application (Settings › Agents, off by default). You choose what they may do (read, send, propose) and in which collections. An agent never gets a secret value; Bee asks you before a program connects for the first time and before each request it sends, and asks again when that request has changed; a change it proposes arrives as a fork for you to merge or discard, which it can send and revise to see what the change returns: Bee then shows you all the fork changes before you agree. A proposal cannot change where a request is sent, nor point it at a secret it does not use already. An agent can send with an environment it names instead of the active one, without ever reading what it holds and without changing the one you work with: the question says which one it is. When you agree, an agent also reads the last response you got for a request without sending it again, and reads a long body piece by piece.

### Fixed

- A GET request sent with a body now says why macOS refuses to send it.
- A secret a server sends back is masked in a response whose text is not UTF-8 too.

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
