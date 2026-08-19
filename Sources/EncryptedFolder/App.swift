import SwiftUI

@main
struct EncryptedFolderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Encrypted Folder", systemImage: "lock.square")
        } description: {
            Text("Choose or create a vault to begin.")
        } actions: {
            HStack {
                Button("Open Vault…") {}
                Button("New Vault…") {}
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
