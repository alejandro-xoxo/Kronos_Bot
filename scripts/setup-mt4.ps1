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
Write-Host "1. Descargar el instalador GENERICO de MetaTrader 4 desde el sitio"
Write-Host "   oficial: https://www.metatrader4.com/es/download"
Write-Host "   (NO existe un instalador separado de VT Markets - es el mismo"
Write-Host "   software generico para cualquier broker; la conexion a VT"
Write-Host "   Markets se hace despues, desde dentro de la plataforma ya"
Write-Host "   instalada). Normalmente se llama algo como 'mt4setup.exe'."
Write-Host ""
Write-Host "2. Correr el instalador normalmente (doble clic), como cualquier"
Write-Host "   programa de Windows."
Write-Host ""
Write-Host "3. Seguir el instalador grafico hasta el final (Next, Next, Finish)."
Write-Host ""
Write-Host "4. Abrir MT4 (el instalador normalmente deja un acceso directo en"
Write-Host "   el escritorio o el menu de inicio)."
Write-Host ""
Write-Host "5. Recien AHORA, dentro de la plataforma ya instalada, conectarte al"
Write-Host "   servidor especifico de VT Markets: en MT4 ir a"
Write-Host "   Archivo > Iniciar sesion en cuenta de trading (o la ventana de"
Write-Host "   login que aparece al abrir por primera vez) e ingresar:"
Write-Host "     - Numero de cuenta"
Write-Host "     - Contrasena"
Write-Host "     - Servidor (el nombre exacto que te dio VT Markets, ej. algo"
Write-Host "       como 'VTMarkets-Live' o 'VTMarkets-Demo' - puede requerir"
Write-Host "       buscarlo en la lista de servidores si no aparece por"
Write-Host "       defecto)"
Write-Host "   Estas credenciales NO se automatizan ni se guardan en ningun"
Write-Host "   archivo del repo, se ingresan a mano en la ventana de login."
Write-Host ""
Write-Host "Una vez logueado y viendo precios en tiempo real en el terminal,"
Write-Host "MT4 esta listo para el siguiente paso: instalar el EA puente"
Write-Host "(Fase 6, pendiente - no implementado todavia)."
Write-Host ""

Write-Host "== Setup automatizado completado =="
