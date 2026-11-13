import os
import shutil
import sys
import zipfile
from pathlib import Path
import PyInstaller.__main__

BASE_DIR = Path(__file__).resolve().parent


def _common_pyinstaller_args(name: str, mode_flag: str) -> list[str]:
    """Construye los argumentos compartidos de PyInstaller para --onefile y --onedir."""
    args = [
        str(BASE_DIR / "main.py"),
        f"--name={name}",
        f"--icon={BASE_DIR / 'icon.ico'}",
        mode_flag,
        "--windowed",
        "--noconfirm",
        "--clean",
        f"--add-data={BASE_DIR / 'web' / 'templates'};web/templates",
        f"--add-data={BASE_DIR / 'web' / 'static'};web/static",
        "--collect-all=playwright",
        "--hidden-import=uvicorn.logging",
        "--hidden-import=uvicorn.loops",
        "--hidden-import=uvicorn.loops.auto",
        "--hidden-import=uvicorn.protocols",
        "--hidden-import=uvicorn.protocols.http",
        "--hidden-import=uvicorn.protocols.http.auto",
        "--hidden-import=uvicorn.protocols.websockets",
        "--hidden-import=uvicorn.protocols.websockets.auto",
        "--hidden-import=uvicorn.lifespan",
        "--hidden-import=uvicorn.lifespan.on",
        "--hidden-import=starlette.responses",
        "--hidden-import=starlette.requests",
        "--hidden-import=jinja2",
        "--hidden-import=qrcode",
        "--hidden-import=PIL",
        "--hidden-import=tkinter",
        "--hidden-import=tkinter.filedialog",
        "--collect-all=webview",
        "--collect-all=pythonnet",
        "--collect-all=clr_loader",
    ]
    if (BASE_DIR / "icon.ico").exists():
        args.append(f"--add-data={BASE_DIR / 'icon.ico'};.")
    return args


def build(build_zip: bool = True):
    print("=" * 60)
    print(" Compilando Aula-Scrapt para Windows (.exe standalone + .zip)")
    print("=" * 60)

    dist_dir = BASE_DIR / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)

    # 1. Compilar ejecutable standalone (--onefile) para descarga y auto-update directo
    print("\n[1/2] Compilando Aula-Scrapt-Windows.exe (--onefile)...")
    PyInstaller.__main__.run(_common_pyinstaller_args("Aula-Scrapt-Windows", "--onefile"))

    onefile_exe = dist_dir / "Aula-Scrapt-Windows.exe"
    if onefile_exe.exists():
        size_mb = round(onefile_exe.stat().st_size / (1024 * 1024), 1)
        print(f" Ejecutable standalone creado: {onefile_exe} ({size_mb} MB)")

    # 2. Compilar version portable (--onedir) + ZIP
    if build_zip:
        print("\n[2/2] Compilando version portable Aula-Scrapt.exe (--onedir)...")
        PyInstaller.__main__.run(_common_pyinstaller_args("Aula-Scrapt", "--onedir"))

        output_folder = dist_dir / "Aula-Scrapt"
        if output_folder.exists():
            if (BASE_DIR / "icon.ico").exists():
                shutil.copy(BASE_DIR / "icon.ico", output_folder / "icon.ico")

            zip_path = dist_dir / "Aula-Scrapt-Windows.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
                for root, _dirs, files in os.walk(output_folder):
                    for file in files:
                        file_path = Path(root) / file
                        arcname = file_path.relative_to(dist_dir)
                        zipf.write(file_path, arcname)

            print("\n" + "=" * 60)
            print(" Compilacion exitosa!")
            print(f" Ejecutable standalone: {onefile_exe}")
            print(f" Carpeta portable:     {output_folder}")
            print(f" Archivo ZIP:          {zip_path} ({round(zip_path.stat().st_size / (1024 * 1024), 1)} MB)")
            print("=" * 60 + "\n")


if __name__ == "__main__":
    onefile_only = "--onefile-only" in sys.argv
    build(build_zip=not onefile_only)
