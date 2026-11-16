import BeeCore
import SwiftUI

/// Edits an authorization: its kind, then the fields of that kind (credentials in `SecretValueField`s),
/// and one caption that says what will be sent.
struct AuthEditor: View {
    @Binding private var auth: AuthConfig
    private let allowsInherit: Bool
    private let context: VariableContext

    /// `allowsInherit` is false at collection level, where there is no parent to inherit from.
    init(auth: Binding<AuthConfig>, allowsInherit: Bool, context: VariableContext) {
        _auth = auth
        self.allowsInherit = allowsInherit
        self.context = context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                GridRow {
                    label("Type")
                    RequestPopUp(
                        "Type", selection: $auth.kind,
                        options: AuthKind.allCases
                            .filter { allowsInherit || $0 != .inherit }
                            .map { RequestPopUpOption(value: $0, title: Self.title(of: $0)) }
                    )
                }
                switch auth.kind {
                case .inherit, .none:
                    EmptyView()
                case .bearer:
                    GridRow {
                        label("Token")
                        SecretValueField("Token or {{variable}}", text: $auth.bearerToken.value, context: context)
                    }
                case .basic:
                    GridRow {
                        label("Username")
                        TemplateField("Username", text: $auth.basicUsername, context: context)
                    }
                    GridRow {
                        label("Password")
                        SecretValueField("Password or {{variable}}", text: $auth.basicPassword.value, context: context)
                    }
                case .apiKey:
                    GridRow {
                        label("Name")
                        TemplateField("X-Api-Key", text: $auth.apiKeyName, context: context)
                    }
                    GridRow {
                        label("Value")
                        SecretValueField("Key or {{variable}}", text: $auth.apiKeyValue.value, context: context)
                    }
                    GridRow {
                        label("Add to")
                        RequestPopUp(
                            "Add to", selection: $auth.apiKeyLocation,
                            options: [
                                RequestPopUpOption(value: APIKeyLocation.header, title: "Header"),
                                RequestPopUpOption(value: APIKeyLocation.query, title: "Query"),
                            ]
                        )
                    }
                }
            }
            explanation
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.text())
            .foregroundStyle(Theme.inkSecondary)
            .gridColumnAlignment(.leading)
    }

    // MARK: What will be sent

    /// One caption: words in what Bee says, the header or parameter in the wire voice, credentials sealed.
    private var explanation: some View {
        let sent = Self.sent(auth)
        return HStack(spacing: Theme.Space.xs) {
            Text(sent.words).requestCaption()
            if let wire = sent.wire {
                TokenText(wire, context: context, size: Theme.Size.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .lineLimit(1)
    }

    static func title(of kind: AuthKind) -> String {
        switch kind {
        case .inherit: "Inherit from parent"
        case .none: "None"
        case .bearer: "Bearer token"
        case .basic: "Basic"
        case .apiKey: "API key"
        }
    }

    /// What the authorization adds to the request. A credential is never part of the text.
    static func sent(_ auth: AuthConfig) -> (words: String, wire: String?) {
        switch auth.kind {
        case .inherit:
            return ("Uses the authorization of the parent folder or collection.", nil)
        case .none:
            return ("Sends no authorization, even when a parent has one.", nil)
        case .bearer:
            guard !auth.bearerToken.value.isEmpty else {
                return ("Enter a token to add the Authorization header.", nil)
            }
            return ("Adds the header", "Authorization: Bearer \(RequestText.sealed(auth.bearerToken.value))")
        case .basic:
            guard !auth.basicUsername.isEmpty || !auth.basicPassword.value.isEmpty else {
                return ("Enter a username and a password to add the Authorization header.", nil)
            }
            return ("Adds the header", "Authorization: Basic \(URLTemplate.mask)")
        case .apiKey:
            guard !auth.apiKeyName.isEmpty else {
                return ("Enter a name and a value to add the key.", nil)
            }
            let value = auth.apiKeyValue.value.isEmpty ? "" : RequestText.sealed(auth.apiKeyValue.value)
            switch auth.apiKeyLocation {
            case .header: return ("Adds the header", "\(auth.apiKeyName): \(value)")
            case .query: return ("Adds the query parameter", "\(auth.apiKeyName)=\(value)")
            }
        }
    }

    /// The resting summary: the type and where it goes.
    static func summary(of auth: AuthConfig) -> String {
        switch auth.kind {
        case .inherit: "Inherit from parent"
        case .none: "None"
        case .bearer: "Bearer token in the Authorization header"
        case .basic: "Basic in the Authorization header"
        case .apiKey:
            switch auth.apiKeyLocation {
            case .header: auth.apiKeyName.isEmpty ? "API key in a header" : "API key in the header \(auth.apiKeyName)"
            case .query:
                auth.apiKeyName.isEmpty ? "API key in the query" : "API key in the query parameter \(auth.apiKeyName)"
            }
        }
    }
}
