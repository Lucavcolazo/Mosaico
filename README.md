# Mosaico

Widgets animados para el escritorio de macOS, hechos con SwiftUI. Usan una estética de
mosaico de píxeles: barras, calendarios y portadas armadas con cuadraditos.

A diferencia de los widgets de WidgetKit, cada widget de Mosaico es una ventana sin bordes
que vive en el escritorio, debajo de tus ventanas. Por eso puede tener animaciones continuas,
hover y botones.

## Widgets

| Widget | Qué muestra |
|---|---|
| **Almacenamiento** | Barra de píxeles por categoría (Apps, Desarrollo, Fotos, Datos de apps…), con lo que más ocupa al pasar el mouse. Limpia cachés y vacía la Papelera con una animación de partículas. Si conectás un disco externo, aparece un selector para verlo y expulsarlo. |
| **Calendario** | El mes entero. Cada día se "llena" de píxeles según lo ocupado que está, con los colores de tus calendarios, y abajo muestra el próximo evento. |
| **Reloj** | Hora digital minimalista en matriz de puntos. |
| **Música (Spotify)** | Portada en píxeles, barra de progreso y controles (±10 s, anterior, play/pausa, siguiente). |
| **Clima** | Ícono animado en pixel art, próximas 24 h como columnas de píxeles y los próximos 7 días ([Open-Meteo](https://open-meteo.com), sin cuenta). |
| **Mascota** | Los ojos de un robot en vivo, leídos de su stream de eventos (SSE). Detalles abajo. |

Cada widget se activa desde el menú de la barra superior (**Widgets**) y se redimensiona
desde su esquina inferior derecha. El menú **Estilo** cambia entre *Sólido*, *Vidrio líquido*
y *Vidrio esmerilado*.

## Requisitos

- macOS 15 o posterior. El estilo *Vidrio líquido* necesita macOS 26 o posterior.
- Las Command Line Tools de Xcode (`xcode-select --install`). No hace falta Xcode completo.

## Compilar y abrir

```bash
./scripts/build-app.sh
open build/Mosaico.app
```

El script compila en modo release y arma `build/Mosaico.app`. Firma la app con un
certificado local que crea la primera vez y guarda en un llavero propio, en
`~/Library/Application Support/Mosaico/signing`. Como la firma es siempre la misma, macOS
reconoce la app entre compilaciones y no vuelve a pedir los permisos.

Para verla con datos de ejemplo, sin tocar el disco ni pedir permisos:

```bash
open build/Mosaico.app --args --demo
```

El ícono se genera con `swift scripts/make-icon.swift`, que escribe `Support/AppIcon.icns`.

## Permisos

macOS los pide una sola vez, a medida que cada widget los necesita:

- **Documentos, Escritorio y Descargas:** para medir cuánto ocupan.
- **Acceso total al disco** (opcional): para medir la Papelera.
- **Calendario:** para los eventos.
- **Automatización de Spotify:** para leer qué suena y controlarlo.
- **Ubicación:** para el clima. Se redondea a ~1 km antes de consultar Open-Meteo.

## Mascota (robot por SSE)

El widget se conecta a `http://<host>:<puerto>/stream`, un stream de Server-Sent Events con:

- `event: f` → `{"o": [ojo0, ojo1], "b": brillo}`. Cada ojo viene en base64: 1024 bytes,
  128×64 a 1 bit, 16 bytes por fila, y el bit más alto es el píxel de la izquierda.
- `event: e` → el estado del robot (el widget lo ignora; solo muestra los ojos).

Al tocar los ojos se manda `POST /evento` con `{"type":"touch"}`. Sin conexión, los ojos se
ven cerrados y la app reintenta sola.

La dirección del robot se configura desde el menú: **Dirección de LuckyPy…**. Podés poner
varias separadas por coma (por ejemplo la IP de Tailscale y la local como respaldo) y se
prueban en orden. Queda guardada solo en tu Mac, no en el código.

> El robot sirve HTTP sin cifrar, y App Transport Security no admite excepciones por IP.
> Por eso la app permite cargas HTTP (`NSAllowsArbitraryLoads`). El resto de las conexiones
> (Open-Meteo y las portadas de Spotify) usan HTTPS.

## Estructura

```
Sources/Mosaico/
  Shell/      App, menú de la barra y ventanas de widget (nivel escritorio)
  Bar/        Piezas compartidas: barra de píxeles, animador, marco de tarjeta, estilos
  Storage/    Almacenamiento (escaneo, categorías, selector de disco)
  External/   Discos externos
  Calendar/   Calendario (EventKit)
  Clock/      Reloj
  NowPlaying/ Música (Spotify por AppleScript)
  Weather/    Clima (CoreLocation + Open-Meteo)
  Mascota/    Ojos del robot por SSE
Support/Info.plist
scripts/build-app.sh
```

## Rendimiento

Los widgets solo dibujan cuando algo cambia y se pausan cuando una ventana los tapa. En
reposo, la app usa ~0,1 % de CPU, y ~0,5 % con los ojos del robot en vivo.
