# Kronos Bot — Fase 6: preparación del entorno MT4 en Windows.
#
# En Windows, MT4 corre nativo (no requiere Wine). Este script solo
# automatiza lo que se puede automatizar en este SO: la carpeta de
# comunicación con n8n. La instalación de MT4 en sí y el login a la
# cuenta VT Markets quedan como pasos manuales (requieren interacción
# gráfica con el instalador de MT4).
#
# Para Linux basado en Arch (Arch, CachyOS, Manjaro, etc.), usar
# scripts/setup-mt4.sh en su lugar.
#
# Uso: abrir PowerShell en la raíz del repo y correr:
#   .\scripts\setup-mt4.ps1

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Mt4BridgeDir = Join-Path $RepoRoot "mt4-bridge"

Write-Host "== Kronos Bot - Setup MT4 (Fase 6, Windows) =="
Write-Host ""

# 1. Crear estructura de mt4-bridge/
Write-Host "-- Paso 1/2: creando estructura de mt4-bridge/ --"
$PendingDir = Join-Path $Mt4BridgeDir "orders\pending"
$ResultsDir = Join-Path $Mt4BridgeDir "orders\results"

New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

New-Item -ItemType File -Force -Path (Join-Path $PendingDir ".gitkeep") | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $ResultsDir ".gitkeep") | Out-Null

Write-Host "Carpeta lista en $Mt4BridgeDir (orders\pending, orders\results)."
Write-Host ""

# 2. Instrucciones manuales
Write-Host "-- Paso 2/2: pasos MANUALES pendientes --"
Write-Host ""
Write-Host "Lo automatizable ya quedo listo en este SO. Faltan estos pasos manuales:"
Write-Host ""
Write-Host "1. Descargar el instalador de MT4 desde el sitio de VT Markets"
Write-Host "   (normalmente un .exe, ej. 'vtmarkets4setup.exe')."
Write-Host ""
Write-Host "2. Correr el instalador normalmente (doble clic), como cualquier"
Write-Host "   programa de Windows. No requiere Wine ni configuracion especial."
Write-Host ""
Write-Host "3. Seguir el instalador grafico hasta el final (Next, Next, Finish)."
Write-Host ""
Write-Host "4. Abrir MT4 (el instalador normalmente deja un acceso directo en"
Write-Host "   el escritorio o el menu de inicio)."
Write-Host ""
Write-Host "5. Loguearte con las credenciales de tu cuenta VT Markets (numero de"
Write-Host "   cuenta, contrasena, servidor) - estas NO se automatizan ni se"
Write-Host "   guardan en ningun archivo del repo, se ingresan a mano en la"
Write-Host "   ventana de login de MT4."
Write-Host ""
Write-Host "Una vez logueado y viendo precios en tiempo real en el terminal,"
Write-Host "MT4 esta listo para el siguiente paso: instalar el EA puente"
Write-Host "(Fase 6, pendiente - no implementado todavia)."
Write-Host ""

Write-Host "== Setup automatizado completado =="
