// Script de prueba standalone para parse-signal.js
// parse-signal.js está escrito para correr dentro de un nodo Function
// de n8n (usa `$input.all()` y `return` a nivel de módulo), así que
// aquí se envuelve su código fuente en una función que simula ese
// entorno, en vez de duplicar la lógica del parser.
//
// Uso: node n8n-workflows/test-parser.js

const fs = require('fs');
const path = require('path');

const parserSource = fs.readFileSync(
  path.join(__dirname, 'parse-signal.js'),
  'utf8'
);

function runParser(items) {
  const $input = {
    all: () => items.map((json) => ({ json })),
  };
  const fn = new Function('$input', parserSource);
  return fn($input);
}

const testCases = [
  {
    label: 'Señal en una línea',
    text: 'XAUUSD BUY 4372  TP 4376  SL 4347',
  },
  {
    label: 'Señal en varias líneas, múltiples TP',
    text: 'XAUUSD SELL 4388\nTP 4386\nTP 4385\nTP 4380\nTP 4370\nSL 4414',
  },
  {
    label: 'Instrucción de seguimiento (no debe matchear)',
    text: 'MOVER el sl a be',
  },
];

const payloads = testCases.map((tc, i) => ({
  message_id: i + 1,
  chat_id: -1001234567890,
  sender: 'test-caller',
  text: tc.text,
  timestamp: new Date().toISOString(),
  reply_to_message_id: null,
}));

const results = runParser(payloads);

testCases.forEach((tc, i) => {
  console.log(`\n--- Caso ${i + 1}: ${tc.label} ---`);
  console.log('Texto:', JSON.stringify(tc.text));
  console.log('Resultado:', JSON.stringify(results[i].json, null, 2));
});
