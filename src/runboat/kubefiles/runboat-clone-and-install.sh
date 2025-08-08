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

echo "🔍 === INFORMACIÓN DE DEBUG COMPLETA ==="
echo "Todas las variables de entorno relacionadas con GitHub:"
env | grep -i -E "(github|git|token|runboat)" | sort || echo "No se encontraron variables relacionadas"

echo ""
echo "🌍 Todas las variables de entorno (primeras 100):"
env | head -100

echo ""
echo "📋 Variables específicas:"
echo "RUNBOAT_GIT_REPO: '${RUNBOAT_GIT_REPO:-NO_DEFINIDA}'"
echo "RUNBOAT_GIT_REF: '${RUNBOAT_GIT_REF:-NO_DEFINIDA}'"
echo "RUNBOAT_GITHUB_TOKEN presente: $([ -n "$RUNBOAT_GITHUB_TOKEN" ] && echo "SÍ (${#RUNBOAT_GITHUB_TOKEN} caracteres)" || echo "NO")"
echo "GITHUB_TOKEN presente: $([ -n "$GITHUB_TOKEN" ] && echo "SÍ (${#GITHUB_TOKEN} caracteres)" || echo "NO")"
echo "TOKEN presente: $([ -n "$TOKEN" ] && echo "SÍ (${#TOKEN} caracteres)" || echo "NO")"
echo "GH_TOKEN presente: $([ -n "$GH_TOKEN" ] && echo "SÍ (${#GH_TOKEN} caracteres)" || echo "NO")"

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
    echo "🔐 Token de GitHub encontrado para autenticación"
    TOKEN_SOURCE=""
    [ -n "$RUNBOAT_GITHUB_TOKEN" ] && TOKEN_SOURCE="RUNBOAT_GITHUB_TOKEN"
    [ -n "$GITHUB_TOKEN" ] && [ -z "$TOKEN_SOURCE" ] && TOKEN_SOURCE="GITHUB_TOKEN"  
    [ -n "$TOKEN" ] && [ -z "$TOKEN_SOURCE" ] && TOKEN_SOURCE="TOKEN"
    [ -n "$GH_TOKEN" ] && [ -z "$TOKEN_SOURCE" ] && TOKEN_SOURCE="GH_TOKEN"
    echo "📍 Usando token de: $TOKEN_SOURCE"
else
    echo "⚠️ No se encontró ningún token de GitHub"
    GITHUB_AUTH_TOKEN=""
fi

echo ""
echo "🌍 Información del repositorio:"
echo "Repositorio: ${RUNBOAT_GIT_REPO}"
echo "Referencia: ${RUNBOAT_GIT_REF}"
echo ""

# Función para descargar con autenticación
download_with_auth() {
    local method="$1"
    local url="$2"
    shift 2  # Remueve los primeros 2 parámetros, el resto son headers
    local curl_headers=("$@")  # Almacena todos los headers como array
    
    echo "🔄 Intentando método: $method"
    echo "📡 URL: $url"
    
    # Usar archivo temporal para evitar contaminación del HTTP_CODE
    local temp_output=$(mktemp)
    
    if [ ${#curl_headers[@]} -gt 0 ]; then
        # Construir comando curl con headers
        curl -s -w "%{http_code}" -L "${curl_headers[@]}" -o tarball.tar.gz "$url" > "$temp_output"
    else
        curl -s -w "%{http_code}" -L -o tarball.tar.gz "$url" > "$temp_output"
    fi
    
    HTTP_CODE=$(cat "$temp_output")
    rm -f "$temp_output"
    
    echo "📊 Código HTTP: $HTTP_CODE"
    
    if [ "$HTTP_CODE" = "200" ]; then
        if tar -tzf tarball.tar.gz >/dev/null 2>&1; then
            echo "✅ Descarga exitosa con $method"
            tar zxf tarball.tar.gz --strip-components=1
            rm tarball.tar.gz
            return 0
        else
            echo "❌ Archivo descargado no es un tarball válido"
            rm -f tarball.tar.gz
            return 1
        fi
    else
        echo "❌ Error en descarga con $method (HTTP $HTTP_CODE)"
        rm -f tarball.tar.gz
        return 1
    fi
}

# Función para descargar sin autenticación
download_public() {
    echo "🔄 Intentando acceso público"
    local url="https://github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}"
    echo "📡 URL: $url"
    
    local temp_output=$(mktemp)
    curl -s -w "%{http_code}" -L -o tarball.tar.gz "$url" > "$temp_output"
    HTTP_CODE=$(cat "$temp_output")
    rm -f "$temp_output"
    
    echo "📊 Código HTTP: $HTTP_CODE"
    
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
    echo "🔐 Iniciando descarga con autenticación..."
    
    # Método 1: URL con token embebido (más simple y directo)
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
                        echo "💥 ERROR FATAL: No se pudo descargar el repositorio por ningún método"
                        
                        echo "🔍 Información de debugging adicional:"
                        echo "   - Token length: ${#GITHUB_AUTH_TOKEN} caracteres"
                        echo "   - Token prefix: ${GITHUB_AUTH_TOKEN:0:7}..."
                        echo "   - Repositorio: ${RUNBOAT_GIT_REPO}"
                        echo "   - Referencia: ${RUNBOAT_GIT_REF}"
                        
                        # Verificar si el repositorio existe sin autenticación
                        echo "🔍 Verificando si el repositorio existe..."
                        repo_check=$(curl -s -o /dev/null -w "%{http_code}" "https://github.com/${RUNBOAT_GIT_REPO}")
                        echo "   - Código de respuesta del repo: $repo_check"
                        
                        # Verificar si el commit/branch existe
                        echo "🔍 Verificando si la referencia existe..."
                        ref_check=$(curl -s -o /dev/null -w "%{http_code}" "https://api.github.com/repos/${RUNBOAT_GIT_REPO}/commits/${RUNBOAT_GIT_REF}")
                        echo "   - Código de respuesta del commit: $ref_check"
                        
                        exit 1
                    fi
                fi
            fi
        fi
    fi
else
    echo "⚠️ Sin token de autenticación, intentando acceso público..."
    if ! download_public; then
        echo "💥 ERROR FATAL: No se pudo descargar el repositorio"
        echo "🔍 Posibles causas:"
        echo "   - Repositorio es privado y no se proporcionó token válido"
        echo "   - Referencia '${RUNBOAT_GIT_REF}' no existe"
        echo "   - Repositorio '${RUNBOAT_GIT_REPO}' no existe"
        echo "   - Problemas de conectividad"
        exit 1
    fi
fi

echo ""
echo "📁 Contenido descargado:"
ls -la || echo "No se pudo listar el contenido"

# Install.
echo ""
echo "🚀 Iniciando instalación..."
INSTALL_METHOD=${INSTALL_METHOD:-oca_install_addons}
echo "📦 Método de instalación: ${INSTALL_METHOD}"

if [[ "${INSTALL_METHOD}" == "oca_install_addons" ]] ; then
    echo "🔧 Ejecutando oca_install_addons..."
    oca_install_addons
elif [[ "${INSTALL_METHOD}" == "editable_pip_install" ]] ; then
    echo "🔧 Ejecutando pip install -e ..."
    pip install -e .
else
    echo "❌ INSTALL_METHOD no soportado: '${INSTALL_METHOD}'"
    echo "📋 Métodos soportados: oca_install_addons, editable_pip_install"
    exit 1
fi

# Keep a copy of the venv that we can re-use for shorter startup time.
echo "💾 Guardando copia del entorno virtual..."
cp -ar /opt/odoo-venv/ /mnt/data/odoo-venv

echo "✅ Marcando como inicializado..."
touch /mnt/data/initialized

echo ""
echo "🎉 ¡Script completado exitosamente!"