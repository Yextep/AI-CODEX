# AI-CODEX

Script Bash para instalar o actualizar Codex CLI. El proyecto contiene un único punto de entrada, [`iou-codex.sh`](iou-codex.sh), con métodos de instalación mediante el instalador oficial, npm o los binarios publicados en `openai/codex`.

## Funciones

- Instala la versión más reciente o una versión indicada con `--version`.
- Detecta una instalación existente y comprueba la versión del ejecutable.
- Prepara los requisitos del sistema mediante `apt-get` en Debian/Ubuntu y comprueba `bubblewrap` en Linux.
- Descarga los archivos con `curl` o `wget`, con reintentos.
- Para el método binario, crea una copia de respaldo de una instalación existente y verifica el nuevo ejecutable antes de sustituirlo.
- Usa un bloqueo temporal para evitar instalaciones simultáneas y registra la salida en un archivo de log.
- Comprueba el arranque del daemon cuando la versión instalada ofrece ese comando.

## Requisitos

- Bash y acceso a Internet.
- `curl` o `wget`, además de `tar`, `gzip`, `mktemp`, `tee` e `install`.
- En Linux, `bubblewrap` debe estar instalado y su comando `bwrap` debe poder ejecutarse. La preparación automática de paquetes requiere root o `sudo` cuando hay dependencias pendientes.
- El método `npm` requiere Node.js y npm; en sistemas con `apt-get`, el script intenta instalarlos si faltan.
- El método `binary` contempla Linux y macOS en arquitecturas `x86_64` y `aarch64`/`arm64`. En Linux selecciona el archivo de distribución `musl`.

Los métodos `auto` y `official` usan el mismo instalador y no necesitan Node.js ni npm. `auto` no encadena automáticamente los otros métodos si el instalador falla.

## Uso

Desde la carpeta del repositorio:

```bash
# Consultar las opciones
bash iou-codex.sh --help

# Instalar o actualizar con el método predeterminado
bash iou-codex.sh

# Elegir una carpeta de instalación para el usuario actual
bash iou-codex.sh --install-dir "$HOME/.local/bin"

# Utilizar uno de los métodos alternativos
bash iou-codex.sh --method binary --install-dir "$HOME/.local/bin"
bash iou-codex.sh --method npm
```

Para fijar una versión, añade `--version VERSION`, sustituyendo `VERSION` por una versión publicada. El script admite números de versión con el formato `X.Y.Z`, con un sufijo de prepublicación opcional.

## Opciones

| Opción | Comportamiento |
| --- | --- |
| `--method auto` | Ejecuta el instalador oficial; es el valor predeterminado. |
| `--method official` | Ejecuta explícitamente el instalador de `https://chatgpt.com/codex/install.sh`. |
| `--method npm` | Instala el paquete global `@openai/codex` mediante npm. |
| `--method binary` | Descarga e instala un binario de las releases de `openai/codex`. |
| `--version VERSION` | Solicita una versión concreta; si se omite, usa la más reciente. |
| `--install-dir DIR` | Selecciona la carpeta de destino para `auto`, `official` o `binary`. |
| `--force` | Reinstala con `npm` o `binary` aunque la versión actual coincida. |
| `-h`, `--help` | Muestra la ayuda. |

## Ubicación y registro

- `CODEX_INSTALL_DIR` permite establecer el directorio de instalación mediante una variable de entorno.
- El método oficial usa `$HOME/.local/bin` si no se indica otro directorio.
- El método binario intenta reutilizar un ejecutable existente que pueda escribir; en su defecto, considera `/usr/local/bin` y después `$HOME/.local/bin`.
- `LOG_FILE` permite cambiar el archivo de registro. Su valor predeterminado es `/tmp/codex-install-update.log`.
- El bloqueo se guarda en `/tmp/codex-install-update.lock`.

Ejecuta el script con el usuario que utilizará Codex. La instalación de paquetes del sistema usa elevación de privilegios cuando es necesaria. Si el directorio elegido no está en `PATH`, el script muestra cómo añadirlo. Tras una actualización, reinicia las sesiones de Codex que ya estaban abiertas.

## Alcance

Este repositorio automatiza la instalación y las comprobaciones descritas. Las descargas, las versiones disponibles y el funcionamiento del instalador oficial dependen de servicios externos. Revisa el log si una instalación o la comprobación del daemon falla.
