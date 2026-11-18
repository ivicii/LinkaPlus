import SwiftUI
import UniformTypeIdentifiers

/// A plain data document used only to hand the encrypted backup to the system
/// save sheet (Files, iCloud, AirDrop…).
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.data]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Export and restore the lock access keys as an encrypted file.
struct BackupView: View {
    @State private var mode: Mode = .idle
    @State private var pass = ""
    @State private var pass2 = ""
    @State private var message: String?
    @State private var isError = false
    @State private var exportDoc: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: Data?

    enum Mode { case idle, exporting, importing }

    private var canExport: Bool { pass.count >= 6 && pass == pass2 }

    var body: some View {
        List {
            Section {
                Text("Je toegangssleutels leven nu alleen in deze telefoon en in LINKA's cloud. Met een back-up kun je je slot blijven bedienen als die cloud wegvalt of je telefoon kwijtraakt. Het bestand is versleuteld met een wachtwoord — bewaar dat los (bijv. in je wachtwoordmanager).")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Back-up maken") {
                SecureField("Wachtwoord (min. 6 tekens)", text: $pass)
                SecureField("Herhaal wachtwoord", text: $pass2)
                Button {
                    makeBackup()
                } label: { Label("Exporteer versleutelde back-up", systemImage: "square.and.arrow.up") }
                    .disabled(!canExport)
            }

            Section {
                Button {
                    showImporter = true
                } label: { Label("Kies back-upbestand", systemImage: "square.and.arrow.down") }
            } header: {
                Text("Herstellen")
            } footer: {
                Text("Na het kiezen van het bestand vraag ik je wachtwoord. Bestaande sloten blijven staan; sleutels uit de back-up worden toegevoegd.")
            }

            if let message {
                Section {
                    Label(message, systemImage: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? Theme.danger : Theme.success)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Back-up & herstel")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter,
                      document: exportDoc,
                      contentType: .data,
                      defaultFilename: "LinkaPlus-\(Self.dateStamp).\(KeyBackup.fileExtension)") { result in
            switch result {
            case .success: set("Back-up opgeslagen. Bewaar je wachtwoord goed.", error: false); pass = ""; pass2 = ""
            case .failure(let e): set("Opslaan mislukt: \(e.localizedDescription)", error: true)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data, .json],
                      allowsMultipleSelection: false) { result in
            handleImportPick(result)
        }
        .alert("Wachtwoord van de back-up", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            SecureField("Wachtwoord", text: $pass)
            Button("Herstel") { doRestore() }
            Button("Annuleer", role: .cancel) { pendingImport = nil; pass = "" }
        } message: {
            Text("Voer het wachtwoord in waarmee deze back-up is gemaakt.")
        }
    }

    private static var dateStamp: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func set(_ msg: String, error: Bool) { message = msg; isError = error }

    private func makeBackup() {
        do {
            let data = try KeyBackup.export(passphrase: pass)
            exportDoc = BackupDocument(data: data)
            showExporter = true
            message = nil
        } catch {
            set((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, error: true)
        }
    }

    private func handleImportPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingImport = try Data(contentsOf: url)
                pass = ""
            } catch {
                set("Kon het bestand niet lezen.", error: true)
            }
        case .failure(let e):
            set("Kiezen mislukt: \(e.localizedDescription)", error: true)
        }
    }

    private func doRestore() {
        guard let data = pendingImport else { return }
        pendingImport = nil
        do {
            try KeyBackup.restore(data, passphrase: pass)
            set("Hersteld. Je sloten staan weer in de app.", error: false)
        } catch {
            set((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, error: true)
        }
        pass = ""
    }
}
