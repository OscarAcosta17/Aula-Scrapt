import os
import shutil
import sys
import zipfile
from pathlib import Path
import PyInstaller.__main__

BASE_DIR = Path(__file__).resolve().parent

def build():
    print("=" * 60)
    print(" Compilando Aula-Scrapt como ejecutable portable de Windows")
    print("=" * 60)

    dist_dir = BASE_DIR / "dist"
    build_dir = BASE_DIR / "build"

    args = [
        str(BASE_DIR / "main.py"),
        "--name=Aula-Scrapt",
        f"--icon={BASE_DIR / 'icon.ico'}",
        "--onedir",
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

    print("Ejecutando PyInstaller...")
    PyInstaller.__main__.run(args)

    output_folder = dist_dir / "Aula-Scrapt"
    if output_folder.exists():
        if (BASE_DIR / "icon.ico").exists():
            shutil.copy(BASE_DIR / "icon.ico", output_folder / "icon.ico")
        print("\n" + "=" * 60)
        print(" Compilacion exitosa!")
        print(f" Carpeta del programa: {output_folder}")
        print(" Creando archivo .ZIP listo para compartir con amigos...")
        
        zip_path = dist_dir / "Aula-Scrapt-Windows.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for root, dirs, files in os.walk(output_folder):
                for file in files:
                    file_path = Path(root) / file
                    arcname = file_path.relative_to(dist_dir)
                    zipf.write(file_path, arcname)

        print(f" Archivo ZIP creado: {zip_path}")
        print(f" Tamano: {round(zip_path.stat().st_size / (1024 * 1024), 1)} MB")
        print("=" * 60 + "\n")

if __name__ == "__main__":
    build()
