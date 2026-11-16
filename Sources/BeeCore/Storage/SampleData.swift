import Foundation

/// The workspace a person finds on first launch: a short tour of variables, secrets, scripts and
/// tests, runnable as is against httpbin.org.
public enum SampleData {
    public static func workspace() -> Workspace {
        let httpbin = Environment(name: "httpbin", variables: [
            Variable(name: "baseUrl", value: "https://httpbin.org"),
            Variable(name: "userName", value: "bee"),
            Variable(name: "ticketId", value: "42"),
            Variable(name: "apiToken", value: "demo-token-1234", isSecret: true),
            Variable(name: "accessToken", value: "", isSecret: true),
        ])
        let local = Environment(name: "Local", variables: [
            Variable(name: "baseUrl", value: "http://localhost:3000"),
            Variable(name: "apiToken", value: "", isSecret: true),
        ])
        return Workspace(
            collections: [basics()], environments: [httpbin, local], activeEnvironmentID: httpbin.id
        )
    }

    private static func basics() -> Collection {
        Collection(
            name: "Bee Basics",
            items: [
                .request(getWithParameters()),
                .request(getByPathVariable()),
                .request(sendJSON()),
                .request(sendSecretHeader()),
                .folder(tokenFlow()),
                .request(teapot()),
            ],
            preRequestScript: """
            // Collection scripts run for every request of the collection.
            // This one tags each call with a unique id before it is sent.
            bee.request.headers.upsert({ key: "X-Request-Id", value: bee.uuid() });
            """,
            notes: """
            A tour of Bee. Pick the "httpbin" environment, then send the requests from top to bottom.
            Values written {{likeThis}} come from the active environment.
            """
        )
    }

    private static func getWithParameters() -> RequestItem {
        RequestItem(
            name: "Get with parameters",
            method: .get,
            url: "{{baseUrl}}/get",
            queryParams: [
                KeyValue(key: "user", value: "{{userName}}"),
                KeyValue(key: "page", value: "1"),
            ],
            notes: "Query parameters are edited as rows. {{userName}} is replaced by the environment value."
        )
    }

    private static func getByPathVariable() -> RequestItem {
        RequestItem(
            name: "Get by path variable",
            method: .get,
            url: "{{baseUrl}}/anything/tickets/:ticketId/comments/:commentId",
            pathVariables: [KeyValue(key: "commentId", value: "7")],
            notes: """
            A segment written :name is a path variable. commentId has its value under Path variables; \
            ticketId has none, so it takes the ticketId variable of the environment.
            """
        )
    }

    private static func sendJSON() -> RequestItem {
        RequestItem(
            name: "Send JSON",
            method: .post,
            url: "{{baseUrl}}/post",
            body: RequestBody(
                mode: .raw,
                raw: """
                {
                  "name": "{{userName}}",
                  "sentAt": {{$timestamp}}
                }
                """,
                rawLanguage: .json
            ),
            postResponseScript: """
            // Post-response scripts read the response and record tests.
            bee.test("Status is 200", () => {
              bee.response.to.have.status(200);
            });

            // httpbin sends back the JSON it received under "json".
            bee.test("The body is echoed", () => {
              const echoed = bee.response.json().json;
              bee.expect(echoed).to.have.property("sentAt");
              bee.expect(echoed.name).to.equal(bee.variables.get("userName"));
            });
            """,
            notes: "{{$timestamp}} is a built-in value: the current Unix time."
        )
    }

    private static func sendSecretHeader() -> RequestItem {
        RequestItem(
            name: "Send a secret header",
            method: .get,
            url: "{{baseUrl}}/headers",
            headers: [KeyValue(key: "X-Api-Token", value: "{{apiToken}}", isSecret: true)],
            notes: """
            apiToken is a secret variable: it is kept encrypted, masked on screen and hidden from the \
            history and the console. The server still receives the real value.
            """
        )
    }

    private static func tokenFlow() -> Folder {
        let getToken = RequestItem(
            name: "1 · Get a token",
            method: .get,
            url: "{{baseUrl}}/uuid",
            postResponseScript: """
            // Keep a value from the response for the next request.
            // { secret: true } stores it encrypted in the active environment.
            const body = bee.response.json();
            bee.environment.set("accessToken", body.uuid, { secret: true });

            bee.test("A token was returned", () => {
              bee.expect(body).to.have.property("uuid");
              bee.expect(body.uuid).to.be.a("string");
            });
            console.log("accessToken saved to the environment");
            """
        )
        let callWithToken = RequestItem(
            name: "2 · Call with the token",
            method: .get,
            url: "{{baseUrl}}/bearer",
            auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{accessToken}}")),
            postResponseScript: """
            // Passes once "1 · Get a token" has filled accessToken.
            bee.test("The token is accepted", () => {
              bee.response.to.have.status(200);
            });
            """
        )
        return Folder(
            name: "Token flow",
            items: [.request(getToken), .request(callWithToken)],
            notes: "Send the two requests in order: the first stores a token, the second uses it."
        )
    }

    private static func teapot() -> RequestItem {
        RequestItem(
            name: "Teapot",
            method: .get,
            url: "{{baseUrl}}/status/418",
            postResponseScript: """
            // A test can expect any status, not only a success.
            bee.test("The server is a teapot", () => {
              bee.expect(bee.response.code).to.equal(418);
            });
            """
        )
    }
}
