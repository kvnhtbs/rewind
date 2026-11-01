# REWIND

> *Un año después, decide qué recuerdos merecen quedarse.*

App iOS nativa (Swift + SwiftUI, iOS 17+) que recupera cada día las fotos y vídeos de hace un año y te deja decidir con gestos tipo Tinder qué conservar y qué eliminar.

- **PhotoKit** para acceder a la galería (respeta acceso limitado) · **SwiftData** para sesiones y decisiones · **UserNotifications** para recordatorios locales.
- Todo se procesa en el dispositivo. Nada se borra sin confirmación explícita.
- Bundle ID provisional: `com.rewind.app`.

## Estructura del repositorio

```
.
├── codemagic.yaml            ← configuración de CI/CD
├── README.md
├── .gitignore
├── REWIND.xcodeproj/         ← proyecto Xcode (scheme compartido "REWIND")
└── REWIND/                   ← código fuente
    ├── REWINDApp.swift       ← punto de entrada (@main)
    ├── Info.plist            ← permiso de Fotos, orquestación de escenas
    ├── Assets.xcassets/      ← AppIcon (1024 px) y AccentColor
    └── *.swift               ← vistas, servicios y modelos
```

## Estado de verificación (léelo antes de empezar)

El proyecto se generó **sin acceso a Xcode ni a un compilador de Swift**, así que **no se ha compilado nunca**.
Se hizo revisión estática del código y validación estructural de `project.pbxproj`, `Info.plist`, JSON de assets y `codemagic.yaml`, pero eso no sustituye a una compilación real.
**La primera ejecución en Codemagic es la prueba real.** Si falla, copia el error del log y se corrige (es normal que una primera compilación necesite 1–3 iteraciones).

## Compilar en Codemagic desde Windows

### 1. Subir el proyecto a GitHub
1. Descomprime el ZIP. El contenido de la carpeta (`codemagic.yaml`, `REWIND.xcodeproj`, `REWIND/`…) debe quedar **en la raíz** del repositorio.
2. En tu repo actual, **borra la estructura antigua** (`REWIND/REWIND/REWIND/…`) y sube esta. Con GitHub Desktop o Git:
   ```
   git rm -r REWIND
   # copia aquí el contenido del ZIP
   git add -A
   git commit -m "Proyecto Xcode + Codemagic"
   git push
   ```
3. Comprueba en github.com que en la raíz se ve `codemagic.yaml` y `REWIND.xcodeproj`.

### 2. Conectar Codemagic
1. Entra en https://codemagic.io e inicia sesión con GitHub.
2. **Add application** → elige tu repositorio → tipo de proyecto **"Other"/nativo iOS** (no Flutter ni React Native).
3. Codemagic detecta `codemagic.yaml`; selecciona **"Use codemagic.yaml"** (o "Switch to YAML configuration").
4. Pulsa **Start new build**, elige la rama y el workflow **REWIND - Compilación sin firma**.

### 3. Interpretar el resultado
- ✅ **Éxito**: el proyecto compila para simulador y dispositivo. Aparece `REWIND-unsigned.ipa` en *Artifacts*. Ese IPA **no está firmado y no se puede instalar** en un iPhone; solo demuestra que compila.
- ❌ **Fallo**: abre el paso que falló (rojo) y copia las líneas `error:` del log. También se guardan completos en `build/xcodebuild-*.log` dentro de *Artifacts*.

### 4. Generar un IPA firmado (cuando quieras probar en tu iPhone)
Sin Mac solo puedes probar en un iPhone real con un IPA firmado, y eso requiere **Apple Developer Program (99 USD/año)**:
1. En developer.apple.com registra el App ID `com.rewind.app` (o el que elijas; si lo cambias, edita `PRODUCT_BUNDLE_IDENTIFIER` en el proyecto y `bundle_identifier` en el YAML).
2. En App Store Connect ▸ Users and Access ▸ Integrations, crea una **clave API** (rol *App Manager*) y descarga el `.p8`.
3. En Codemagic ▸ Team settings ▸ Integrations ▸ App Store Connect, añade la clave y anota el nombre que le des.
4. En Codemagic ▸ Code signing identities, genera o sube el certificado de distribución y el perfil de aprovisionamiento.
5. En `codemagic.yaml` descomenta el bloque `rewind-signed`, sustituye `NOMBRE_DE_TU_INTEGRACION` y ejecútalo. Para TestFlight crea antes la app en App Store Connect.

Para instalar en tu iPhone sin pasar por la App Store usa `distribution_type: ad_hoc` y registra el UDID del dispositivo; para TestFlight, `app_store`.

## Reglas funcionales

- **Selección**: fecha original de captura (`creationDate`), día natural en la zona horaria del dispositivo, "hace un año" = `Calendar.date(byAdding: .year, value: -1)`.
- **29 de febrero** (`DateRules.swift`): hoy 29/feb → se revisa el 28/feb del año anterior. El 28/feb de un año no bisiesto cuyo año previo fue bisiesto revisa 28 **y** 29/feb, para que ese día no quede sin revisar.
- **Persistencia**: decisiones ligadas a `PHAsset.localIdentifier`; no se vuelven a mostrar salvo "Reiniciar sesión". Archivos borrados manualmente en Fotos se ignoran.
- **Borrado seguro**: izquierda solo marca. Borrar exige "CONFIRMAR LIMPIEZA" + diálogo propio + diálogo del sistema; los elementos van a "Eliminados recientemente" (30 días).
- **Espacio liberado**: solo se contabiliza cuando PhotoKit confirma el borrado.
- **Notificaciones**: se programan los próximos 14 días con el recuento real; los días sin pendientes no notifican. Se reprograman al abrir/cerrar la app.

## Limitaciones conocidas
- El tamaño de archivo usa la clave no documentada `fileSize` de `PHAssetResource`; si Apple la cambiara, el espacio se mostraría como 0.
- Sin pruebas automáticas ni localización más allá del español.
