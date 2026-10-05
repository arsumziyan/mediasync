import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isSignedIn {
            LibraryView()
        } else {
            LoginView()
        }
    }
}

struct LoginView: View {
    @Environment(AppState.self) private var state
    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var busy = false
    @AppStorage("apiBaseURL") private var baseURL = "http://localhost:8000"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (8+ characters)", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                }
                Section("Server") {
                    TextField("API URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let error = state.errorMessage {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Section {
                    Button {
                        busy = true
                        Task {
                            await state.signIn(email: email, password: password, register: isRegistering)
                            busy = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(isRegistering ? "Create account" : "Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || email.isEmpty || password.count < 8)

                    Button(isRegistering ? "I already have an account" : "Create a new account") {
                        Haptics.select()
                        isRegistering.toggle()
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("MediaSync")
        }
    }
}
