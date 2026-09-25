// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import Foundation

struct PermissionFlowStrings {
  let language: PermissionFlowLanguage

  init(_ language: PermissionFlowLanguage) {
    self.language = language
  }

  private func pick(_ english: String, _ spanish: String) -> String {
    language == .spanish ? spanish : english
  }

  func title(_ kind: PermissionFlowKind) -> String {
    switch kind {
    case .accessibility: pick("Accessibility", "Accesibilidad")
    case .fullDiskAccess: pick("Full Disk Access", "Acceso total al disco")
    case .automation: pick("Automation", "Automatización")
    case .microphone: pick("Microphone", "Micrófono")
    case .localNetwork: pick("Local Network", "Red local")
    case .inputMonitoring: pick("Input Monitoring", "Monitoreo de entrada")
    case .screenRecording: pick("Screen Recording", "Grabación de pantalla")
    }
  }

  func windowTitle(_ app: String) -> String { pick("Set up \(app)", "Configura \(app)") }

  func headline(_ app: String) -> String {
    pick("Let's set up \(app)", "Vamos a configurar \(app)")
  }

  func subtitle(_ app: String, required: Int, optional: Int) -> String {
    let need: String
    switch required {
    case 0:
      need = pick(
        "\(app) works better with these permissions", "\(app) funciona mejor con estos permisos")
    case 1:
      need = pick(
        "\(app) needs one permission to work", "\(app) necesita un permiso para funcionar")
    default:
      need = pick(
        "\(app) needs \(required) permissions to work",
        "\(app) necesita \(required) permisos para funcionar")
    }
    let extra: String
    switch (required, optional) {
    case (0, _), (_, 0): extra = ""
    case (_, 1): extra = pick(", plus one optional", " y uno opcional")
    default: extra = pick(", plus \(optional) optional", " y \(optional) opcionales")
    }
    return need + extra + ".\n" + pick("You only do this once.", "Solo se hace una vez.")
  }

  func progress(_ done: Int, of total: Int) -> String {
    pick("\(done) of \(total) ready", "\(done) de \(total) listos")
  }

  var allow: String { pick("Allow", "Permitir") }
  var openSettings: String { pick("Open Settings", "Abrir Ajustes") }
  var waiting: String { pick("Waiting…", "Esperando…") }
  var granted: String { pick("Ready", "Listo") }
  var requested: String { pick("Requested", "Solicitado") }
  var optional: String { pick("Optional", "Opcional") }
  var later: String { pick("Set up later", "Configurar después") }
  var lockedUntilOthers: String {
    pick(
      "Comes last: macOS asks to reopen the app after this one.",
      "Va al final: macOS pide reabrir la app después de este permiso.")
  }
  func reopen(_ app: String) -> String { pick("Reopen \(app)", "Reabrir \(app)") }
  func reopenHint(_ app: String) -> String {
    pick(
      "Turned it on? Reopen \(app) to finish.",
      "¿Ya lo activaste? Reabre \(app) para terminar.")
  }
  func finishWithReopen(_ app: String) -> String {
    pick("Reopen \(app) to finish the setup.", "Reabre \(app) para terminar la configuración.")
  }
  var reopenFailed: String {
    pick(
      "Couldn't reopen automatically. Quit and open it again.",
      "No se pudo reabrir. Ciérrala y ábrela de nuevo.")
  }

  func welcome(_ app: String) -> String { pick("Welcome to \(app)", "Bienvenido a \(app)") }
  func ready(_ app: String) -> String {
    pick(
      "Everything is ready. \(app) is already working from your menu bar.",
      "Todo listo. \(app) ya está funcionando desde tu barra de menús.")
  }
  func start(_ app: String) -> String { pick("Start using \(app)", "Empezar a usar \(app)") }
  var closesSoon: String { pick("This window closes on its own", "Esta ventana se cierra sola") }

  func dragTitle(_ app: String) -> String {
    pick("Drag \(app) into the list above", "Arrastra \(app) a la lista de arriba")
  }
  func dragDetail(_ kind: PermissionFlowKind) -> String {
    pick(
      "Drop it in \(title(kind)), then turn on its switch.",
      "Suéltalo en \(title(kind)) y activa su interruptor.")
  }
  func dragAccessibility(_ app: String, _ kind: PermissionFlowKind) -> String {
    pick("Drag \(app) to the \(title(kind)) list", "Arrastra \(app) a la lista de \(title(kind))")
  }
  func toggleTitle(_ app: String) -> String {
    pick("Turn on \(app)'s switch", "Activa el interruptor de \(app)")
  }
  func toggleDetail(_ app: String, _ kind: PermissionFlowKind) -> String {
    pick(
      "Find \(app) in the \(title(kind)) list above and turn it on.",
      "Busca \(app) en la lista de \(title(kind)) de arriba y actívalo.")
  }
  var accessGranted: String { pick("Access granted", "Permiso concedido") }
  func returning(_ app: String) -> String { pick("Back to \(app)…", "Volviendo a \(app)…") }
  var dismissGuide: String { pick("Dismiss guide", "Cerrar guía") }
}
