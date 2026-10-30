# Aula-Scrapt USM — Sincronizador de Material hacia Carpeta Local / Obsidian

Aplicación web local (PC y Teléfono) para listar cursos, secciones y archivos en **Aula USM** (`https://aula.usm.cl`) y descargarlos bajo demanda hacia cualquier carpeta de tu computador o biblioteca de **Obsidian**.

---

## Características Principales

- **100% Privado, Local y Portable:**
  - Sin servidores externos ni rutas fijas en el código. Cualquier persona que clone este repositorio puede elegir en qué carpeta de su PC guardar sus materiales usando el botón **"Elegir carpeta..."** (selector nativo de Windows) o escribiendo la ruta.
  - Tus cookies de sesión (`data/session.json`) y tu configuración personal (`data/settings.json`) se guardan localmente en `data/` y están excluidas de Git (`.gitignore`).
- **Diseño Compacto sin Scroll Infinito:**
  - La interfaz ocupa el alto de la ventana (`100vh`) con cabeceras compactas; el scroll ocurre únicamente dentro del listado de ramos/archivos.
  - **Ramos colapsados por defecto:** Al cargar tus cursos, todos vienen cerrados mostrando el resumen de archivos totales y pendientes.
  - **Agrupación por carpetas/secciones:** Al hacer clic en un ramo, se despliega dividido en sus respectivas secciones o carpetas de Aula USM, permitiendo abrir solo la carpeta que te interesa o marcar toda una carpeta con un clic.
- **Asociación Automática e Inteligente de Carpetas:**
  - Limpia automáticamente años/semestres (`(202602)`), códigos (`(INF266)`) y paralelos (`|Paralelos:200`), dejando únicamente el nombre limpio (`Sistemas de Gestión`).
  - Si en tu carpeta destino ya existen subcarpetas, las asocia automáticamente por similitud, y además puedes personalizar el nombre de la carpeta de cada ramo directamente en la cabecera del curso.
- **Cálculo de Peso/Tamaño y Progreso en Tiempo Real:**
  - Muestra el tamaño de cada archivo (`135 KB`, `2.4 MB`) y calcula en vivo el peso total seleccionado en la barra inferior (`11 archivos • 24.5 MB`).
  - Streaming con Server-Sent Events (SSE) con porcentaje de `0%` a `100%`, archivo actual y actualización visual archivo por archivo.
  - Botón "Marcar ramo" al desplegar cualquier asignatura para seleccionar todos sus archivos con un solo clic.
- **Generación Automática de Grafo `.md` para Obsidian e IA:**
  - Al descargar archivos, se crea o sobrescribe un índice maestro por ramo (`00 - Indice Aula - <Ramo>.md`) y sub-índices por sección (`00 - Seccion - <Seccion>.md`) con frontmatter YAML y `[[wikilinks]]` bidireccionales, optimizados tanto para la vista de grafo de Obsidian como para que agentes de IA localicen cualquier documento en un solo paso.

---

## Estructura del Proyecto

```text
Aula-Scrapt/
├── config.py                # Gestión de configuración dinámica (data/settings.json) y coincidencia de carpetas
├── main.py                  # Servidor FastAPI, selector nativo de carpetas (tkinter) y QR móvil
├── iniciar_aula_scrapt.bat  # Ejecutable de inicio rápido para Windows
├── requirements.txt         # Dependencias de Python
├── scraper/
│   ├── auth.py              # Login manual asistido (Playwright) y verificación estricta de sesión
│   ├── moodle_client.py     # Extractor de cursos (AJAX Moodle 4.x + HTML) y módulos por sección
│   └── obsidian_sync.py     # Comparador de archivos existentes y descargador bajo demanda
└── web/
    ├── templates/index.html # Interfaz compacta (100vh) sin emojis
    └── static/              # Estilos (style.css) y acordeones por ramo/sección (app.js)
```

---

## Instalación y Uso

### Opción A: Ejecutable Portable de Windows (Recomendada y para amigos)
No requiere instalar Python, Git ni librerías:
1. Descomprime **`dist/Aula-Scrapt-Windows.zip`** (o entra a `dist/Aula-Scrapt/`).
2. Haz doble clic en **`Aula-Scrapt.exe`**.
3. Se abrirá automáticamente tu navegador en `http://localhost:8000`.
4. Cuando termines, pulsa el botón **"Cerrar app"** en la barra superior para finalizar el programa.

### Opción B: Ejecución desde código fuente (Python)
1. Instalar dependencias:
   ```bash
   pip install -r requirements.txt
   ```
2. Ejecutar con doble clic en **`iniciar_aula_scrapt.bat`** o desde terminal:
   ```bash
   python main.py
   ```
3. Si deseas recompilar el ejecutable tras hacer cambios, ejecuta:
   ```bash
   compilar_exe.bat
   ```
