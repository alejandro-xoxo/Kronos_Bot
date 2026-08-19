# Arquitectura futura — visión de referencia

Este documento describe hacia dónde debería evolucionar Kronos Bot si
pasa de "uso personal" a "servicio para varios clientes". **No es
trabajo pendiente inmediato** — es el criterio contra el que evaluar
decisiones de diseño de hoy, para no tomar atajos que después haya
que deshacer. Ninguna fase de aquí se ejecuta salvo que se decida
explícitamente empezarla.

## Modelo: multi-instancia aislada, no multi-tenant

Un único Telethon **compartido** (una sola sesión de Telegram, la
cuenta que sigue el grupo real de señales) hace fan-out del mensaje
a N instancias independientes — una por cliente. Cada instancia tiene
su propio:

- n8n (workflow independiente)
- Postgres (datos independientes)
- EA + prefijo de Wine/MT4 (cuenta de bróker independiente)

No hay una base de datos ni un n8n compartido entre clientes: aislar
por instancia evita que un bug o una fuga de datos de un cliente
afecte a otro.

El stack de pruebas (dev) usa un Telethon **separado**, apuntando al
grupo de pruebas — nunca comparte sesión ni credenciales con el
Telethon de producción.

## Seguridad de credenciales de cliente

Nunca se centralizan contraseñas de bróker de clientes. Cada cliente
hace su propio login en su instancia de MT4/Wine vía VNC temporal
(ej. noVNC, accesible desde navegador sin instalar nada), con una
contraseña de un solo uso que se revoca apenas termina el login. El
operador no ve ni almacena esa contraseña en ningún momento.

## Visibilidad: caja negra + reporte

- El operador tiene visibilidad técnica completa: logs, dashboard
  interno, sin autenticación en esta fase (uso propio).
- El cliente recibe únicamente un reporte diario resumido por
  Telegram (ganancia/pérdida del día) — sin acceso a dashboard ni
  panel técnico en esta fase.

## Infraestructura

Arranca en un mini PC personal (uso dual: automatización propia +
uso/estudio personal). Pensado para migrar a un servidor dedicado si
el número de clientes crece. El diseño debe funcionar bien en
hardware modesto desde el día uno — no se apoya en supuestos que
obliguen a reescribir al escalar (ej. nada que asuma recursos
ilimitados de CPU/RAM por instancia).

## Evolución del enum de perfiles del EA

Hoy `ENUM_KRONOS_PROFILE` está hardcodeado a 2 valores
(`PROD_STD`/`DEMO_VIP`) — correcto para una sola cuenta real + una
demo. Cuando haya más de 2-3 cuentas/clientes, este enum debería
evolucionar a algo parametrizable por instalación (ej. leído de un
archivo de configuración propio de cada instancia, no un enum fijo
compilado en el `.mq4`). Anotado como **deuda técnica consciente, no
urgente hoy** — no hay que resolverlo hasta que el número real de
cuentas lo justifique.

## Ruta de crecimiento

- **Hoy (Camino 1)** — multi-instancia simple: la lista de destinos
  de Telethon (a qué instancia reenviar cada mensaje) vive en un
  archivo de configuración editado a mano.
- **Futuro, con clientes reales pagando** — esa misma lista se mueve
  a una tabla de Postgres, sin rediseñar el resto del sistema (el
  fan-out, el aislamiento por instancia, y el modelo de
  credenciales/visibilidad no cambian).
