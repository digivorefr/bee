# Bee

A native macOS API client: requests, collections, environments, variables, pre-request and post-response scripts, with secrets kept out of every file but an encrypted vault.

Swift 6 · SwiftUI + AppKit · arm64 · macOS 26+ · no third-party dependency.

## Install

Download `Bee-<version>.zip` from the [latest release](https://github.com/digivorefr/bee/releases/latest), open it and move **Bee** to Applications. Bee needs a Mac with Apple silicon and macOS 26 or later.

Bee is not notarized by Apple yet, so macOS refuses to open it the first time: go to **System Settings › Privacy & Security**, scroll down to **Security** and click **Open Anyway**. This is asked once per version downloaded by hand.

From version 1.1.0, Bee updates itself (see [Updates](#updates)).

## Build and run

Only the Command Line Tools are required (no Xcode).

```bash
Scripts/build-app.sh --open
```

The app is written to `dist/Bee.app` (ad-hoc signed). Tests: `swift test`.

## Layout

| Path | Content |
|---|---|
| `Sources/BeeCore` | UI-free core: models, variables, HTTP, scripts (JavaScriptCore), vault, storage, runner |
| `Sources/Bee` | The application: model, design system, features |
| `Sources/BeeMCP` | `bee-mcp`, the relay AI agents start (MCP on stdio) |
| `Tests/BeeCoreTests` | Swift Testing suites for the core |
| `design/language.md` | The design language every screen follows |
| `CHANGELOG.md` | What changed in each version; its first entry is the version of the build, and Bee shows it under Help › What's New in Bee |
| `Scripts/` | `build-app.sh` (bundle), `release.sh` (download archive and GitHub release), `update-key.swift` (release signing key), `version.sh`, `make-icon.swift` (icon) |

## Where data lives

`~/Library/Application Support/Bee/`: `workspace.json`, `collections/`, `environments/`, `history.json`, `settings.json`, `secrets.vault`. The collection files meant to be shared are in `~/Documents/Bee/`.

## Variables

- `{{name}}` anywhere in a request is replaced by the variable of that name: the active environment first, then the collection, then the globals.
- A path segment written `:name` (`/tickets/:ticketId`) is a path variable. Its value is set under **Path variables** and may use `{{variables}}`; left empty, it takes the variable of the same name. The value is percent-encoded as one segment (`a/b` is sent as `a%2Fb`), where a `{{placeholder}}` typed in the URL is pasted as it is.

## Collection files

- Each collection has a file in `~/Documents/Bee` (Settings › Collections chooses another folder), written as a Postman Collection v2.1 document and kept up to date as the collection changes. There is no export step: the file can be sent, committed with the code it describes, or opened in Postman.
- A file dropped in the folder becomes a collection; a file edited elsewhere is read again within two seconds, and Bee says which collection changed. Bee puts a file in its own form when it first reads it: identifiers are added, so that the same file always names the same requests, and secret values are taken out. A file written again by another tool (a Postman export, without identifiers or with its own) still names the requests Bee holds, by their names and places; a request renamed there is a new one. An identifier names one request in all of Bee: a file that repeats one gets a new one.
- What the file holds: the tree, the requests, their scripts, the names of the variables. What it never holds: a secret value (the row is written with an empty value and `"beeSecret": true`) and the value of a variable. Those stay on this Mac: variables in Bee's own store, secrets in the vault. In a file Bee wrote (`"beeSecrets": "marked"` in `info`), only the marked rows are secrets; in a file of another tool, a row named like a credential is taken for one.
- Bee writes only what it changed. A part of a request the file already says, and what Bee does not model (saved responses, an authorization of a kind Bee cannot send, the description of a row), is left as it was written.
- Bee keeps each file as it last wrote or read it (`collection-files.known/` in its data folder). That copy tells a change made in the file from a change made in Bee that has not reached the file yet: only the first is taken in, part by part, folder by folder and variable by variable, so both stand. When both changed the same part of a request, the file wins. What neither side deleted is never lost: a request moved into a folder the other side deleted comes back at the top. Without that copy (another folder is chosen, Bee's data was lost), the file wins where the two differ and nothing held in Bee is removed.
- A file someone changed since Bee last read it is never written over: it is read first. A file that cannot be read is left alone and said once. A file that is deleted is written again; a file renamed by hand keeps its name. A collection is deleted in Bee, and its file then goes to the Trash.
- A collection file is trusted like the code it sits with: it says where requests are sent and which scripts run. Read what changed before sending after someone else's edit.
- While secrets are locked (the Keychain refused the key), the folder is neither read nor written: a secret a file brings would otherwise leave the file without reaching the vault.
- Bee's own copy stays in `~/Library/Application Support/Bee/collections/`; forks are never written to a collection file.

## Agents (MCP)

Bee ships a relay, `Bee.app/Contents/MacOS/bee-mcp`, that an AI agent's program starts to reach Bee over the Model Context Protocol (stdio). For Claude Code:

```bash
claude mcp add bee -- "/Applications/Bee.app/Contents/MacOS/bee-mcp"
```

- Off by default. Settings › Agents turns it on, sets what agents may do (read requests; send one when you agree; propose changes as forks they can send when you agree) and which collections they see. None is open until you pick it.
- The relay holds nothing: it hands each call to the running application over a socket in Bee's data folder, open to your user only. Bee answers only the relay shipped in its own bundle, and asks you the first time a program starts it. A program is its path; an interpreter (node, python, a shell) is the script file it runs, and one started in a way that tells nothing (`-e`, `-c`, options or a subcommand before the script), like the helper that runs every extension of an editor, is allowed until Bee quits at most. A program whose file is gone from the disk is that one process, told by its name, its number and when it started: Bee cannot say where it came from (an update does that to a running program, and a program can do it on purpose), says so, and allowing it lasts until it quits. A program you turn away is not asked about again until agents are turned off and on.
- Tools: `list_collections`, `list_requests`, `get_request`, `list_environments`, `send_request`, `get_response`, `propose_change`.
- What an agent reads is the request as written, in the shape of a collection file: a secret is an empty value marked `beeSecret`, and the values of variables are not given. The forks of a request are listed under it and read the same way, yours as well as those an agent proposed.
- `send_request` sends a request of a collection, or a fork of one, exactly as written, after you allowed it in Bee (once, or until Bee quits). For a fork, the question shows all it changes of its original (address and the values of its path variables, parameters, headers, body) and names the variables it uses that the original does not. What someone else wrote is shown as such: on one line, a line break or a character that hides or reorders text made visible, each line of a body set in under a heading of Bee's, a long text said to be cut before the part that is shown. The question says where the address leads with the variables as they are, what the request carries and whether scripts run with it. What you allow is that request, with what it takes from its folders and collection, its secrets, the active environment and that destination: if any of it changes, even while the question is on screen, Bee asks again and says it changed. No key answers yes, and a question that has just come up takes no answer for a moment, so a click meant for the one before it is lost. The agent gets the response as you see it: secrets masked, whatever the charset of the body. In what Bee itself says of a failure, the values of variables are masked too.
- `send_request` sends with the active environment, or with another one the agent names (`environment`, by name or identifier from `list_environments`). An agent knows an environment by its name and the names of its variables, never by a value. The environment you work with does not change: only that send uses the one named, what its scripts change goes to that one, and the question says which it is and that it is not the one Bee is on. Agreeing until Bee quits holds for one environment: the same request with another is asked about.
- `get_response` gives the last response Bee got for a request or a fork without sending it again, so an agent can look at what you got yourself. Bee asks you each time it is a response the program has not seen; one it was given (it sent the request, or you agreed) is read again without a question, which is how it reads on, piece by piece, in a body cut after 60,000 characters. It is the response as the send masked it, whatever you revealed on screen since, masked again with the secrets as they are when it is read.
- `propose_change` never touches the collection: it creates a fork, which the agent can send when you agree, to see what its change returns, and revise in place rather than make another. You merge the fork or discard it. Once you edit a fork an agent proposed it is yours: an agent no longer revises it, and a proposal on it starts another fork. An agent cannot change a header or a parameter that holds a secret, the authorization (nor set the header, the cookie or the parameter that carries it), a script, where a request is sent (scheme, host, port), point a request at a secret variable it does not use already, directly or through the value of another variable, nor pile up more than ten forks on a request. A header it removes is turned off, not deleted. An address and a header it writes are one line, without a hidden character, of a length a person can read.
- A program that gives up on a call (a timeout) takes its question off the screen, and nothing is sent for it.
- Limits: a response is data from a server and may carry instructions meant for the agent; what you allow it to send is up to you. Masking finds a secret sent back as it is or encoded, not one a server transformed. The question about a program tells you who asks; it does not protect against another program of your own account that starts the relay the same way, or that rewrites the collection files: such a program is already past what Bee can check.

## Forks

- **Request › Fork** copies a request of a collection to try things on it. The fork is listed under its original, with an empty cell; its page has another ground, so the two are never mistaken.
- A fork is kept on this Mac only (`workspace.json`), never in the collection. It is sent from the place of its original: same folders, authorization and scripts.
- The parts a fork has not changed (URL, parameters, authorization, headers, body, scripts, settings) follow the original. The parts it changed stay its own.
- **Merge…** puts the changed parts in the original and removes the fork; where the original changed the same part since, the review asks which one to keep. A fork can also be kept as a new request, or discarded. Its secrets have their own entries in the vault, moved to the original by a merge.
- While secrets are locked, Bee cannot tell what a fork changed: forking and merging wait until they are unlocked. Deleting a request that has forks asks first, since they go with it.

## Secrets

- A secret (a secret variable, an authorization credential, a row marked secret) is never encoded by the models: no workspace file, history entry, export or cURL command can contain its value.
- Values live in `secrets.vault`, sealed with AES-256-GCM. The 256-bit key is one item in the login Keychain (`Bee Vault Key`, this device only).
- In the "Request sent" view and in history, a secret is masked where it was put in (path, parameters, headers, body text), whatever its length or encoding. Console lines, test results and error messages are searched for known secret values instead, which cannot catch a value shorter than 4 characters. A response that echoes a secret back is shown masked until revealed.
- A script that copies a secret into another variable makes that variable secret too; turning a secret back into a plain value clears it unless the person just authenticated.
- Revealing or copying a secret asks for Touch ID or the account password; a copied secret is marked concealed and cleared after a minute.
- Rebuilding the app changes its signature: macOS then asks once to let the new build read `Bee Vault Key`.

## Updates

- Once a day, and on Bee › Check for Updates…, Bee asks GitHub for the latest release of this repository (`api.github.com/repos/digivorefr/bee/releases/latest`). The request carries Bee's version and nothing else. Settings › Updates turns the daily question off.
- A newer release is announced with its notes. Bee installs it by itself only when the release holds `Bee-<version>.zip` and its signature `Bee-<version>.zip.sig`, and that signature is valid for the public key shipped in the application (`Resources/update-key.txt`, Ed25519). The archive is checked before it is unpacked: the update is not quarantined by macOS, so this signature is what stands between a published file and code running on the Mac.
- The new version is then checked again (identifier, version, code signature of every file), put in place of the running copy, and Bee restarts. A copy without the public key, or one that macOS runs from the download folder, offers the release page instead.
- While Bee is signed ad hoc, each new version has a new signature: after an update macOS asks once to let it read `Bee Vault Key`.
- What the signature does not cover: which release is the latest. Someone in control of the repository could hide newer versions, or offer again an older genuine one that is still newer than the installed copy. They cannot make Bee install anything the release key did not sign.

## Scripts

JavaScript, global `bee` (alias `pm` for imported Postman scripts):

```js
// Post-response: keep a token for the next requests, as a secret.
bee.environment.set("accessToken", bee.response.json().token, { secret: true });
bee.test("Status is 200", () => bee.response.to.have.status(200));
```

`bee.environment` · `bee.collectionVariables` · `bee.globals` · `bee.variables` · `bee.request` · `bee.response` · `bee.test` · `bee.expect` · `bee.sendRequest` · `bee.crypto` · `bee.base64` · `bee.uuid()` · `console`.

## Debug harness

Debug builds can be driven without a person (`Sources/Bee/App/DebugHarness.swift`):

```bash
Scripts/build-app.sh --debug
BEE_DATA_DIR=$(mktemp -d) BEE_SCENARIO="select:Send JSON;send;snapshot:/tmp/bee.png;quit" dist/Bee.app/Contents/MacOS/Bee
```

`BEE_DATA_DIR` makes the data throwaway (in-memory vault, no Keychain). Release builds ignore both variables.

## Releasing

Once, before the first signed release, create the key updates are signed with:

```bash
swift Scripts/update-key.swift generate
```

It stores the private key in the login Keychain (`Bee Update Signing Key`, read only after macOS asks) and writes the public key to `Resources/update-key.txt`, to commit. Keep a copy of the private key somewhere safe (Keychain Access shows it as the password of that item): without it, the copies of Bee already installed cannot be given another update by themselves; with it, anyone can sign one. The key is never replaced: on another Mac, `swift Scripts/update-key.swift import <file>` puts the saved copy back, and `generate` refuses to run while `Resources/update-key.txt` exists.

Then, for each version:

1. Add a section at the top of `CHANGELOG.md`: `## 1.1.0 — 2027-01-31`, then `### Added`, `### Changed` or `### Fixed` with one `- ` line per change, written for the people who use Bee. That heading is the version of the build.
2. Commit and push.
3. Package and check the result (`dist/Bee-<version>.zip` holds the application and the license, `dist/Bee-<version>.zip.sig` its signature, for which the Keychain asks; the notes are that section of the changelog followed by how to install):

```bash
Scripts/release.sh
```

4. Publish the tag, the archive and its signature as a GitHub release (refused without the release key, unless `--unsigned` is given):

```bash
Scripts/release.sh --publish
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): use, modify and redistribute the code for any noncommercial purpose. Commercial use is not permitted.
