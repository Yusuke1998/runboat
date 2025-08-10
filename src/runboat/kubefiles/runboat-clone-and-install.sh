#!/bin/bash

set -exo pipefail

# Remove initialization sentinel and data, in case we are reinitializing.
rm -fr /mnt/data/*

# Remove addons dir, in case we are reinitializing after a previously
# failed installation.
rm -fr $ADDONS_DIR

# Download the repository at git reference into $ADDONS_DIR.
# We use curl instead of git clone because the git clone method used more than 1GB RAM,
# which exceeded the default pod memory limit.
mkdir -p $ADDONS_DIR
cd $ADDONS_DIR

echo "📥 Descargando repositorio: ${RUNBOAT_GIT_REPO}@${RUNBOAT_GIT_REF}"

# Función para determinar qué token usar con fallbacks múltiples
determine_github_token() {
    if [ -n "$RUNBOAT_GITHUB_TOKEN" ]; then
        echo "$RUNBOAT_GITHUB_TOKEN"
        return 0
    elif [ -n "$GITHUB_TOKEN" ]; then
        echo "$GITHUB_TOKEN"
        return 0
    elif [ -n "$TOKEN" ]; then
        echo "$TOKEN"
        return 0
    elif [ -n "$GH_TOKEN" ]; then
        echo "$GH_TOKEN"
        return 0
    else
        return 1
    fi
}

# Determinar qué token usar
if GITHUB_AUTH_TOKEN=$(determine_github_token); then
    echo "🔐 Usando token de GitHub para autenticación"
else
    echo "⚠️ Sin token de autenticación, intentando acceso público"
    GITHUB_AUTH_TOKEN=""
fi

# Función para descargar con autenticación
download_with_auth() {
    local method="$1"
    local url="$2"
    shift 2
    local curl_headers=("$@")
    
    local temp_output=$(mktemp)
    
    if [ ${#curl_headers[@]} -gt 0 ]; then
        curl -s -w "%{http_code}" -L "${curl_headers[@]}" -o tarball.tar.gz "$url" > "$temp_output"
    else
        curl -s -w "%{http_code}" -L -o tarball.tar.gz "$url" > "$temp_output"
    fi
    
    HTTP_CODE=$(cat "$temp_output")
    rm -f "$temp_output"
    
    if [ "$HTTP_CODE" = "200" ]; then
        if tar -tzf tarball.tar.gz >/dev/null 2>&1; then
            echo "✅ Descarga exitosa"
            tar zxf tarball.tar.gz --strip-components=1
            rm tarball.tar.gz
            return 0
        else
            echo "❌ Archivo descargado no es un tarball válido"
            rm -f tarball.tar.gz
            return 1
        fi
    else
        echo "❌ Error en descarga (HTTP $HTTP_CODE)"
        rm -f tarball.tar.gz
        return 1
    fi
}

# Función para descargar sin autenticación
download_public() {
    local url="https://github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}"
    
    local temp_output=$(mktemp)
    curl -s -w "%{http_code}" -L -o tarball.tar.gz "$url" > "$temp_output"
    HTTP_CODE=$(cat "$temp_output")
    rm -f "$temp_output"
    
    if [ "$HTTP_CODE" = "200" ]; then
        if tar -tzf tarball.tar.gz >/dev/null 2>&1; then
            echo "✅ Descarga exitosa (repositorio público)"
            tar zxf tarball.tar.gz --strip-components=1
            rm tarball.tar.gz
            return 0
        else
            echo "❌ Archivo descargado no es un tarball válido"
            rm -f tarball.tar.gz
            return 1
        fi
    else
        echo "❌ Error en descarga pública (HTTP $HTTP_CODE)"
        rm -f tarball.tar.gz
        return 1
    fi
}

# Proceso de descarga
if [ -n "$GITHUB_AUTH_TOKEN" ]; then
    # Método 1: URL con token embebido
    if ! download_with_auth "URL con token embebido" \
        "https://${GITHUB_AUTH_TOKEN}@github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}"; then
        
        # Método 2: Header Authorization Bearer
        if ! download_with_auth "Authorization Bearer" \
            "https://github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}" \
            "-H" "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" \
            "-H" "Accept: application/vnd.github.v3.raw"; then
            
            # Método 3: Header Authorization token  
            if ! download_with_auth "Authorization token" \
                "https://github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}" \
                "-H" "Authorization: token ${GITHUB_AUTH_TOKEN}" \
                "-H" "Accept: application/vnd.github.v3.raw"; then
                
                # Método 4: API de GitHub
                if ! download_with_auth "API de GitHub" \
                    "https://api.github.com/repos/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}" \
                    "-H" "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" \
                    "-H" "Accept: application/vnd.github+json"; then
                    
                    echo "❌ Todos los métodos autenticados fallaron"
                    echo "🔄 Intentando acceso público como último recurso..."
                    if ! download_public; then
                        echo "💥 ERROR: No se pudo descargar el repositorio"
                        exit 1
                    fi
                fi
            fi
        fi
    fi
else
    if ! download_public; then
        echo "💥 ERROR: No se pudo descargar el repositorio"
        exit 1
    fi
fi

# Función para detectar si el repositorio es un módulo Odoo en la raíz
detect_root_module() {
    if [ -f "__manifest__.py" ] || [ -f "__openerp__.py" ]; then
        echo "🔍 Detectado módulo Odoo en la raíz del repositorio"
        return 0
    fi
    return 1
}

# Función para reorganizar módulos en la raíz
reorganize_root_module() {
    local repo_name=$(basename "${RUNBOAT_GIT_REPO}")
    echo "📁 Reorganizando módulo en la raíz: creando carpeta '$repo_name'"
    
    # Crear directorio temporal para mover archivos
    mkdir -p temp_module
    
    # Mover todos los archivos y directorios (incluyendo ocultos) al directorio temporal
    # Usar find para evitar problemas con archivos que empiezan con punto
    find . -maxdepth 1 -mindepth 1 -not -name temp_module -not -name "." -not -name ".." -exec mv {} temp_module/ \;
    
    # Crear la carpeta del módulo
    mkdir -p "$repo_name"
    
    # Mover todo de vuelta a la carpeta del módulo
    if [ -d "temp_module" ] && [ "$(ls -A temp_module 2>/dev/null)" ]; then
        mv temp_module/* "$repo_name/" 2>/dev/null || true
        mv temp_module/.* "$repo_name/" 2>/dev/null || true
    fi
    
    # Limpiar directorio temporal
    rmdir temp_module 2>/dev/null || true
    
    # Verificar que el módulo se creó correctamente
    if [ -f "$repo_name/__manifest__.py" ] || [ -f "$repo_name/__openerp__.py" ]; then
        echo "✅ Módulo reorganizado correctamente en carpeta: $repo_name"
    else
        echo "⚠️ Advertencia: No se encontró __manifest__.py o __openerp__.py en $repo_name"
    fi
}

# Verificar si es un módulo en la raíz y reorganizar si es necesario
if detect_root_module; then
    reorganize_root_module
fi

# Set default INSTALL_METHOD if not provided
INSTALL_METHOD=${INSTALL_METHOD:-oca_install_addons}
echo "📦 Iniciando instalación con método: ${INSTALL_METHOD}"

if [[ "${INSTALL_METHOD}" == "oca_install_addons" ]] ; then
    oca_install_addons
elif [[ "${INSTALL_METHOD}" == "editable_pip_install" ]] ; then
    pip install -e .
else
    echo "❌ INSTALL_METHOD no soportado: '${INSTALL_METHOD}'"
    exit 1
fi

# Keep a copy of the venv that we can re-use for shorter startup time.
cp -ar /opt/odoo-venv/ /mnt/data/odoo-venv

echo "✅ Inicialización completada"
touch /mnt/data/initialized