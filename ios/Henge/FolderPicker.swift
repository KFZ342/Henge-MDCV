import SwiftUI
import UniformTypeIdentifiers

/// The system folder picker, opened in place.
///
/// SwiftUI's `fileImporter` copies what it hands back into the app. A folder cannot be
/// copied, so on iOS the picker showed folders greyed out and only files looked
/// selectable — which is why a drive could not be chosen at all. This asks the document
/// picker for a folder without copying (`asCopy: false`), so it returns a
/// security-scoped URL for the drive, or for a folder on it.
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
