# SapoWhisper - Documentación del Proyecto

> **Documento para AI Assistants y Desarrolladores**
> Última actualización: Diciembre 2024

---

## Resumen del Proyecto

**SapoWhisper** es una aplicación nativa de macOS que convierte voz a texto. Funciona desde el Menu Bar y permite transcribir audio usando un atajo de teclado global personalizable.

### Estado Actual: MVP Funcional + WhisperKit Full Local

| Característica                       | Estado       |
| ------------------------------------ | ------------ |
| Menu Bar App                         | Completo     |
| Icono personalizado del sapo         | Completo     |
| Grabación de Audio                   | Completo     |
| Transcripción Apple (Online)         | Completo     |
| **Transcripción WhisperKit (Local)** | **Completo** |
| Selector de Motor (Online/Local)     | Completo     |
| Selector de Modelo Whisper           | Completo     |
| **Descarga de Modelos con Progreso** | **Completo** |
| **Velocidad de Descarga (MB/s)**     | **Completo** |
| Hotkey Global Personalizable         | Completo     |
| Selección de Micrófono               | Completo     |
| Selección de Idioma (ES/EN/Auto)     | Completo     |
| Copiar al Portapapeles               | Completo     |
| Auto-paste (vuelve a app anterior)   | Completo     |
| Sonidos de Feedback                  | Completo     |
| UI Moderna                           | Completo     |

---

## IMPORTANTE: Arquitectura de Vistas

### Hay DOS ventanas de configuración diferentes:

1. **ModelDownloadView.swift** (PRINCIPAL) - Se abre desde "Configuración" en el menú

   - Tiene 2 pestañas: **Ajustes** e **Info**
   - **TODOS los ajustes van aquí**: micrófono, idioma, hotkey, comportamiento, gestión de modelos
   - Se abre con: `openWindow(id: "settings")`

2. **SettingsView.swift** - Se abre con ⌘, (Command + coma)
   - Es la ventana de preferencias estándar de macOS
   - Tiene duplicados de algunos ajustes (legacy)
   - **NO agregar nuevos ajustes aquí**, usar ModelDownloadView

### Regla: Cuando agregues configuración, hazlo en ModelDownloadView en la pestaña "Ajustes"

---

## Estructura de Archivos

```
SapoWhisper/
├── SapoWhisper/
│   ├── App/
│   │   ├── SapoWhisperApp.swift     # Entry point (MenuBarExtra + Windows)
│   │   └── AppDelegate.swift        # NSApplicationDelegate
│   │
│   ├── Core/
│   │   ├── AudioRecorder.swift      # Grabacion con AVAudioEngine
│   │   ├── AudioDeviceManager.swift # Lista microfonos disponibles (CoreAudio)
│   │   ├── WhisperTranscriber.swift # Transcripcion con Apple Speech (Online)
│   │   ├── WhisperKitTranscriber.swift # Transcripcion Local y Gestión de Modelos
│   │   ├── HotkeyManager.swift      # Atajos globales (Carbon API)
│   │   ├── PasteManager.swift       # Portapapeles + auto-paste
│   │   └── SapoWhisperViewModel.swift # ViewModel central
│   │
│   ├── Models/
│   │   ├── AppState.swift           # Estados de la app
│   │   ├── WhisperModel.swift       # Modelos legacy
│   │   └── TranscriptionEngine.swift # Enum motor + metadata modelos WhisperKit
│   │
│   ├── Views/
│   │   ├── MenuBarView.swift        # UI del popup del menu bar
│   │   ├── MenuBarIcon.swift        # Icono dinamico del menu bar
│   │   ├── ModelDownloadView.swift  # VENTANA PRINCIPAL DE CONFIGURACION
│   │   └── SettingsView.swift       # Preferencias Cmd+, (secundario)
│   │
│   ├── Utilities/
│   │   ├── Constants.swift          # Constantes y StorageKeys
│   │   ├── DownloadManager.swift    # Legacy downloader
│   │   └── SoundManager.swift       # Sonidos de feedback
│   │
│   └── Assets.xcassets/
│       ├── AppIcon.appiconset/      # Icono del sapo (todos los tamanos)
│       └── MenuBarIcon.imageset/    # Icono para menu bar
```

---

## Componentes Clave

### WhisperKitTranscriber.swift

Core de la funcionalidad local. Maneja:

- Carga de modelos Whisper optimizados
- **Descarga inteligente**: Monitorea el progreso de descarga calculando el tamaño del repo local
- **Indicador de Velocidad**: Calcula MB/s en tiempo real
- **Gestión de Estados**: `downloading` -> `prewarming` (cuando el tamaño se estabiliza) -> `loaded`
- **Gestión de Memoria**: Carga/Descarga modelos según selección

### AudioDeviceManager.swift

Lista todos los micrófonos disponibles en el sistema usando CoreAudio de forma segura (sin warnings de punteros):

```swift
AudioDeviceManager.shared.availableDevices  // [AudioDevice]
AudioDeviceManager.shared.refreshDevices()  // Actualiza la lista
```

### HotkeyManager.swift

Maneja atajos de teclado globales. Ahora usa constantes inmutables (`let`) donde corresponde.

---

## Transcripción de Audio

### Motor Dual: WhisperKit (Local) + Apple Speech (Online)

La app soporta **dos motores de transcripción**:

#### 1. WhisperKit (Local) - Recomendado

- 100% offline, procesamiento en dispositivo (GPU/Neural Engine)
- Usa modelos de OpenAI Whisper optimizados para Apple Silicon
- Mayor privacidad (nada sale del Mac)
- **Modelos Actualizados**:
  - **Tiny** (76.6 MB) - Muy rápido
  - **Base** (146.7 MB) - Rápido
  - **Small** (486.5 MB) - Mejor balance (Recomendado)
  - **Large V3** (3.09 GB) - Máxima precisión (Lento)
  - **Large V3 Turbo** (3.2 GB) - Precisión V3 + Velocidad

#### 2. Apple Speech (Online)

- Requiere conexión a internet
- Usa servidores de Apple
- Rápido y sin descargas adicionales

---

## Decisiones de Diseño Recientes

### Monitoreo de Descarga "Repo-based"

WhisperKit descarga un repositorio completo. Para mostrar una barra de progreso real:

1. Calculamos el tamaño total esperado del modelo.
2. Monitoreamos el crecimiento del directorio local (`getTotalRepoSize`).
3. Calculamos la velocidad en tiempo real (MB/s).
4. Detectamos cuando la descarga se detiene (tamaño estable) para cambiar al estado "Prewarming".

### Auto-Cancelación

Si el usuario cambia de modelo mientras otro se descarga, la tarea anterior se cancela automáticamente y se limpia la UI.

### Persistencia Inteligente

Al abrir la app, si el motor seleccionado es local, se recarga automáticamente el último modelo usado sin intervención del usuario.

---

## Comandos de Desarrollo

```bash
# Compilar
xcodebuild -project SapoWhisper.xcodeproj -scheme SapoWhisper -configuration Debug build

# Git (rama main protegida)
git checkout -b feature/nombre
git add -A && git commit -m "mensaje en inglés detallado"
git push origin feature/nombre
gh pr create --title "Título" --body "Descripción"
gh pr merge --squash --delete-branch
```

---

## Roadmap

### Completado

- [x] Menu Bar App con icono personalizado
- [x] Grabación y transcripción
- [x] Hotkey global personalizable
- [x] Selección de micrófono
- [x] Selección de idioma
- [x] UI moderna (Ajustes/Info)
- [x] **WhisperKit: Integración Completa**
- [x] **Gestión de Modelos: Descarga, Borrado, Selección**
- [x] **UI de Descarga: Barra de progreso, % real, MB/s**
- [x] **Fix: Estado de Prewarming correcto**
- [x] **Fix: Sincronización de tamaño de modelos**

### Próximo

- [ ] Historial de transcripciones (Base de datos local)
- [ ] Launch at Login
- [ ] Soporte para dictado continuo (streaming)

### Futuro

- [ ] Onboarding interactivo
- [ ] Integración con LLMs locales para resumen
- [ ] App Store Ready

---

## Referencias

- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- [CoreAudio](https://developer.apple.com/documentation/coreaudio)
