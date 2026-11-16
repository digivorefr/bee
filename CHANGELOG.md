# Changelog

What changed in each version of Bee, newest first. The first version listed is the version the application is built as, and Bee shows this file under Help › What's New in Bee.

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
