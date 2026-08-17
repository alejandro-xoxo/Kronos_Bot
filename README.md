<div align="center">

# 🤖 Kronos Bot

**Copia señales de trading de un grupo de Telegram a una cuenta real de MT4, con confirmación humana de por medio — para que operar a las 4 de la mañana sea un tap, no cinco minutos despierto tipeando precios en MetaTrader.**

[![Estado](https://img.shields.io/badge/estado-v1%20MVP%20funcional-2ea44f)](docs/versions/v1.md)
[![Ejecución real](https://img.shields.io/badge/ejecución-verificada%20en%20cuenta%20live-blue)](docs/versions/v1.md#-evidencia-real)
[![Licencia](https://img.shields.io/badge/uso-personal%20%2F%20portafolio-lightgrey)](#-licencia)
![Python](https://img.shields.io/badge/Python-Telethon-3776AB?logo=python&logoColor=white)
![n8n](https://img.shields.io/badge/n8n-orquestación-EA4B71?logo=n8n&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-DB-4169E1?logo=postgresql&logoColor=white)
![MQL4](https://img.shields.io/badge/MQL4-MT4%20EA-black)

</div>

<p align="center">
  <img src="docs/screenshots/02-confirmacion-telegram.png" alt="Notificación de nueva señal con botones Confirmar/Rechazar y ticket real ejecutado" width="420">
</p>

---

## 📖 Índice

- [El problema](#-el-problema)
- [Cómo funciona, en corto](#-cómo-funciona-en-corto)
- [Versiones](#-versiones)
- [Licencia](#-licencia)

---

## 🎯 El problema

Todavía estoy estudiando para ser developer. En paralelo empecé a meterme en trading buscando un ingreso extra — no un plan de hacerme rico rápido, sino algo real que pudiera sostener mientras sigo formándome.

Encontré un grupo de señales en Telegram que se veía sólido: buen historial, comunidad activa. El problema es que es un grupo español y yo no vivo ahí — las señales me caen entre la **1:30 a. m. y las 8:00 a. m.** hora mía. Copiarlas a mano significaba despertarme, abrir MT4 medio dormido, y tipear instrumento, dirección, entrada, take-profit y stop-loss antes de que el precio se moviera. Un solo dígito mal tipeado a esa hora es plata perdida.

No tenía presupuesto para un VPS, ni para una API de IA paga, ni para pagarle a un servicio de copy-trading de terceros. Tenía mi laptop y ganas de aprender de verdad construyendo algo real — no otro boceto de portafolio, sino un problema mío que tenía que funcionar de verdad. Así nació Kronos Bot.

La meta de fondo es que el copiado sea **100% automático**: que la señal se ejecute sola en mi cuenta mientras duermo. Pero un sistema que va a mover plata real no se suelta a ciegas desde el día uno — por eso la primera versión todavía me pide confirmar cada señal con un botón de Telegram antes de ejecutar. Es un paso intermedio deliberado: primero valido que cada pieza del sistema funciona sin sorpresas con un humano en el loop, después le suelto también la decisión.

## ⚙️ Cómo funciona, en corto

Telegram (grupo) → Telethon captura el mensaje → n8n lo parsea e inserta en Postgres → me llega a mí un botón de Confirmar/Rechazar por Telegram → si confirmo, un Expert Advisor en MQL4 ejecuta la orden real en MT4 → el resultado (ticket real) vuelve por el mismo camino y me llega la confirmación.

El detalle de cada decisión de arquitectura, los retos técnicos que aparecieron con tráfico real, el diagrama completo, instalación y configuración están documentados por versión — ver abajo.

## 📦 Versiones

| Versión | Estado | Qué es |
|---|---|---|
| **[v1](docs/versions/v1.md)** | ✅ MVP funcional, ejecución real verificada | Ciclo completo con confirmación humana: captura → parseo por regex → confirmación → ejecución real en MT4 → resultado. Arrancó el 10/08/2026. |
| v2 | 🔜 Planeada | Automatización completa (sin confirmación manual) + interpretación por Gemini de instrucciones de seguimiento en lenguaje libre. |

Cada versión documenta su propia arquitectura, decisiones, retos técnicos, stack, instalación y roadmap — el README no repite ese detalle a propósito, para que quede versionado junto con el código al que corresponde.

Reglas de negocio (fuente única de verdad, no versionadas por release): [`PROTOCOLOS_KRONOS_BOT.md`](PROTOCOLOS_KRONOS_BOT.md). Estado técnico fase por fase: [`STATUS.md`](STATUS.md).

## 📄 Licencia

Uso personal / portafolio. El código es público para que se vea el proceso, pero no está pensado como librería reusable ni producto de terceros. Si algo de acá te sirve como referencia, adelante — mencioná la fuente.

⚠️ *Este proyecto es una herramienta personal de automatización, no un producto de inversión ni una recomendación de trading. Todo el capital operado es propio y el riesgo se gestiona con reglas explícitas y fijas (ver `PROTOCOLOS_KRONOS_BOT.md`).*

---

<div align="center">

Construido por [**alejandro-xoxo**](https://github.com/alejandro-xoxo) mientras aprendo a programar en serio, resolviendo un problema que era mío.

</div>
