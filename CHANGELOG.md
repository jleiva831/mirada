# Cambios

## Sin publicar

- **AppImage actualizable**: el AppImage trae información de actualización y cada versión publica su `.zsync`, así que se puede actualizar con [AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate) o Gear Lever descargando solo lo que cambió.
- **Metadatos AppStream** (`io.github.jleiva831.mirada.metainfo.xml`) en el `.deb` y el AppImage: los centros de software y catálogos de AppImage muestran descripción, capturas y versiones.
- El lanzador ya no declara dos categorías principales, que podían hacer aparecer Mirada dos veces en el menú.

## 0.4.1 — 2026-11-26

- **Instaladores**: paquete `.deb` (Debian 12+ / Ubuntu 22.04+) y **AppImage** (x86_64), con Python y Qt incluidos; no hace falta instalar nada más. Se adjuntan a cada versión en GitHub. Gracias a @Pdzly (#1).

## 0.4.0 — 2026-11-26

- **Calibración de ruido**: en Ajustes, el botón *Calibrar con 3 s de silencio* mide el ruido de fondo (ventilador, teclado, calle) y ajusta la sensibilidad sola. Ignora clics aislados y avisa si hay demasiado ruido para usar la voz.

## 0.3.0 — 2026-11-25

- El notch se pone **bajo el panel superior** (KDE, GNOME, XFCE…) en vez de quedar tapado por él. Opción *Sobre el panel* para paneles que se ocultan solos.
- **Elegir pantalla** en Ajustes, para notebooks con monitor externo. Si el monitor se desconecta, vuelve a la principal.
- **Posición de la cámara**: centro, izquierda, derecha o porcentaje exacto; ajuste fino con ← / → en el prompter.
- El ancho del notch es un **porcentaje de la pantalla**, así que se ve igual de proporcionado en cualquier resolución.
- Se reubica solo al cambiar la resolución, el panel o los monitores.
- Una ventana flotante que quedó fuera de pantalla (monitor desconectado) vuelve a una pantalla visible.
- **Ahorro de batería**: menos redibujos por segundo mientras está en pausa.
- Nota: la opción antigua `notch_width` (px) se reemplaza por `notch_width_pct`; el ancho vuelve al valor por defecto.

## 0.2.0 — 2026-11-25

- Código abierto con licencia MIT; Qt pasa de PyQt6 a PySide6 (LGPL).
- Código separado en módulos e instalable como paquete (`pip`, `pipx`, `uv`).
- Configuración validada al cargar: un archivo dañado ya no impide abrir Mirada.
- Guardado atómico de la configuración.
- Control remoto: código secreto más largo, comparación en tiempo constante y solo comandos conocidos.
- Instalador: se corrige el falso aviso de bibliotecas faltantes; se agrega `uninstall.sh` e icono propio.
- Opciones `--version` y `--help`.
- Tests e integración continua en GitHub Actions.

## 0.1.0

- Primera versión: modo notch y flotante, seguimiento por voz, secciones y control remoto.
