<div align="center">

# 🤖 Kronos Bot

**Copia señales de trading de un grupo de Telegram a una cuenta real de MT4, con control de riesgo automático — para no tener que despertarse a las 4 de la mañana a tipear precios en MetaTrader.**

[![Estado](https://img.shields.io/badge/estado-v2%20en%20producción%20real-2ea44f)](docs/versions/v2.md)
[![Ejecución real](https://img.shields.io/badge/ejecución-verificada%20en%20cuenta%20live-blue)](docs/versions/v1.md#-evidencia-real)
[![Historial de versiones](https://img.shields.io/badge/versiones-v1.0%20→%20v2.4-orange)](docs/versions/v2.md#️-historial-de-versiones)
[![Licencia](https://img.shields.io/badge/uso-personal%20%2F%20portafolio-lightgrey)](#-licencia)
![Python](https://img.shields.io/badge/Python-Telethon-3776AB?logo=python&logoColor=white)
![n8n](https://img.shields.io/badge/n8n-orquestación-EA4B71?logo=n8n&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-DB-4169E1?logo=postgresql&logoColor=white)
![MQL4](https://img.shields.io/badge/MQL4-MT4%20EA-black)

</div>

<p align="center">
  <img src="docs/screenshots/02-confirmacion-telegram.png" alt="Notificación de nueva señal con botones Confirmar/Rechazar y ticket real ejecutado" width="420">
  <img src="docs/screenshots/06-dashboard-pvg-crecimiento.png" alt="Dashboard: panel de Crecimiento con capital y evolución en vivo" width="420">
</p>

---

## 📖 Índice

- [El problema](#-el-problema)
- [Cómo funciona, en corto](#-cómo-funciona-en-corto)
- [Versiones](#-versiones)
- [Licencia](#-licencia)

---

## 🎯 El problema

Un grupo de señales de trading en Telegram, con buen historial, publica entre la **1:30 a. m. y las 8:00 a. m.** hora del autor. Copiar cada señal a mano significa despertarse, abrir MT4 medio dormido y tipear instrumento, dirección, entrada, take-profit y stop-loss antes de que el precio se mueva — un dígito mal tipeado a esa hora es plata perdida.

Sin presupuesto para un VPS, una API de IA paga, ni un servicio de copy-trading de terceros, Kronos Bot nace como solución propia: correr local, con las piezas justas para resolver el problema real.

La meta de fondo siempre fue automatización total — la señal ejecutándose sola mientras el autor duerme. v1 mantuvo confirmación humana obligatoria por diseño: un sistema que mueve dinero real no se suelta a ciegas desde el día uno. Primero se validó cada pieza con un humano en el loop; en v2 la decisión ya se automatiza, con controles de riesgo en vez de supervisión manual constante.

## ⚙️ Cómo funciona, en corto

Telegram (grupo) → Telethon captura el mensaje → n8n lo parsea e inserta en Postgres → si pasa los controles de riesgo de v2 (0 operaciones abiertas, ganancia del día bajo el límite) se auto-confirma; si no, cae a botón de Confirmar/Rechazar por Telegram como en v1 → un Expert Advisor en MQL4 ejecuta la orden real en MT4 → el resultado (ticket real) vuelve por el mismo camino como confirmación.

Arquitectura, retos técnicos, instalación y configuración están documentados por versión — ver abajo.

## 📦 Versiones

| Versión | Estado | Qué es |
|---|---|---|
| **[v1](docs/versions/v1.md)** | ✅ MVP funcional, ejecución real verificada | Ciclo completo con confirmación humana: captura → parseo por regex → confirmación → ejecución real en MT4 → resultado. Arrancó el 10/08/2026. |
| **[v2](docs/versions/v2.md)** | ✅ En producción real desde el 30/08/2026 | Auto-confirmación de señales con control de riesgo: tope de 1 operación simultánea + circuit breaker de ganancia diaria (≥7% corta la automatización hasta el día siguiente y cae a confirmación manual). Interpretación por Gemini de instrucciones de seguimiento sigue sin conectar. |

Cada versión documenta su propia arquitectura, decisiones, retos técnicos, stack, instalación y roadmap — el README no repite ese detalle a propósito, para que quede versionado junto con el código al que corresponde.

El dashboard (Crecimiento, Interés compuesto, Calendario, Panel de control, Conversor) es la integración de [PVG_kronos](https://github.com/alejandro-xoxo/PGV_kronos.git), un proyecto externo propio — ver capturas y detalle en [`docs/versions/v2.md`](docs/versions/v2.md#-evidencia-real).

## 📄 Licencia

Uso personal / portafolio. El código es público para que se vea el proceso, pero no está pensado como librería reusable ni producto de terceros. Si algo de acá te sirve como referencia, adelante — mencioná la fuente.

⚠️ *Este proyecto es una herramienta personal de automatización, no un producto de inversión ni una recomendación de trading. Todo el capital operado es propio y el riesgo se gestiona con reglas explícitas y fijas.*

---

<div align="center">

Construido por [**alejandro-xoxo**](https://github.com/alejandro-xoxo) como proyecto real de aprendizaje, resolviendo un problema propio.

</div>
