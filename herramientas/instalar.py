# -*- coding: utf-8 -*-
"""
instalar.py - Instala el watcher de ClubCampestre desde cero (lo abre instalar.bat).

Busca solo el Left 4 Dead 2 (en cualquier disco), instala todo en la carpeta
donde esta este archivo, clona los repos, deja el watcher con su configuracion,
lo pone en el inicio de Windows y lo arranca. Solo pide confirmar.
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
    url = f"https://github.com/{usuario}/{repo}.git"
    destino = repo_existente(repo, base) or (Path(base) / repo)
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


def buscar_l4d2():
    """Busca la carpeta del Left 4 Dead 2 en todas las bibliotecas de Steam y discos."""
    import re, string
    raices = []
    try:
        import winreg
        for hive, clave, valor in [(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                                   (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                                   (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath")]:
            try:
                with winreg.OpenKey(hive, clave) as k:
                    raices.append(Path(winreg.QueryValueEx(k, valor)[0]))
            except OSError:
                pass
    except ImportError:
        pass
    bibliotecas = []
    for r in raices:
        bibliotecas.append(r)
        vdf = r / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text("utf-8", "replace")):
                bibliotecas.append(Path(m.group(1).replace("\\\\", "\\")))
    for letra in string.ascii_uppercase[2:]:
        d = Path(f"{letra}:\\")
        if d.exists():
            for sub in ["Steam", "SteamLibrary", "Program Files (x86)\\Steam", "Program Files\\Steam", "Juegos\\Steam", "Games\\Steam"]:
                bibliotecas.append(d / sub)
    hallados = []
    for b in bibliotecas:
        c = b / "steamapps" / "common" / "Left 4 Dead 2"
        try:
            if (c / "left4dead2").exists() and os.path.normcase(os.path.normpath(str(c))) not in \
                    [os.path.normcase(os.path.normpath(str(h))) for h in hallados]:
                hallados.append(c)
        except OSError:
            pass
    return hallados


def repo_existente(nombre, base):
    """Si el repo ya esta clonado en la carpeta base o en la de arriba, lo usa."""
    for d in [Path(base) / nombre, Path(base).parent / nombre]:
        if (d / ".git").exists():
            return d
    return None


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

    # ---- valores detectados ----
    titulo("BUSCANDO EL LEFT 4 DEAD 2...")
    hallados = buscar_l4d2()
    if len(hallados) == 1:
        l4d2 = str(hallados[0])
    elif len(hallados) > 1:
        print("Encontre varios:")
        for i, h in enumerate(hallados, 1):
            print(f"  {i}. {h}")
        n = preguntar("¿Cual uso? (numero)", "1")
        l4d2 = str(hallados[int(n) - 1]) if n.isdigit() and 0 < int(n) <= len(hallados) else str(hallados[0])
    else:
        print("No lo encontre solo.")
        l4d2 = preguntar("Pega la carpeta del Left 4 Dead 2 (la que tiene left4dead2 adentro)")
    base = str(AQUI)
    usuario, repo_web, repo_pl = "Kydium", "kdm", "PLUGINSL4D2"

    def resumen():
        sm = Path(l4d2) / "left4dead2" / "addons" / "sourcemod"
        print()
        print(f"  Juego:          {l4d2}" + ("" if sm.exists() else "   (OJO: no tiene SourceMod)"))
        print(f"  Se instala en:  {base}")
        print(f"  GitHub:         {usuario}  |  pagina: {repo_web or '-'}  |  plugins: {repo_pl or '-'}")

    titulo("ESTO ES LO QUE VOY A USAR")
    resumen()
    print()
    if not si_no("¿Instalar con esto?"):
        l4d2 = preguntar("Carpeta del Left 4 Dead 2", l4d2)
        base = preguntar("Carpeta donde se instala (repos y watcher)", base)
        usuario = preguntar("Tu usuario de GitHub", usuario)
        repo_web = preguntar("Repo de la pagina (vacio = no usar)", repo_web)
        repo_pl = preguntar("Repo de los plugins (vacio = no usar)", repo_pl)
        titulo("QUEDA ASI")
        resumen()
    Path(base).mkdir(parents=True, exist_ok=True)
    print("\nLos repos tienen que existir en GitHub (si son nuevos, crealos vacios en github.com/new).")

    titulo("CLONANDO")
    dir_web = url_web = dir_pl = url_pl = None
    if repo_web:
        dir_web, url_web = clonar(usuario, repo_web, base)
    if repo_pl:
        dir_pl, url_pl = clonar(usuario, repo_pl, base)

    # dominio propio de la pagina (archivo CNAME)
    if dir_web:
        cname = dir_web / "CNAME"
        actual = cname.read_text("utf-8").strip() if cname.exists() else ""
        dom = actual or preguntar("Dominio propio de la pagina (vacio = ninguno)")
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
    titulo("WATCHER")
    carpeta_w = Path(base) / "watcher"
    carpeta_w.mkdir(parents=True, exist_ok=True)
    for nombre in ["watcher.py", "detener_watcher.bat", "reiniciar_watcher.bat"]:
        origen = AQUI / nombre
        if origen.exists() and origen.resolve() != (carpeta_w / nombre).resolve():
            shutil.copy2(origen, carpeta_w / nombre)
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
    if True:   # que arranque solo al prender la PC
        r = subprocess.run(["reg", "add", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                            "/v", "WatcherKDM", "/t", "REG_SZ", "/d", comando, "/f"],
                           capture_output=True, text=True)
        print("  Listo, queda en el inicio." if r.returncode == 0 else "  No se pudo: " + r.stderr.strip())

    if True:   # arrancarlo ya (cierra el que este abierto)
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
