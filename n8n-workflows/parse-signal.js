// Kronos Bot — Nodo Function (n8n): parser regex de señales nuevas
// Fuente de reglas: PROTOCOLOS_KRONOS_BOT.md (secciones 4.1, 4.2, 4.3)
//
// Entrada esperada (payload de Telethon): message_id, chat_id, sender,
// text, timestamp, reply_to_message_id
//
// Este nodo SOLO detecta y parsea señales nuevas de formato fijo.
// No calcula lotaje, no inserta en la base de datos, no envía
// notificaciones — eso lo hacen otros nodos del workflow.

const MAX_AGE_MINUTES = 5;

// Formato fijo esperado:
//   INSTRUMENTO BUY|SELL [LIMIT] PRECIO TP VALOR [TP VALOR ...] SL VALOR
// El label "TP" se repite una vez por cada take profit, sin número pegado
// (no existe "TP1"/"TP2" en los mensajes reales del grupo). Puede venir
// en una sola línea o con saltos de línea entre campos — el código
// colapsa los saltos de línea en espacios antes de aplicar el regex.
// Ejemplos reales:
//   "XAUUSD BUY 4372  TP 4376  SL 4347"
//   "XAUUSD SELL 4388\nTP 4386\nTP 4385\nTP 4380\nTP 4370\nSL 4414"
// Sin ancla $ al final: los mensajes reales a veces traen texto
// adicional después del SL (emojis, comentarios). \b asegura que el
// valor de SL termine en límite de palabra, sin exigir fin de string.
const SIGNAL_REGEX = /^([A-Z]{3,10})\s+(BUY|SELL)\s+(LIMIT\s+)?(\d+(?:\.\d+)?)\s+TP\s+(\d+(?:\.\d+)?)(?:\s+TP\s+(\d+(?:\.\d+)?))?(?:\s+TP\s+\d+(?:\.\d+)?)*\s+SL\s+(\d+(?:\.\d+)?)\b/i;

// Regex secundario: mismo formato pero sin exigir SL. Se usa solo para
// distinguir "señal con SL faltante" (sección 4.2 regla 5 — no se
// inventa el SL, la señal no se ejecuta hasta tenerlo) de un mensaje
// que directamente no es una señal nueva.
const SIGNAL_WITHOUT_SL_REGEX = /^([A-Z]{3,10})\s+(BUY|SELL)\s+(LIMIT\s+)?(\d+(?:\.\d+)?)\s+TP\s+(\d+(?:\.\d+)?)(?:\s+TP\s+\d+(?:\.\d+)?)*\b/i;

function parseTimestamp(rawTimestamp) {
  if (typeof rawTimestamp === 'number') {
    // Segundos unix -> ms si el valor es demasiado pequeño para ser ms
    return new Date(rawTimestamp < 1e12 ? rawTimestamp * 1000 : rawTimestamp);
  }
  return new Date(rawTimestamp);
}

const results = [];

for (const item of $input.all()) {
  const payload = item.json;
  const rawText = (payload.text || '').trim().replace(/\s+/g, ' ');

  const match = rawText.match(SIGNAL_REGEX);

  if (!match) {
    // No coincide con el formato completo de señal nueva. Puede ser
    // una instrucción de seguimiento, un mensaje no relacionado, o
    // una señal real con el SL faltante — se distinguen para no
    // perder de vista este último caso (protocolo sección 4.2 regla 5).
    const partialMatch = rawText.match(SIGNAL_WITHOUT_SL_REGEX);
    results.push({
      json: {
        ...payload,
        matched: false,
        reason: partialMatch ? 'MISSING_SL' : 'NO_MATCH_FIXED_FORMAT',
      },
    });
    continue;
  }

  const [, instrument, direction, limitFlag, entryPrice, tp1, tp2, sl] = match;

  const signalDate = parseTimestamp(payload.timestamp);
  if (isNaN(signalDate.getTime())) {
    results.push({
      json: {
        ...payload,
        matched: false,
        reason: 'INVALID_TIMESTAMP',
      },
    });
    continue;
  }

  const ageMinutes = (Date.now() - signalDate.getTime()) / 60000;

  if (ageMinutes > MAX_AGE_MINUTES) {
    // Regla de antigüedad (sección 4.3): binaria, sin excepciones.
    results.push({
      json: {
        ...payload,
        matched: true,
        status: 'EXPIRED',
        interpreted_by: 'REGEX',
      },
    });
    continue;
  }

  results.push({
    json: {
      ...payload,
      matched: true,
      status: 'PENDING_CONFIRMATION',
      interpreted_by: 'REGEX',
      instrument: instrument.toUpperCase(),
      direction: direction.toUpperCase(),
      execution_type: limitFlag ? 'LIMIT' : 'MARKET',
      entry_price: parseFloat(entryPrice),
      tp: parseFloat(tp1), // TP usado para ejecutar, según protocolo sección 4.2 regla 6
      tp2: tp2 !== undefined ? parseFloat(tp2) : null, // solo informativo, no se usa para ejecutar
      sl: parseFloat(sl),
      raw_text: rawText,
    },
  });
}

return results;
