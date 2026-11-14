# -*- coding: utf-8 -*-
"""
instalar.py - Instala el watcher de ClubCampestre desde cero (lo abre instalar.bat).

Pregunta las carpetas y los repos de GitHub, clona los repos, deja el watcher
en su propia carpeta con su configuracion y lo pone en el inicio de Windows.
Se puede volver a ejecutar cuando quieras: lo que ya existe no se borra.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent


def preguntar(texto, defecto=""):
    extra = f" [{defecto}]" if defecto else ""
    r = input(f"{texto}{extra}: ").strip().strip('"')
    return r or defecto


def si_no(texto, defecto=True):
    d = "S/n" if defecto else "s/N"
    r = input(f"{texto} ({d}): ").strip().lower()
    return defecto if not r else r.startswith("s")


def titulo(t):
    print()
    print("=" * 60)
    print(" " + t)
    print("=" * 60)


def git(args, cwd=None):
    r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def clonar(usuario, repo, base):
    """Clona github.com/usuario/repo en base/repo (si ya esta, lo deja)."""
    destino = Path(base) / repo
    url = f"https://github.com/{usuario}/{repo}.git"
    if (destino / ".git").exists():
        print(f"  Ya existe {destino} (no se toca). Actualizando...")
        git(["pull", "--rebase", "--autostash"], cwd=str(destino))
        return destino, url
    if destino.exists() and any(destino.iterdir()):
        print(f"  OJO: {destino} existe y no es un repo de git. Muevelo o borralo y vuelve a ejecutar.")
        return None, url
    print(f"  Clonando {url} ...")
    ok, out = git(["clone", url, str(destino)])
    if not ok:
        print("  No se pudo clonar:")
        print("  " + out.replace("\n", "\n  "))
        print("  Revisa que el repo exista en GitHub (puede estar vacio, pero debe existir).")
        return None, url
    print(f"  Listo: {destino}")
    return destino, url


def rama_de(repo_dir):
    ok, out = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=str(repo_dir))
    return out if ok and out and out != "HEAD" else "main"


def parar_watchers_viejos():
    ps = ("Get-CimInstance Win32_Process | Where-Object { ($_.Name -like 'python*') -and "
          "($_.CommandLine -like '*watcher.py*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)


def main():
    titulo("INSTALADOR DEL WATCHER - ClubCampestre")
    print("Enter = usar el valor entre [corchetes].")

    # ---- requisitos ----
    if shutil.which("git") is None:
        print("\nFalta Git. Instala Git for Windows (https://git-scm.com) y vuelve a ejecutar.")
        return
    nombre_git = git(["config", "--global", "user.name"])[1]
    correo_git = git(["config", "--global", "user.email"])[1]
    if not nombre_git or not correo_git:
        titulo("TU NOMBRE EN GIT (solo la primera vez)")
        git(["config", "--global", "user.name", preguntar("Tu nombre o usuario", "Kydium")])
        git(["config", "--global", "user.email", preguntar("Tu correo de GitHub")])

    # ---- carpetas ----
    titulo("1. CARPETAS")
    while True:
        l4d2 = preguntar("Carpeta del Left 4 Dead 2", r"E:\Steam\steamapps\common\Left 4 Dead 2")
        if (Path(l4d2) / "left4dead2" / "addons" / "sourcemod").exists():
            break
        print("  No encuentro left4dead2\\addons\\sourcemod ahi. Revisa la ruta (o instala SourceMod primero).")
        if not si_no("  ¿Escribirla de nuevo?"):
            break
    base = preguntar("Carpeta donde van los repos y el watcher", r"E:\L4D2SVR")
    Path(base).mkdir(parents=True, exist_ok=True)

    # ---- repos ----
    titulo("2. GITHUB")
    usuario = preguntar("Tu usuario de GitHub", "Kydium")
    print("\nRepo de la PAGINA (comandos, top 10, torneos). Vacio = no usar.")
    repo_web = preguntar("Nombre del repo de la pagina", "kdm")
    print("\nRepo de los PLUGINS (respaldo con versiones). Vacio = no usar.")
    repo_pl = preguntar("Nombre del repo de plugins", "PLUGINSL4D2")
    print("\nLos repos tienen que existir en GitHub (crealos vacios en github.com/new si no estan).")

    titulo("3. CLONANDO")
    dir_web = url_web = dir_pl = url_pl = None
    if repo_web:
        dir_web, url_web = clonar(usuario, repo_web, base)
    if repo_pl:
        dir_pl, url_pl = clonar(usuario, repo_pl, base)

    # dominio propio de la pagina (archivo CNAME)
    if dir_web:
        cname = dir_web / "CNAME"
        actual = cname.read_text("utf-8").strip() if cname.exists() else ""
        dom = preguntar("Dominio propio de la pagina (vacio = ninguno)", actual)
        if dom and dom != actual:
            cname.write_text(dom + "\n", "utf-8")
            git(["add", "CNAME"], cwd=str(dir_web))
            git(["commit", "-m", "CNAME"], cwd=str(dir_web))
            git(["push"], cwd=str(dir_web))

    # restaurar plugins despues de formatear
    if dir_pl:
        scripting = Path(l4d2) / "left4dead2" / "addons" / "sourcemod" / "scripting"
        faltan = [d for d in dir_pl.iterdir() if d.is_dir() and (d / (d.name + ".sp")).exists()
                  and not (scripting / (d.name + ".sp")).exists()]
        if faltan and scripting.exists():
            print(f"\nHay {len(faltan)} plugins en el repo que no estan en tu carpeta scripting:")
            print("  " + ", ".join(d.name for d in faltan))
            if si_no("¿Copiarlos a scripting? (para compilarlos)"):
                for d in faltan:
                    shutil.copy2(d / (d.name + ".sp"), scripting / (d.name + ".sp"))
                print("  Copiados.")

    # ---- watcher ----
    titulo("4. WATCHER")
    carpeta_w = Path(preguntar("Carpeta del watcher", str(Path(base) / "watcher")))
    carpeta_w.mkdir(parents=True, exist_ok=True)
    origen = AQUI / "watcher.py"
    if origen.resolve() != (carpeta_w / "watcher.py").resolve():
        shutil.copy2(origen, carpeta_w / "watcher.py")
    cfg = {
        "l4d2": l4d2,
        "repo_web": str(dir_web) if dir_web else "",
        "repo_plugins": str(dir_pl) if dir_pl else "",
        "url_plugins": url_pl or "",
        "rama": rama_de(dir_web) if dir_web else "main",
    }
    (carpeta_w / "watcher_config.json").write_text(json.dumps(cfg, indent=2, ensure_ascii=False), "utf-8")
    print(f"  Watcher en: {carpeta_w}")

    # ---- inicio de Windows ----
    pyw = Path(sys.executable).with_name("pythonw.exe")
    if not pyw.exists():
        pyw = Path(sys.executable)
    comando = f'"{pyw}" "{carpeta_w / "watcher.py"}"'
    if si_no("¿Que el watcher arranque solo al prender la PC?"):
        r = subprocess.run(["reg", "add", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                            "/v", "WatcherKDM", "/t", "REG_SZ", "/d", comando, "/f"],
                           capture_output=True, text=True)
        print("  Listo, queda en el inicio." if r.returncode == 0 else "  No se pudo: " + r.stderr.strip())

    if si_no("¿Arrancar el watcher ahora? (cierra el que este abierto)"):
        parar_watchers_viejos()
        subprocess.Popen([str(pyw), str(carpeta_w / "watcher.py")], cwd=str(carpeta_w),
                         creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))
        print(f"  Arrancado. Su log: {carpeta_w / 'logs' / 'watcher.log'}")

    titulo("TERMINADO")
    print("La primera vez que suba algo, Git puede abrir el navegador para iniciar sesion en GitHub.")
    print("Si algo falla, mira el log del watcher.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelado.")
