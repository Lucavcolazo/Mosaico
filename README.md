# Mosaico

Widgets para el escritorio de macOS con estética de píxeles, hechos en SwiftUI.

<!-- Video de los widgets: arrastralo acá al editar en GitHub -->

## Widgets

- **Almacenamiento**: el disco por categorías. Limpia cachés y la Papelera, y muestra los discos externos.
- **Calendario**: el mes entero con tus eventos.
- **Clima**: el tiempo ahora, las próximas 24 horas y los próximos 7 días.
- **Música**: lo que suena en Spotify, con controles.
- **Batería**: tu Mac y tus dispositivos Bluetooth.
- **Reloj**: hora digital en matriz de puntos.
- **Mascota**: los ojos de un robot en vivo (Raspberry Pi por SSE).

Los widgets se activan desde el ícono de Mosaico en la barra de menú. Se mueven
arrastrándolos y se redimensionan desde la esquina inferior derecha.

## Instalar

Requiere macOS 15 o posterior y las Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Lucavcolazo/Mosaico.git
cd Mosaico
./scripts/build-app.sh
ditto build/Mosaico.app /Applications/Mosaico.app
open /Applications/Mosaico.app
```

Para que arranque solo al prender la Mac, activá **Abrir al iniciar sesión** en el menú de Mosaico.

## Notas

- macOS pide los permisos una sola vez, según el widget: carpetas, calendario, ubicación y Spotify.
- La dirección del robot se configura en el menú, en **Dirección de LuckyPy…**.
- Es liviano: en reposo usa menos del 1 % de CPU.
