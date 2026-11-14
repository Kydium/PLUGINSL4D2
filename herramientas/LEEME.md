# Herramientas del servidor

Para dejar todo funcionando en una PC nueva (o despues de formatear):

1. Instala **Python** (marca "Add python.exe to PATH") y **Git for Windows**.
2. Descarga este repo (boton verde **Code > Download ZIP**), descomprimelo y pon la carpeta
   `herramientas` donde quieras tener todo (ej. `D:\Servidor`).
3. Abre **instalar.bat**.
4. El instalador busca solo el Left 4 Dead 2 en todos tus discos y bibliotecas de Steam,
   te muestra un resumen y solo pregunta **¿Instalar con esto?** (Enter = si).

Todo queda en la misma carpeta del instalador: los repos (`kdm`, `PLUGINSL4D2`) y el `watcher`.
El watcher queda en el inicio de Windows y arranca solo. Si faltan plugins en `scripting`,
ofrece copiarlos desde el repo.

## Que hace el watcher

- Cuando el plugin SR genera las paginas (`data/sr_web_out`), las sube al repo de la pagina.
- Cuando cambias un plugin propio (`cc_*.sp`, `cl4d2_*.sp` en `scripting`), lo sube al repo
  de plugins con su version. Las versiones anteriores no se borran: quedan en `<plugin>/versiones/`.

Para cambiar carpetas o repos despues, vuelve a ejecutar `instalar.bat` o edita `watcher_config.json`.
Log: `logs/watcher.log` dentro de la carpeta del watcher.
