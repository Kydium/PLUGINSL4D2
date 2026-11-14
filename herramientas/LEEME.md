# Herramientas del servidor

Para dejar todo funcionando en una PC nueva (o despues de formatear):

1. Instala **Python** (marca "Add python.exe to PATH") y **Git for Windows**.
2. Descarga este repo (boton verde **Code > Download ZIP**) y descomprimelo.
3. Entra a la carpeta `herramientas` y abre **instalar.bat**.
4. Responde las preguntas (Enter = valor por defecto):
   - carpeta del Left 4 Dead 2
   - carpeta donde van los repos (ej. `E:\L4D2SVR`)
   - tu usuario de GitHub y el nombre de los repos (pagina y plugins)
   - dominio propio de la pagina (si tienes)

El instalador clona los repos, copia `watcher.py` a su carpeta con su `watcher_config.json`,
lo pone en el inicio de Windows y lo arranca. Si faltan plugins en `scripting`, ofrece copiarlos.

## Que hace el watcher

- Cuando el plugin SR genera las paginas (`data/sr_web_out`), las sube al repo de la pagina.
- Cuando cambias un plugin propio (`cc_*.sp`, `cl4d2_*.sp` en `scripting`), lo sube al repo
  de plugins con su version. Las versiones anteriores no se borran: quedan en `<plugin>/versiones/`.

Para cambiar carpetas o repos despues, vuelve a ejecutar `instalar.bat` o edita `watcher_config.json`.
Log: `logs/watcher.log` dentro de la carpeta del watcher.
