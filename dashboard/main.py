"""
Kronos Bot — Dashboard web local.

Sirve una página simple para ver posiciones abiertas en MT4 (via
status.json escrito por el EA) y cambiar el perfil de cuenta activo
del EA (via config.json leído por el EA — ver ENUM_KRONOS_PROFILE en
KronosBridgeEA.mq4). El EA valida siempre el perfil recibido contra
AccountNumber() antes de operar; el dashboard no tiene ninguna
lógica de seguridad propia, solo persiste la elección. Ver
mt4-bridge/FORMATO_ARCHIVOS.md para el contrato exacto de ambos
archivos.

Expuesto por internet vía el túnel ngrok compartido (ver
docker-compose.yml, servicio `caddy`) además de LAN/localhost
(puerto 8088). Protegido con HTTP Basic Auth (`DASHBOARD_USER` / `DASHBOARD_PASSWORD`
en `.env`) aplicado a toda la app — ver `_require_auth` más abajo.
"""
import hmac
import json
import os
from datetime import datetime, timezone
from functools import wraps

import psycopg2
import psycopg2.extras
from flask import Flask, Response, jsonify, request, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="")

ORDERS_DIR = os.environ.get("MT4_ORDERS_DIR", "/mt4-bridge/orders")
STATUS_PATH = os.path.join(ORDERS_DIR, "status.json")
CONFIG_PATH = os.path.join(ORDERS_DIR, "config.json")

VALID_PROFILES = ("PROD_STD", "DEMO_VIP")

DASHBOARD_USER = os.environ.get("DASHBOARD_USER")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD")


def _check_auth(auth):
    if not auth or not DASHBOARD_USER or not DASHBOARD_PASSWORD:
        return False
    # hmac.compare_digest evita timing attacks al comparar credenciales.
    return hmac.compare_digest(auth.username, DASHBOARD_USER) and hmac.compare_digest(
        auth.password, DASHBOARD_PASSWORD
    )


@app.before_request
def _require_auth():
    if not _check_auth(request.authorization):
        return Response(
            "Autenticación requerida.",
            401,
            {"WWW-Authenticate": 'Basic realm="Kronos Dashboard"'},
        )

DASHBOARD_USER = os.environ.get("DASHBOARD_USER")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD")


def _check_auth(auth):
    if not auth or not DASHBOARD_USER or not DASHBOARD_PASSWORD:
        return False
    # hmac.compare_digest evita timing attacks al comparar credenciales.
    return hmac.compare_digest(auth.username, DASHBOARD_USER) and hmac.compare_digest(
        auth.password, DASHBOARD_PASSWORD
    )


@app.before_request
def _require_auth():
    if not _check_auth(request.authorization):
        return Response(
            "Autenticación requerida.",
            401,
            {"WWW-Authenticate": 'Basic realm="Kronos Dashboard"'},
        )


def get_db_connection():
    return psycopg2.connect(
        host="postgres",
        dbname=os.environ.get("POSTGRES_DB"),
        user=os.environ.get("POSTGRES_USER"),
        password=os.environ.get("POSTGRES_PASSWORD"),
    )


@app.route("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.route("/api/positions")
def api_positions():
    if not os.path.isfile(STATUS_PATH):
        return jsonify({"positions": [], "account": None, "stale": True}), 200

    try:
        with open(STATUS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        # Archivo presente pero corrupto/en escritura a medias:
        # tratarlo como "todavía no hay datos válidos" en vez de 500.
        return jsonify({"positions": [], "account": None, "stale": True}), 200

    data.setdefault("positions", [])
    data.setdefault("account", None)
    data["stale"] = False
    _attach_daily_seq(data["positions"])
    return jsonify(data), 200


def _attach_daily_seq(positions):
    """Agrega 'daily_seq' (1, 2, 3... según orden cronológico de
    apertura dentro de su día en UTC, reiniciando cada día) a cada
    posición — es el número "1ra operación del día" que se muestra
    como identificador principal en el dashboard en vez del ticket
    crudo. Solo contempla las posiciones que siguen abiertas ahora
    (status.json no tiene historial de las ya cerradas), así que si
    una operación anterior del mismo día ya cerró, la numeración de
    las que quedan abiertas puede saltear números — es una limitación
    conocida, no aplica al historial de señales (ver api_signals),
    que sí tiene el historial completo en Postgres."""
    with_time = [p for p in positions if p.get("open_time")]
    without_time = [p for p in positions if not p.get("open_time")]
    with_time.sort(key=lambda p: p["open_time"])

    counters = {}
    for p in with_time:
        day = p["open_time"][:10]  # "YYYY-MM-DD" del ISO 8601 UTC
        counters[day] = counters.get(day, 0) + 1
        p["daily_seq"] = counters[day]
        p["daily_seq_date"] = day

    for p in without_time:
        p["daily_seq"] = None
        p["daily_seq_date"] = None


VALID_POSITION_ACTIONS = ("SET_BE", "SET_TP_BE", "CLOSE")


def _load_managed_positions():
    """Posiciones manejadas por el EA (managed=true) del último
    status.json, con su ticket y signal_uid. Se usa para no dejar
    escribir comandos sobre tickets inventados, ya cerrados, o
    abiertos manualmente fuera de la automatización — el EA de todos
    modos ignora acciones sobre tickets sin su InpMagicNumber (ver
    ProcessActionFile), pero rechazarlas acá evita encolar un archivo
    de acción que nunca se va a ejecutar."""
    if not os.path.isfile(STATUS_PATH):
        return []
    try:
        with open(STATUS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    return [p for p in data.get("positions", []) if p.get("managed", True)]


def _load_current_tickets():
    return {p.get("ticket") for p in _load_managed_positions()}


def _related_tickets(ticket, positions):
    """Tickets de sub-señales relacionadas con `ticket` — mismo
    signal_uid base (ej. "1424-A" y "1424-B" comparten "1424", ver
    protocolo sección 4.2 regla 6: TP1/TP2 de una misma señal generan
    sub-señales independientes con el mismo instrumento/entrada/SL,
    solo el TP difiere). Se usa para propagar SET_BE a todas las
    sub-señales de una misma señal cuando el usuario mueve una a BE."""
    by_ticket = {p.get("ticket"): p.get("signal_uid") for p in positions}
    signal_uid = by_ticket.get(ticket)
    if not signal_uid or "-" not in signal_uid:
        return []
    base_id = signal_uid.rsplit("-", 1)[0]
    return [
        t
        for t, uid in by_ticket.items()
        if t != ticket and uid and uid.rsplit("-", 1)[0] == base_id
    ]


@app.route("/api/positions/<int:ticket>/action", methods=["POST"])
def api_position_action(ticket):
    body = request.get_json(silent=True) or {}
    action = body.get("action")

    if action not in VALID_POSITION_ACTIONS:
        return (
            jsonify(
                {
                    "error": "action inválida: '{}'. Valores permitidos: {}".format(
                        action, ", ".join(VALID_POSITION_ACTIONS)
                    )
                }
            ),
            400,
        )

    positions = _load_managed_positions()
    current_tickets = {p.get("ticket") for p in positions}
    if ticket not in current_tickets:
        return (
            jsonify(
                {
                    "error": f"ticket {ticket} no aparece en las posiciones abiertas actuales "
                    "(¿ya cerró, o el EA todavía no reportó status.json?)."
                }
            ),
            404,
        )

    # SET_BE se propaga a todas las sub-señales relacionadas (mismo
    # signal_uid base, ej. TP1/TP2 de una misma señal, protocolo
    # sección 4.2 regla 6): mover una a BE sin mover la otra deja una
    # pata de la misma señal con riesgo mientras la otra ya no lo
    # tiene, que no es lo que el usuario espera al pedir "BE".
    tickets_to_queue = [ticket]
    if action == "SET_BE":
        tickets_to_queue += [t for t in _related_tickets(ticket, positions) if t in current_tickets]

    actions_dir = os.path.join(ORDERS_DIR, "actions")
    os.makedirs(actions_dir, exist_ok=True)
    # El contenedor corre como root; el EA (Wine) corre con el usuario del
    # host y necesita permiso de escritura sobre la CARPETA para poder
    # borrar el archivo tras procesarlo (FileDelete), no solo sobre el
    # archivo — sin esto queda basura en actions/ para siempre. 0777 es
    # aceptable acá: carpeta local de un solo usuario, sin exponer nada
    # a internet (ver docstring del módulo).
    os.chmod(actions_dir, 0o777)

    for t in tickets_to_queue:
        # Un archivo por ticket+acción: si mandás BE y CLOSE casi juntos no
        # se pisan entre sí: el EA procesa los dos en el mismo ciclo.
        action_path = os.path.join(actions_dir, f"{t}-{action}.json")
        with open(action_path, "w", encoding="utf-8") as f:
            json.dump({"ticket": t, "action": action}, f)
        os.chmod(action_path, 0o666)

        # Borra cualquier resultado viejo del mismo ticket+acción (de un
        # intento anterior) para que el polling del frontend no lea un
        # "success" desactualizado antes de que el EA procese este comando
        # nuevo — ver api_position_action_result.
        result_path = _action_result_path(t, action)
        if os.path.isfile(result_path):
            os.remove(result_path)

    return (
        jsonify(
            {
                "ticket": ticket,
                "action": action,
                "queued": True,
                "related_tickets": tickets_to_queue[1:],
            }
        ),
        200,
    )


def _action_result_path(ticket, action):
    return os.path.join(ORDERS_DIR, "action_results", f"{ticket}-{action}.json")


@app.route("/api/positions/<int:ticket>/action_result")
def api_position_action_result(ticket):
    action = request.args.get("action")
    if action not in VALID_POSITION_ACTIONS:
        return (
            jsonify(
                {
                    "error": "action inválida: '{}'. Valores permitidos: {}".format(
                        action, ", ".join(VALID_POSITION_ACTIONS)
                    )
                }
            ),
            400,
        )

    result_path = _action_result_path(ticket, action)
    if not os.path.isfile(result_path):
        return jsonify({"found": False}), 200

    try:
        with open(result_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        # Escritura a medias del EA — tratar como "todavía no está".
        return jsonify({"found": False}), 200

    data["found"] = True
    return jsonify(data), 200


SIGNAL_RANGES = {
    # date_trunc('week', ...) en Postgres arranca el lunes (semana ISO).
    "today": "date_trunc('day', NOW())",
    "week": "date_trunc('week', NOW())",
    "month": "date_trunc('month', NOW())",
    "all": None,
}


@app.route("/api/signals")
def api_signals():
    range_param = request.args.get("range", "all")
    if range_param not in SIGNAL_RANGES:
        return (
            jsonify(
                {
                    "error": "range inválido: '{}'. Valores permitidos: {}".format(
                        range_param, ", ".join(SIGNAL_RANGES)
                    )
                }
            ),
            400,
        )

    since_expr = SIGNAL_RANGES[range_param]
    where_clause = f"WHERE created_at >= {since_expr}" if since_expr else ""

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            # daily_seq: número de secuencia dentro del día de la señal (se
            # reinicia cada día, orden cronológico ASC pese a que el listado
            # final se devuelve DESC) — es el identificador amigable ("1ra
            # señal del día") que se muestra en el dashboard en vez del id
            # técnico. daily_seq_date acompaña para el caso "N del 20 ago"
            # cuando el filtro trae señales de más de un día.
            cur.execute(
                f"""
                SELECT id, signal_uid, instrument, direction, status,
                       mt4_ticket, entry_price, sl, tp, created_at, updated_at,
                       CASE WHEN id % 20 = 0 THEN 20 ELSE id % 20 END AS cycle_position,
                       ROW_NUMBER() OVER (
                           PARTITION BY created_at::date ORDER BY created_at ASC
                       ) AS daily_seq,
                       created_at::date AS daily_seq_date
                FROM signals
                {where_clause}
                ORDER BY created_at DESC
                LIMIT 500
                """
            )
            rows = cur.fetchall()
    except psycopg2.Error as exc:
        return jsonify({"error": f"error consultando la base de datos: {exc}"}), 500
    finally:
        if conn is not None:
            conn.close()

    return jsonify({"signals": rows, "range": range_param}), 200


@app.route("/api/signals/<int:signal_id>/retry", methods=["POST"])
def api_signal_retry(signal_id):
    # Solo reintenta señales que quedaron en PENDING_MANUAL (el EA las
    # confirmó como CONFIRMED pero OrderSend falló — ver
    # mt4-bridge/FORMATO_ARCHIVOS.md sección 2). Guard idempotente igual
    # que el resto del flujo: si dos clicks llegan casi juntos, el
    # segundo UPDATE no encuentra la fila (ya no está en PENDING_MANUAL)
    # y no reescribe el archivo de orden dos veces.
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                UPDATE signals
                SET status = 'CONFIRMED', updated_at = NOW()
                WHERE id = %s AND status = 'PENDING_MANUAL'
                RETURNING id, signal_uid, instrument, direction, execution_type,
                          entry_price, sl, tp, lot_assigned
                """,
                (signal_id,),
            )
            row = cur.fetchone()
            conn.commit()
    except psycopg2.Error as exc:
        return jsonify({"error": f"error consultando la base de datos: {exc}"}), 500
    finally:
        if conn is not None:
            conn.close()

    if row is None:
        return (
            jsonify(
                {
                    "error": f"señal #{signal_id} no está en PENDING_MANUAL "
                    "(ya se reintentó, sigue en curso, o nunca falló)."
                }
            ),
            409,
        )

    order = {
        "signal_id": row["id"],
        "signal_uid": row["signal_uid"],
        "instrument": row["instrument"],
        "direction": row["direction"],
        "execution_type": row["execution_type"],
        "entry_price": row["entry_price"],
        "sl": row["sl"],
        "tp": row["tp"],
        "lot": row["lot_assigned"],
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    pending_dir = os.path.join(ORDERS_DIR, "pending")
    os.makedirs(pending_dir, exist_ok=True)
    pending_path = os.path.join(pending_dir, f"{signal_id}.json")
    with open(pending_path, "w", encoding="utf-8") as f:
        json.dump(order, f)

    return jsonify({"signal_id": signal_id, "status": "CONFIRMED", "order": order}), 200


@app.route("/api/config", methods=["GET"])
def api_config_get():
    if not os.path.isfile(CONFIG_PATH):
        return jsonify({"profile": None}), 200

    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return jsonify({"profile": None}), 200

    return jsonify({"profile": data.get("profile")}), 200


@app.route("/api/config", methods=["POST"])
def api_config_post():
    body = request.get_json(silent=True) or {}
    profile = body.get("profile")

    if profile not in VALID_PROFILES:
        return (
            jsonify(
                {
                    "error": (
                        "profile inválido: '{}'. Valores permitidos: {}".format(
                            profile, ", ".join(VALID_PROFILES)
                        )
                    )
                }
            ),
            400,
        )

    os.makedirs(ORDERS_DIR, exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump({"profile": profile}, f)

    return jsonify({"profile": profile}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
