import SwiftUI
import Photos

@MainActor
struct SettingsView: View {
    @Environment(PhotoLibraryService.self) private var library
    @AppStorage(Keys.notifEnabled) private var enabled = true
    @AppStorage(Keys.notifHour) private var hour = 20
    @AppStorage(Keys.notifMinute) private var minute = 0
    @AppStorage(Keys.userName) private var userName = ""
    @State private var showDeniedAlert = false
    let onChange: () -> Void

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                hour = c.hour ?? 20; minute = c.minute ?? 0
                onChange()
            })
    }

    private var accessText: String {
        switch library.status {
        case .authorized: "Completo"
        case .limited: "Limitado"
        case .denied, .restricted: "Sin acceso"
        default: "No determinado"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Perfil") { TextField("Tu nombre (opcional)", text: $userName) }
                Section("Recordatorios") {
                    Toggle("Recordatorio diario", isOn: $enabled)
                        .onChange(of: enabled) { _, on in
                            guard on else { onChange(); return }
                            Task {
                                let st = await NotificationService.status()
                                var ok = (st == .authorized)
                                if st == .notDetermined { ok = await NotificationService.requestAuthorization() }
                                if !ok { enabled = false; showDeniedAlert = true }
                                onChange()
                            }
                        }
                    DatePicker("Hora", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .disabled(!enabled)
                    Text("No se envían avisos los días sin contenido pendiente.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Biblioteca") {
                    LabeledContent("Acceso a Fotos", value: accessText)
                    if library.status == .limited { Button("Gestionar fotos seleccionadas") { library.presentLimitedPicker() } }
                    Button("Abrir Ajustes de iOS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("Acerca de") {
                    NavigationLink("Privacidad") { PrivacyView() }
                    LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("Ajustes")
            .alert("Notificaciones desactivadas", isPresented: $showDeniedAlert) {
                Button("Abrir Ajustes") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { Text("Activa las notificaciones de REWIND en los Ajustes de iOS para recibir recordatorios.") }
        }
        .onAppear { library.refreshStatus() }
    }
}

@MainActor
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            Text("""
            • Tus fotos y vídeos nunca salen del dispositivo: no hay servidores, cuentas ni analíticas.
            • REWIND no guarda copias de tus fotos. Solo almacena el identificador de cada elemento y tu decisión (conservar / eliminar).
            • Nada se elimina sin tu confirmación explícita y la autorización del sistema.
            • Los elementos eliminados van a «Eliminados recientemente» de Apple Fotos durante 30 días.
            • Puedes revocar el acceso en cualquier momento desde Ajustes de iOS.
            """).padding()
        }
        .navigationTitle("Privacidad")
    }
}
