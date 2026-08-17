"""
Kronos Bot — Dashboard web local.

Sirve una página simple para ver posiciones abiertas en MT4 (via
status.json escrito por el EA) y cambiar el sufijo de símbolo del
bróker (via config.json leído por el EA). Ver
mt4-bridge/FORMATO_ARCHIVOS.md para el contrato exacto de ambos
archivos.

Sin autenticación: solo se expone en localhost/LAN (puerto 8088), no
por ngrok — ver docker-compose.yml. Si en algún momento se vuelve a
exponer por internet, hay que reintroducir un mecanismo de login
antes de hacerlo.
"""
import json
import os
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, request, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="")

ORDERS_DIR = os.environ.get("MT4_ORDERS_DIR", "/mt4-bridge/orders")
STATUS_PATH = os.path.join(ORDERS_DIR, "status.json")
CONFIG_PATH = os.path.join(ORDERS_DIR, "config.json")

VALID_SYMBOL_SUFFIXES = ("-VIP", "-STD")


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
    return jsonify(data), 200


VALID_POSITION_ACTIONS = ("SET_BE", "CLOSE")


def _load_current_tickets():
    """Tickets que el EA reportó como abiertos en el último status.json.
    Se usa para no dejar escribir comandos sobre tickets inventados o
    ya cerrados — mismo criterio de "solo lo que el EA ya conoce" que
    orders/status.json."""
    if not os.path.isfile(STATUS_PATH):
        return set()
    try:
        with open(STATUS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return set()
    return {p.get("ticket") for p in data.get("positions", [])}


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

    if ticket not in _load_current_tickets():
        return (
            jsonify(
                {
                    "error": f"ticket {ticket} no aparece en las posiciones abiertas actuales "
                    "(¿ya cerró, o el EA todavía no reportó status.json?)."
                }
            ),
            404,
        )

    actions_dir = os.path.join(ORDERS_DIR, "actions")
    os.makedirs(actions_dir, exist_ok=True)
    # El contenedor corre como root; el EA (Wine) corre con el usuario del
    # host y necesita permiso de escritura sobre la CARPETA para poder
    # borrar el archivo tras procesarlo (FileDelete), no solo sobre el
    # archivo — sin esto queda basura en actions/ para siempre. 0777 es
    # aceptable acá: carpeta local de un solo usuario, sin exponer nada
    # a internet (ver docstring del módulo).
    os.chmod(actions_dir, 0o777)

    # Un archivo por ticket+acción: si mandás BE y CLOSE casi juntos no se
    # pisan entre sí: el EA procesa los dos en el mismo ciclo.
    action_path = os.path.join(actions_dir, f"{ticket}-{action}.json")
    with open(action_path, "w", encoding="utf-8") as f:
        json.dump({"ticket": ticket, "action": action}, f)
    os.chmod(action_path, 0o666)

    return jsonify({"ticket": ticket, "action": action, "queued": True}), 200


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
            cur.execute(
                f"""
                SELECT id, signal_uid, instrument, direction, status,
                       mt4_ticket, entry_price, sl, tp, created_at, updated_at
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
        return jsonify({"symbol_suffix": None}), 200

    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return jsonify({"symbol_suffix": None}), 200

    return jsonify({"symbol_suffix": data.get("symbol_suffix")}), 200


@app.route("/api/config", methods=["POST"])
def api_config_post():
    body = request.get_json(silent=True) or {}
    symbol_suffix = body.get("symbol_suffix")

    if symbol_suffix not in VALID_SYMBOL_SUFFIXES:
        return (
            jsonify(
                {
                    "error": (
                        "symbol_suffix inválido: '{}'. Valores permitidos: {}".format(
                            symbol_suffix, ", ".join(VALID_SYMBOL_SUFFIXES)
                        )
                    )
                }
            ),
            400,
        )

    os.makedirs(ORDERS_DIR, exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump({"symbol_suffix": symbol_suffix}, f)

    return jsonify({"symbol_suffix": symbol_suffix}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
