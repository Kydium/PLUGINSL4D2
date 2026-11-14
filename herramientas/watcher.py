#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
watcher.py - Web Watcher (ranking SR -> GitHub Pages) + respaldo de plugins
Tambien vigila los plugins propios (cc_*.sp, cl4d2_*.sp) de la carpeta scripting
y cuando cambia uno lo sube a github.com/Kydium/PLUGINSL4D2 con su version,
sin borrar las versiones anteriores (quedan en <plugin>/versiones/).
Monitorea data/sr_web_out/ (paginas que genera el plugin SR con el Top 10)
y cuando cambian las copia a E:\\L4D2SVR\\kdm\\ (repo de GitHub Pages) y hace git push.
Link: https://kydium.github.io/kdm/

Ademas sirve la carpeta kdm/ por HTTP (sin https) en el puerto WEB_PUERTO,
para el MOTD del juego: su navegador no abre paginas https (error -107).
Con un tunel TCP de Playit a ese puerto, todos pueden verla.
"""

import re
import sys
import time
import shutil
import subprocess
import threading
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from datetime import datetime

# ─── CONFIGURACION ────────────────────────────────────────────────────────────
# Se lee de watcher_config.json (al lado de este archivo). Lo crea instalar.bat.
# Si no existe, se usan los valores de abajo.
import json
AQUI = Path(__file__).resolve().parent
CFG  = {
    "l4d2":         r"E:\Steam\steamapps\common\Left 4 Dead 2",
    "repo_web":     r"E:\L4D2SVR\kdm",
    "repo_plugins": r"E:\L4D2SVR\PLUGINSL4D2",
    "url_plugins":  "https://github.com/Kydium/PLUGINSL4D2.git",
    "rama":         "main",
}
try:
    CFG.update(json.loads((AQUI / "watcher_config.json").read_text("utf-8")))
except Exception:
    pass

SM          = Path(CFG["l4d2"]) / "left4dead2" / "addons" / "sourcemod"
# Paginas que genera el plugin SR (cada .html se copia al repo web y se sube)
WEB_OUT     = SM / "data" / "sr_web_out"
REPO_DIR    = Path(CFG["repo_web"]) if CFG.get("repo_web") else None
RAMA        = CFG.get("rama", "main")
LOG_FILE    = AQUI / "logs" / "watcher.log"
GIT_MSG     = "auto: actualizar paginas (top 10)"
POLL_SECS   = 3

# Plugins propios -> repo de plugins (cada cambio guarda una version nueva)
PLUGINS_SRC   = SM / "scripting"
PLUGINS_PAT   = ["cc_*.sp", "cl4d2_*.sp"]
PLUGINS_REPO  = Path(CFG["repo_plugins"]) if CFG.get("repo_plugins") else None
PLUGINS_URL   = CFG.get("url_plugins", "")
PLUGINS_ESPERA = 10   # segundos sin cambios antes de subir (por si lo estas editando)

# Servidor web local (0 = apagado; ya no se usa)
WEB_PUERTO  = 0
# ─────────────────────────────────────────────────────────────────────────────


def log(msg):
    ts   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def git(args, cwd=None):
    result = subprocess.run(
        ["git"] + args,
        cwd=str(cwd or REPO_DIR),
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        if "nothing to commit" in result.stdout + result.stderr:
            return False
        log(f"Git error ({' '.join(args)}): {result.stderr.strip()}")
        return False
    return True


def git_push(nombres):
    for n in nombres:
        git(["add", n])
    ok = git(["commit", "-m", GIT_MSG])
    if not ok:
        log("Sin cambios nuevos.")
        return
    # Traer antes lo que haya en GitHub (por si se cambio algo desde la web)
    git(["pull", "--rebase", "--autostash", "origin", RAMA])
    if git(["push", "origin", RAMA]):
        log("Push a GitHub Pages completado.")
    else:
        log("No se pudo hacer push (revisa el log de arriba).")


def sincronizar(motivo):
    """Copia a kdm/ las paginas que cambiaron. Devuelve la lista copiada."""
    if not REPO_DIR or not WEB_OUT.exists():
        return []
    copiadas = []
    for src in sorted(WEB_OUT.glob("*.html")):
        dst = REPO_DIR / src.name
        try:
            if dst.exists() and dst.read_bytes() == src.read_bytes():
                continue
            shutil.copy2(src, dst)
            copiadas.append(src.name)
        except Exception as e:
            log(f"No se pudo copiar {src.name}: {e}")
    if copiadas:
        log(f"{motivo}: {', '.join(copiadas)}. Haciendo git push...")
        git_push(copiadas)
    return copiadas


# ─── RESPALDO DE PLUGINS ─────────────────────────────────────────────────────
def version_de(texto):
    """Lee la version del plugin (myinfo version = "x" o el #define que use)."""
    m = re.search(r'version\s*=\s*"([^"]+)"', texto)
    if m:
        return m.group(1).strip()
    m = re.search(r'version\s*=\s*([A-Za-z_][A-Za-z0-9_]*)', texto)
    if m:
        d = re.search(r'#define\s+' + re.escape(m.group(1)) + r'\s+"([^"]+)"', texto)
        if d:
            return d.group(1).strip()
    return "sin-version"


def nombre_de(texto, defecto):
    m = re.search(r'Plugin\s+myinfo\s*=\s*\{[^}]*?name\s*=\s*"([^"]+)"', texto, re.S)
    return m.group(1) if m else defecto


def guardar_plugin(src, repo, cuando):
    """Copia un plugin al repo. Devuelve (archivos_cambiados, version) o None si no cambio."""
    datos = src.read_bytes()
    base  = src.stem
    carpeta = repo / base
    ultimo  = carpeta / src.name
    if ultimo.exists() and ultimo.read_bytes() == datos:
        return None
    texto = datos.decode("utf-8", "replace")
    ver   = version_de(texto)
    vdir  = carpeta / "versiones"
    vdir.mkdir(parents=True, exist_ok=True)
    # nombre de la version; si ya hay una con el mismo numero y otro contenido: _2, _3...
    destino, n = vdir / f"{base}_v{ver}.sp", 1
    while destino.exists() and destino.read_bytes() != datos:
        n += 1
        destino = vdir / f"{base}_v{ver}_{n}.sp"
    cambiados = []
    if not destino.exists():
        destino.write_bytes(datos)
        cambiados.append(destino)
        etiqueta = destino.stem.replace(base + "_", "")
        hist = carpeta / "HISTORIAL.md"
        nuevo = not hist.exists()
        with open(hist, "a", encoding="utf-8", newline="\n") as f:
            if nuevo:
                f.write(f"# {base}\n\n{nombre_de(texto, base)}\n\n| Version | Fecha | Archivo |\n|---|---|---|\n")
            f.write(f"| {etiqueta} | {cuando} | [versiones/{destino.name}](versiones/{destino.name}) |\n")
        cambiados.append(hist)
    ultimo.write_bytes(datos)
    cambiados.append(ultimo)
    return cambiados, destino.stem.replace(base + "_", "")


def readme_plugins(repo):
    filas = []
    for d in sorted(p for p in repo.iterdir() if p.is_dir() and not p.name.startswith(".")):
        sp = d / (d.name + ".sp")
        if not sp.exists():
            continue
        t = sp.read_text("utf-8", "replace")
        nv = len(list((d / "versiones").glob("*.sp"))) if (d / "versiones").exists() else 0
        filas.append(f"| [{d.name}]({d.name}/{d.name}.sp) | {nombre_de(t, d.name)} | {version_de(t)} | [{nv} guardadas]({d.name}/HISTORIAL.md) |")
    txt = ("# Plugins L4D2 - ClubCampestre\n\n"
           "Plugins de SourceMod del servidor competitivo ClubCampestre (Left 4 Dead 2).\n\n"
           "Cada carpeta tiene la version actual (`<plugin>.sp`) y todas las anteriores en `versiones/`.\n"
           "Se sube solo desde el servidor cada vez que cambia un plugin.\n\nPara instalar el watcher en una PC nueva: ver [herramientas/LEEME.md](herramientas/LEEME.md).\n\n"
           "| Plugin | Nombre | Version actual | Historial |\n|---|---|---|---|\n" + "\n".join(filas) + "\n")
    f = repo / "README.md"
    if not f.exists() or f.read_text("utf-8") != txt:
        f.write_text(txt, "utf-8", newline="\n")
        return [f]
    return []


def preparar_repo_plugins():
    if (PLUGINS_REPO / ".git").exists():
        return True
    if not PLUGINS_URL:
        return False
    log(f"Clonando {PLUGINS_URL} en {PLUGINS_REPO} ...")
    r = subprocess.run(["git", "clone", PLUGINS_URL, str(PLUGINS_REPO)], capture_output=True, text=True)
    if r.returncode != 0:
        log(f"No se pudo clonar el repo de plugins: {r.stderr.strip()}")
        return False
    return True


def sincronizar_plugins(motivo, src_dir=None, repo=None, push=True):
    src_dir = src_dir or PLUGINS_SRC
    repo    = repo or PLUGINS_REPO
    if not repo or not src_dir.exists():
        return []
    if push and not preparar_repo_plugins():
        return []
    if push:
        git(["pull", "--rebase", "--autostash", "origin", RAMA], cwd=repo)
    cuando = datetime.now().strftime("%Y-%m-%d %H:%M")
    hechos, archivos = [], []
    fuentes = sorted({p for pat in PLUGINS_PAT for p in src_dir.glob(pat)})
    for src in fuentes:
        try:
            if push and time.time() - src.stat().st_mtime < PLUGINS_ESPERA:
                continue   # lo estan editando, se sube en la siguiente vuelta
            r = guardar_plugin(src, repo, cuando)
            if r:
                archivos += r[0]
                hechos.append(f"{src.stem} {r[1]}")
        except Exception as e:
            log(f"No se pudo respaldar {src.name}: {e}")
    if not hechos:
        return []
    archivos += readme_plugins(repo)
    if not push:
        return hechos
    for a in archivos:
        git(["add", str(a.relative_to(repo))], cwd=repo)
    msg = "Actualizar " + ", ".join(hechos) if len(hechos) <= 4 else f"Actualizar {len(hechos)} plugins"
    if git(["commit", "-m", msg], cwd=repo) and git(["push", "origin", RAMA], cwd=repo):
        log(f"{motivo}: plugins subidos a GitHub ({', '.join(hechos)}).")
    else:
        log("No se pudo subir los plugins (revisa el log de arriba).")
    return hechos


def firma_plugins():
    if not PLUGINS_REPO or not PLUGINS_SRC.exists():
        return ()
    return tuple(sorted((p.name, p.stat().st_mtime) for pat in PLUGINS_PAT for p in PLUGINS_SRC.glob(pat)))


class MotdHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(REPO_DIR or AQUI), **kwargs)

    def end_headers(self):
        # Que siempre muestre el ranking al dia
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        super().end_headers()

    def guess_type(self, path):
        p = str(path).lower()
        if p.endswith(".woff2"): return "font/woff2"
        if p.endswith(".woff"):  return "font/woff"
        if p.endswith(".html"):  return "text/html; charset=utf-8"
        return super().guess_type(path)

    def log_message(self, fmt, *args):
        pass   # sin spam en la consola


def iniciar_web():
    if not WEB_PUERTO:
        return
    try:
        srv = ThreadingHTTPServer(("0.0.0.0", WEB_PUERTO), MotdHandler)
    except Exception as e:
        log(f"No se pudo abrir el servidor web en el puerto {WEB_PUERTO}: {e}")
        return
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"Servidor web del MOTD: http://127.0.0.1:{WEB_PUERTO}/comandos.html")


def firma():
    """Fechas de modificacion de las paginas generadas (para notar cambios)."""
    if not WEB_OUT.exists():
        return ()
    return tuple((p.name, p.stat().st_mtime) for p in sorted(WEB_OUT.glob("*.html")))


def main():
    log("Watcher iniciado.")
    iniciar_web()
    log(f"Monitoreando: {WEB_OUT}")
    log(f"Destino:      {REPO_DIR}")
    log(f"Plugins:      {PLUGINS_SRC} -> {PLUGINS_REPO}")

    # Al arrancar: subir lo que este pendiente
    try:
        sincronizar("Pendiente al iniciar")
    except Exception as e:
        log(f"Error al iniciar: {e}")
    try:
        sincronizar_plugins("Plugins pendientes al iniciar")
    except Exception as e:
        log(f"Error con los plugins: {e}")

    prev = firma()
    prevp, pendiente = firma_plugins(), 0
    while True:
        try:
            ahora = firma()
            if ahora != prev:
                prev = ahora
                time.sleep(1)   # que el plugin termine de escribir
                sincronizar("Paginas actualizadas")
        except Exception as e:
            log(f"Error: {e}")
        try:
            ahora = firma_plugins()
            if ahora != prevp:
                prevp, pendiente = ahora, time.time() + PLUGINS_ESPERA
            if pendiente and time.time() >= pendiente:
                pendiente = 0
                sincronizar_plugins("Plugin modificado")
        except Exception as e:
            log(f"Error con los plugins: {e}")
        time.sleep(POLL_SECS)


if __name__ == "__main__":
    main()
