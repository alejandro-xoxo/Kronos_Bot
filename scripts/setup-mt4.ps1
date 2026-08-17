# Kronos Bot — Fase 6: preparación del entorno MT4 en Windows.
#
# En Windows, MT4 corre nativo (no requiere Wine). Este script
# automatiza lo que se puede automatizar en este SO: la carpeta de
# comunicación con n8n (symlinks de mt4-bridge/orders/ hacia
# Common\Files\ de MT4) y el symlink del EA a MQL4\Experts\. La
# instalación de MT4 en sí y el login a la cuenta VT Markets quedan
# como pasos manuales (requieren interacción gráfica con el
# instalador de MT4).
#
# Para Linux basado en Arch (Arch, CachyOS, Manjaro, etc.), usar
# scripts/setup-mt4.sh en su lugar; para Ubuntu Server, setup-mt4-ubuntu.sh.
#
# Crear symlinks en Windows requiere privilegios de Administrador, O
# tener activado "Developer Mode" (Configuración > Actualización y
# seguridad > Para desarrolladores) en Windows 10/11 — sin uno de los
# dos, New-Item -ItemType SymbolicLink falla con "A required privilege
# is not held by the client".
#
# Uso: abrir PowerShell en la raíz del repo y correr:
#   .\scripts\setup-mt4.ps1

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Mt4BridgeDir = Join-Path $RepoRoot "mt4-bridge"

Write-Host "== Kronos Bot - Setup MT4 (Fase 6, Windows) =="
Write-Host ""

function Get-ExistingItemOrNull {
    # Get-Item -Force detecta el link/archivo/carpeta aunque sea un
    # symlink ROTO (target inexistente) — a diferencia de Test-Path,
    # que resuelve el reparse point y devuelve $false para un symlink
    # roto como si no existiera nada. Usar esto en vez de Test-Path
    # en cualquier chequeo de "¿hay algo acá que haya que reemplazar?".
    param([string]$Path)
    return (Get-Item -Path $Path -Force -ErrorAction SilentlyContinue)
}

function Test-IsSymlinkTo {
    param([string]$Path, [string]$ExpectedTarget)
    $item = Get-ExistingItemOrNull -Path $Path
    if (-not $item) { return $false }
    if ($item.LinkType -ne "SymbolicLink") { return $false }
    # $item.Target puede venir como array de rutas (PS 5.1) o string (PS 7+)
    $target = $item.Target
    if ($target -is [array]) { $target = $target[0] }
    return ($target -eq $ExpectedTarget)
}

function New-SymlinkSafe {
    param([string]$Path, [string]$Target, [string]$ItemType)
    try {
        New-Item -ItemType $ItemType -Path $Path -Target $Target -Force | Out-Null
        return $true
    } catch {
        Write-Host "  ERROR creando symlink '$Path' -> '$Target': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Correr PowerShell como Administrador, o activar 'Developer Mode' en Windows." -ForegroundColor Yellow
        return $false
    }
}

# Crea o repara el symlink de directorio mt4-bridge\orders\<Name> -> <Target>,
# de forma idempotente (mismo comportamiento que link_bridge_dir en las
# variantes de Linux — ver scripts/setup-mt4.sh).
function Set-BridgeDirLink {
    param([string]$Name, [string]$Target)

    $LinkPath = Join-Path $Mt4BridgeDir "orders\$Name"

    if (Test-IsSymlinkTo -Path $LinkPath -ExpectedTarget $Target) {
        Write-Host "  ${Name}: symlink ya apunta a $Target, se omite."
        return
    }

    if (Get-ExistingItemOrNull -Path $LinkPath) {
        Write-Host "  ${Name}: reemplazando carpeta/symlink existente (roto, viejo, o real) por symlink hacia $Target"
        Remove-Item $LinkPath -Recurse -Force
    }

    if (New-SymlinkSafe -Path $LinkPath -Target $Target -ItemType SymbolicLink) {
        Write-Host "  ${Name}: symlink creado -> $Target"
    }
}

# Decide entre carpetas reales (sin MT4 todavía) o symlinks hacia
# Common\Files del terminal de MT4 (ya instalado y corrido al menos una vez).
function Initialize-BridgeDirs {
    New-Item -ItemType Directory -Force -Path (Join-Path $Mt4BridgeDir "orders") | Out-Null

    $CommonDir = Get-ChildItem -Path "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Common" } | Select-Object -First 1

    if ($CommonDir) {
        $CommonFiles = Join-Path $CommonDir.FullName "Files"
        Write-Host "Terminal de MT4 detectado. Common\Files en:"
        Write-Host "  $CommonFiles"
        New-Item -ItemType Directory -Force -Path (Join-Path $CommonFiles "orders\pending") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $CommonFiles "orders\results") | Out-Null
        Set-BridgeDirLink -Name "pending" -Target (Join-Path $CommonFiles "orders\pending")
        Set-BridgeDirLink -Name "results" -Target (Join-Path $CommonFiles "orders\results")
    } else {
        Write-Host "MT4 todavia no esta instalado/abierto en esta maquina - se usan carpetas"
        Write-Host "reales con .gitkeep (estado normal antes de instalar MT4 por primera vez)."
        $PendingDir = Join-Path $Mt4BridgeDir "orders\pending"
        $ResultsDir = Join-Path $Mt4BridgeDir "orders\results"
        New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
        New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $PendingDir ".gitkeep") | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $ResultsDir ".gitkeep") | Out-Null
    }
}

# Crea/repara un symlink de archivo en MQL4\Experts\ del terminal (NO
# Common, eso es exclusivo de MT4) apuntando al .mq4 del repo. Dirección
# inversa a Set-BridgeDirLink a propósito: acá el repo es la fuente real
# (versionada en git), el symlink vive del lado de MT4 — evita tener que
# re-copiar el archivo cada vez que se edita el EA, solo hay que
# recompilar en MetaEditor (F7).
function Set-EaExpertsLink {
    $SourceEa = Join-Path $Mt4BridgeDir "ea\KronosBridgeEA.mq4"
    if (-not (Test-Path $SourceEa)) {
        Write-Host "  AVISO: no se encontro $SourceEa, se omite el symlink del EA."
        return
    }

    $TerminalDir = Get-ChildItem -Path "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "Common" } | Select-Object -First 1

    if (-not $TerminalDir) {
        Write-Host "  MT4 todavia no esta instalado/corrido en esta maquina - no se encontro"
        Write-Host "  MQL4\Experts. Se omite el symlink del EA (correr este script de nuevo"
        Write-Host "  despues de instalar y abrir MT4 al menos una vez)."
        return
    }

    $ExpertsDir = Join-Path $TerminalDir.FullName "MQL4\Experts"
    $LinkPath = Join-Path $ExpertsDir "KronosBridgeEA.mq4"

    if (Test-IsSymlinkTo -Path $LinkPath -ExpectedTarget $SourceEa) {
        Write-Host "  KronosBridgeEA.mq4: symlink ya apunta al repo, se omite."
        return
    }

    if (Get-ExistingItemOrNull -Path $LinkPath) {
        Write-Host "  KronosBridgeEA.mq4: reemplazando archivo/symlink existente (roto, viejo, o real) por symlink hacia el repo."
        Remove-Item $LinkPath -Force
    }

    New-Item -ItemType Directory -Force -Path $ExpertsDir | Out-Null
    if (New-SymlinkSafe -Path $LinkPath -Target $SourceEa -ItemType SymbolicLink) {
        Write-Host "  KronosBridgeEA.mq4 enlazado en: $ExpertsDir"
        Write-Host "  (abrir MetaEditor y compilar con F7 - el .ex4 resultante queda del lado de MT4, no se versiona)"
    }
}

# 1. Preparar mt4-bridge\orders\{pending,results} — carpetas reales o
#    symlinks hacia Common\Files, según si MT4 ya está instalado.
Write-Host "-- Paso 1/2: preparando mt4-bridge\orders\{pending,results} --"
Initialize-BridgeDirs
Write-Host ""

# 1.5. Enlazar el EA a MQL4\Experts\
Write-Host "-- Paso 1.5/2: enlazando KronosBridgeEA.mq4 en MQL4\Experts\ --"
Set-EaExpertsLink
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
Write-Host "6. Este script ya dejo KronosBridgeEA.mq4 enlazado en MQL4\Experts\"
Write-Host "   (ver salida del Paso 1.5 arriba, si MT4 ya estaba instalado)."
Write-Host "   Abrir MetaEditor (F4 desde MT4), ubicarlo en Navigator > Experts,"
Write-Host "   y compilar con F7. Si corriste este script ANTES de instalar MT4"
Write-Host "   por primera vez, volve a correrlo despues de abrirlo para que se"
Write-Host "   creen los symlinks de los pasos 1 y 1.5."
Write-Host ""
Write-Host "Una vez logueado, viendo precios en tiempo real, y con el EA"
Write-Host "compilado sin errores, MT4 esta listo para arrastrar el EA al"
Write-Host "grafico y activar AutoTrading - ver docs/INSTALL_WINDOWS.md para"
Write-Host "el resto (activacion del EA, puente n8n -> MT4, troubleshooting)."
Write-Host ""

Write-Host "== Setup automatizado completado =="
