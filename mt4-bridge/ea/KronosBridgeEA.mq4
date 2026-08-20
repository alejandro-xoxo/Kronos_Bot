#property strict
#property copyright "Kronos Bot"
#property version   "1.00"
#property description "EA puente: ejecuta órdenes que n8n deja en mt4-bridge/orders/pending/"
#property description "y reporta el resultado en mt4-bridge/orders/results/."
#property description "Formato de archivos: mt4-bridge/FORMATO_ARCHIVOS.md"
#property description "Reglas de negocio: PROTOCOLOS_KRONOS_BOT.md"
#property description ""
#property description "IMPORTANTE: usa la carpeta Common\\Files (flag FILE_COMMON), no la"
#property description "carpeta MQL4\\Files del terminal — mt4-bridge/orders/{pending,results}"
#property description "en el repo son symlinks locales hacia Common\\Files\\orders\\ (ver"
#property description "CLAUDE.md). Esto NO calcula lotaje inteligente ni gestiona cierres/"
#property description "modificaciones — solo abre órdenes nuevas con los datos que ya vienen"
#property description "resueltos en el JSON (lote fijo 0.01, protocolo sección 5)."
#property description ""
#property description "También lee orders/config.json en cada ciclo (sufijo de símbolo"
#property description "dinámico, sin recompilar) y escribe orders/status.json con las"
#property description "posiciones abiertas de este EA (magic number) en cada ciclo."
#property description ""
#property description "orders/actions/*.json: comandos de break-even (SET_BE), BE inverso sobre el TP (SET_TP_BE) y cierre"
#property description "a mercado (CLOSE) sobre posiciones ya abiertas, generados desde"
#property description "el dashboard web — solo actúa sobre tickets con el magic number"
#property description "de este EA, nunca sobre operativa manual del usuario."

//--- Parámetros configurables desde las propiedades del EA en MT4
input int    InpPollIntervalSeconds = 1;          // Intervalo de polling de orders/pending/ y orders/actions/ (segundos)
input int    InpSlippage            = 5;          // Slippage máximo en puntos
input int    InpMagicNumber         = 20260814;   // Magic number para identificar órdenes de este EA
input string InpSymbolSuffix        = "-VIP";     // Sufijo del símbolo real: "-VIP" (demo) / "-STD" (real, cuenta 23096429)

//--- Rutas relativas a Common\Files (todas via FILE_COMMON)
#define PENDING_DIR_PATTERN "orders\\pending\\*.json"
#define PENDING_DIR_PREFIX  "orders\\pending\\"
#define RESULTS_DIR_PREFIX  "orders\\results\\"
#define CONFIG_FILE_PATH    "orders\\config.json"
#define STATUS_FILE_PATH    "orders\\status.json"
#define ACTIONS_DIR_PATTERN "orders\\actions\\*.json"
#define ACTIONS_DIR_PREFIX  "orders\\actions\\"
#define ACTION_RESULTS_DIR_PREFIX "orders\\action_results\\"

//--- Sufijo de símbolo efectivo: arranca con InpSymbolSuffix (fallback) y
//    puede actualizarse en caliente vía orders/config.json (ver
//    UpdateSymbolSuffixFromConfig), sin necesidad de recompilar el EA.
string g_SymbolSuffix;

//--- Estructura de una orden pendiente ya parseada
struct PendingOrder
{
   int    signal_id;
   string signal_uid;
   string instrument;      // instrumento tal como llega de n8n (ej. "XAUUSD")
   string direction;       // "BUY" | "SELL"
   string execution_type;  // "MARKET" | "LIMIT"
   double entry_price;
   double sl;
   double tp;
   double lot;
};

//+------------------------------------------------------------------+
//| Mapeo instrumento -> símbolo real del bróker. Solo los dos        |
//| instrumentos que se operan hoy (XAUUSD, EURUSD) están permitidos  |
//| — cualquier otro se rechaza explícitamente, sin intentar operar.  |
//| El sufijo real (InpSymbolSuffix) depende del TIPO DE CUENTA, no   |
//| del instrumento: "-VIP" en demo (911260411), "-STD" en real       |
//| (23096429) — se cambia desde Properties > Inputs en MT4, sin      |
//| recompilar.                                                       |
//+------------------------------------------------------------------+
bool ResolveBrokerSymbol(const string instrument, string &brokerSymbol)
{
   if(instrument != "XAUUSD" && instrument != "EURUSD")
      return false;

   brokerSymbol = instrument + g_SymbolSuffix;
   return true;
}

//+------------------------------------------------------------------+
//| OnInit / OnDeinit — arranca y detiene el polling por timer       |
//| (punto de robustez 1: OnTimer, no OnTick — no depende de que     |
//| lleguen ticks de precio para revisar archivos pendientes)        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_SymbolSuffix = InpSymbolSuffix;

   // orders/pending, orders/results y orders/actions ya existen como
   // symlinks locales creados por scripts/setup-mt4.sh (ver CLAUDE.md);
   // orders/action_results es nueva y nadie más la crea — sin esto,
   // WriteActionResult() fallaría en el primer intento porque MQL4 no
   // escribe en una carpeta que no existe. FolderCreate no falla si la
   // carpeta ya existe, así que es seguro llamarlo siempre.
   FolderCreate("orders\\action_results", FILE_COMMON);

   if(!EventSetTimer(InpPollIntervalSeconds))
   {
      Print("Kronos EA: no se pudo configurar el timer, error ", GetLastError());
      return(INIT_FAILED);
   }

   Print("Kronos EA: iniciado. Polling de ", PENDING_DIR_PATTERN,
         " cada ", InpPollIntervalSeconds, "s (Common\\Files).");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("Kronos EA: detenido (razón ", reason, ").");
}

//+------------------------------------------------------------------+
//| OnTick — deliberadamente vacío. Toda la lógica corre en OnTimer. |
//+------------------------------------------------------------------+
void OnTick()
{
}

//+------------------------------------------------------------------+
//| OnTimer — dispara el ciclo de polling                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateSymbolSuffixFromConfig();
   ProcessPendingOrders();
   ProcessPositionActions();
   WritePositionsStatus();
}

//+------------------------------------------------------------------+
//| Lee orders/config.json (si existe) y actualiza g_SymbolSuffix    |
//| cuando trae un "symbol_suffix" válido ("-VIP" o "-STD"). Nunca   |
//| rompe el ciclo: si el archivo no existe, no parsea, o el valor   |
//| no es uno de los dos permitidos, se deja g_SymbolSuffix como     |
//| estaba (input o último valor válido leído).                      |
//+------------------------------------------------------------------+
void UpdateSymbolSuffixFromConfig()
{
   string content;
   if(!ReadEntireFile(CONFIG_FILE_PATH, content))
      return; // no existe orders/config.json todavía — caso normal

   string suffix;
   if(!JsonGetValue(content, "symbol_suffix", suffix))
      return; // JSON sin la clave esperada, se ignora

   if(suffix != "-VIP" && suffix != "-STD")
      return; // valor no soportado, se ignora (validación estricta)

   if(suffix != g_SymbolSuffix)
   {
      Print("Kronos EA: symbol_suffix actualizado desde orders/config.json: ",
            g_SymbolSuffix, " -> ", suffix);
      g_SymbolSuffix = suffix;
   }
}

//+------------------------------------------------------------------+
//| Recorre orders/pending/*.json y procesa cada archivo encontrado  |
//+------------------------------------------------------------------+
void ProcessPendingOrders()
{
   string fileName;
   long searchHandle = FileFindFirst(PENDING_DIR_PATTERN, fileName, FILE_COMMON);

   if(searchHandle == INVALID_HANDLE)
      return; // no hay órdenes pendientes en este ciclo, nada que hacer

   bool isFirstFile = true;
   do
   {
      if(!isFirstFile)
      {
         // Pausa corta entre órdenes consecutivas del mismo ciclo. Sin
         // esto, cuando llegan 2+ archivos juntos (ej. señal multi-TP,
         // sub-señales A y B) el segundo OrderSend puede rechazarse con
         // error 4109 (trade not allowed) por mandarse demasiado pegado
         // al primero — bug real detectado en pruebas en vivo (ticket
         // exitoso en la primera sub-señal, 4109 en la segunda, mismo
         // ciclo). No es un problema de permisos del EA/terminal.
         Sleep(500);
      }
      isFirstFile = false;
      ProcessSingleFile(fileName);
   }
   while(FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);
}

//+------------------------------------------------------------------+
//| Procesa un único archivo de orden pendiente                      |
//+------------------------------------------------------------------+
void ProcessSingleFile(string fileName)
{
   string pendingPath = PENDING_DIR_PREFIX + fileName;

   // Reclamar el archivo ANTES de leerlo/ejecutar nada: se renombra a
   // .processing con FileMove. Bug real (2026-08-20): con OnTimer cada
   // 1s, si el timer de Wine dispara en ráfaga (varios ticks pegados
   // tras un atraso) y el FileDelete() del ciclo anterior todavía no
   // se reflejaba en el listado del symlink a Common\Files, el mismo
   // *.json volvía a aparecer en FileFindNext y se reprocesaba —
   // mandó la misma señal 3 veces (3 tickets idénticos en <100ms,
   // ver STATUS.md). El rename es atómico a nivel de filesystem y,
   // como el destino ya no matchea el patrón "*.json" de
   // PENDING_DIR_PATTERN, un ciclo posterior nunca puede volver a
   // encontrarlo — a diferencia de depender de que el FileDelete()
   // final sea instantáneo.
   string claimedPath = pendingPath + ".processing";
   if(!FileMove(pendingPath, FILE_COMMON, claimedPath, FILE_COMMON))
   {
      // Ya lo reclamó (o procesó y borró) otro ciclo/llamada — no es
      // un error, es exactamente la protección funcionando.
      return;
   }

   string content = ReadEntireFile(claimedPath);
   if(content == "")
   {
      // No se borra: puede ser un archivo a medio escribir por n8n en
      // este instante. Se revierte el claim para reintentar en el
      // próximo ciclo del timer.
      Print("Kronos EA: no se pudo leer ", claimedPath, " (vacío o en uso), se reintenta luego.");
      FileMove(claimedPath, FILE_COMMON, pendingPath, FILE_COMMON);
      return;
   }

   Print("Kronos EA: procesando ", claimedPath);

   //--- Punto de robustez 2: validar el JSON antes de ejecutar nada
   PendingOrder order;
   string parseError = "";
   bool parsedOk = ParseOrderJson(content, order, parseError);

   int signalIdForResult = parsedOk ? order.signal_id : FallbackSignalIdFromFilename(fileName);

   if(!parsedOk)
   {
      Print("Kronos EA: JSON inválido en ", claimedPath, ": ", parseError);
      WriteResult(signalIdForResult, false, 0, 0.0, -1, "JSON inválido: " + parseError);
      FileDelete(claimedPath, FILE_COMMON); // punto de robustez 3: nunca se reprocesa un archivo ya leído
      return;
   }

   int    ticket        = -1;
   double executedPrice = 0.0;
   int    errorCode     = 0;
   string errorMessage  = "";

   bool ok = ExecuteOrder(order, ticket, executedPrice, errorCode, errorMessage);

   //--- Punto de robustez 4: reportar tanto éxito como fallo en results/
   if(ok)
      WriteResult(order.signal_id, true, ticket, executedPrice, 0, "");
   else
      WriteResult(order.signal_id, false, 0, 0.0, errorCode, errorMessage);

   //--- Punto de robustez 3 (continuación): mover/borrar tras procesar
   FileDelete(claimedPath, FILE_COMMON);
}

//+------------------------------------------------------------------+
//| Ejecuta la orden en MT4 según execution_type/direction           |
//+------------------------------------------------------------------+
bool ExecuteOrder(const PendingOrder &order, int &ticket, double &executedPrice,
                   int &errorCode, string &errorMessage)
{
   string brokerSymbol;
   if(!ResolveBrokerSymbol(order.instrument, brokerSymbol))
   {
      errorCode    = -1;
      errorMessage = "INSTRUMENT_NOT_SUPPORTED: " + order.instrument;
      Print("Kronos EA: ", errorMessage);
      return false;
   }

   if(!SymbolSelect(brokerSymbol, true))
   {
      errorCode    = -2;
      errorMessage = "SYMBOL_NOT_FOUND: " + brokerSymbol;
      Print("Kronos EA: ", errorMessage);
      return false;
   }

   RefreshRates();

   double ask = MarketInfo(brokerSymbol, MODE_ASK);
   double bid = MarketInfo(brokerSymbol, MODE_BID);

   int    cmd;
   double price;

   // protocolo sección 4.2 reglas 2-4 (actualizado 2026-08-19, excepción
   // autorizada explícitamente por el usuario, aplicada directo a
   // producción): la comparación de precio actual vs entry_price decide
   // mercado-vs-pendiente para TODA señal, sea MARKET o LIMIT.
   // execution_type pasa a ser informativo/de log, no determina la rama.
   // BUY: se quería comprar a entry_price — si el Ask ya está en ese
   // nivel o por debajo, ya "llegó", se ejecuta a mercado.
   // SELL: se quería vender a entry_price — si el Bid ya está en ese
   // nivel o por encima, ya "llegó", se ejecuta a mercado.
   bool limitLevelAlreadyReached =
      ((order.direction == "BUY"  && ask <= order.entry_price) ||
       (order.direction == "SELL" && bid >= order.entry_price));

   if(limitLevelAlreadyReached)
   {
      if(order.execution_type == "LIMIT")
         Print("Kronos EA: signal_id=", order.signal_id,
               " era LIMIT pero el precio ya alcanzó entry_price (",
               DoubleToString(order.entry_price, 5),
               "), se ejecuta como MARKET.");

      if(order.direction == "BUY")
      {
         cmd   = OP_BUY;
         price = ask;
      }
      else
      {
         cmd   = OP_SELL;
         price = bid;
      }
   }
   else // el precio todavía no llegó al nivel de entry_price (toda señal,
        // sea MARKET o LIMIT) — se coloca como orden pendiente. Se elige
        // BUYLIMIT/BUYSTOP/SELLLIMIT/SELLSTOP según dónde quedó el precio
        // actual respecto a entry_price.
   {
      if(order.direction == "BUY")
         cmd = (order.entry_price < ask) ? OP_BUYLIMIT : OP_BUYSTOP;
      else
         cmd = (order.entry_price > bid) ? OP_SELLLIMIT : OP_SELLSTOP;

      price = order.entry_price;
   }

   ResetLastError();
   ticket = OrderSend(brokerSymbol, cmd, order.lot, price, InpSlippage,
                       order.sl, order.tp, "KronosBot:" + order.signal_uid,
                       InpMagicNumber, 0, clrNONE);

   if(ticket < 0)
   {
      errorCode    = GetLastError();
      errorMessage = "OrderSend falló, error " + IntegerToString(errorCode);
      Print("Kronos EA: fallo al ejecutar signal_id=", order.signal_id,
            " (", order.signal_uid, "): ", errorMessage);
      return false;
   }

   if(OrderSelect(ticket, SELECT_BY_TICKET))
      executedPrice = OrderOpenPrice();
   else
      executedPrice = price; // fallback: precio con el que se envió la orden

   Print("Kronos EA: orden ejecutada OK, signal_id=", order.signal_id,
         " signal_uid=", order.signal_uid, " ticket=", ticket,
         " precio=", DoubleToString(executedPrice, 5));
   return true;
}

//+------------------------------------------------------------------+
//| Escribe orders/results/{signal_id}.json                          |
//+------------------------------------------------------------------+
void WriteResult(int signalId, bool success, int ticket, double executedPrice,
                  int errorCode, string errorMessage)
{
   string executedAt = ToIso8601Utc(TimeGMT());

   string json = "{\n";
   json += "  \"signal_id\": " + IntegerToString(signalId) + ",\n";
   json += "  \"success\": " + (success ? "true" : "false") + ",\n";
   json += "  \"ticket\": " + (success ? IntegerToString(ticket) : "null") + ",\n";
   json += "  \"executed_price\": " + (success ? DoubleToString(executedPrice, 5) : "null") + ",\n";
   json += "  \"executed_at\": \"" + executedAt + "\",\n";
   json += "  \"error_code\": " + (success ? "null" : IntegerToString(errorCode)) + ",\n";
   json += "  \"error_message\": " + (success ? "null" : ("\"" + JsonEscape(errorMessage) + "\"")) + "\n";
   json += "}\n";

   string resultPath = RESULTS_DIR_PREFIX + IntegerToString(signalId) + ".json";

   if(WriteEntireFile(resultPath, json))
      Print("Kronos EA: resultado escrito en ", resultPath, " (success=", success, ")");
   else
      Print("Kronos EA: ERROR al escribir ", resultPath, " — revisar permisos de Common\\Files");
}

//+------------------------------------------------------------------+
//| Recorre orders/actions/*.json — comandos de break-even/cierre    |
//| sobre posiciones ya abiertas, generados desde el dashboard web.  |
//+------------------------------------------------------------------+
void ProcessPositionActions()
{
   string fileName;
   long searchHandle = FileFindFirst(ACTIONS_DIR_PATTERN, fileName, FILE_COMMON);

   if(searchHandle == INVALID_HANDLE)
      return; // no hay comandos pendientes en este ciclo

   do
   {
      ProcessSingleAction(fileName);
   }
   while(FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);
}

//+------------------------------------------------------------------+
//| Procesa un único archivo de orders/actions/. Formato:            |
//|   { "ticket": 202230990, "action": "SET_BE" | "SET_TP_BE" | "CLOSE" } |
//| Solo actúa sobre tickets con el InpMagicNumber de este EA — nunca|
//| toca operativa manual del usuario en la misma cuenta. El archivo |
//| se borra siempre tras intentarlo (éxito o fallo), salvo que no   |
//| se haya podido leer (escritura a medias del dashboard).          |
//+------------------------------------------------------------------+
void ProcessSingleAction(string fileName)
{
   string actionPath = ACTIONS_DIR_PREFIX + fileName;

   string content;
   if(!ReadEntireFile(actionPath, content))
   {
      Print("Kronos EA: no se pudo leer ", actionPath, " (vacío o en uso), se reintenta luego.");
      return;
   }

   string ticketStr, action;
   bool ok = JsonGetValue(content, "ticket", ticketStr) && JsonGetValue(content, "action", action);

   if(!ok)
   {
      Print("Kronos EA: JSON inválido en ", actionPath, ", se descarta.");
      FileDelete(actionPath, FILE_COMMON);
      return;
   }

   int ticket = (int)StringToInteger(ticketStr);

   if(ticket <= 0 || (action != "SET_BE" && action != "SET_TP_BE" && action != "CLOSE"))
   {
      Print("Kronos EA: acción inválida en ", actionPath, " (ticket=", ticket,
            ", action=", action, "), se descarta.");
      FileDelete(actionPath, FILE_COMMON);
      return;
   }

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      Print("Kronos EA: ", actionPath, " — ticket ", ticket,
            " no encontrado (¿ya cerrado?), se descarta.");
      FileDelete(actionPath, FILE_COMMON);
      return;
   }

   if(OrderMagicNumber() != InpMagicNumber)
   {
      Print("Kronos EA: ", actionPath, " — ticket ", ticket,
            " no pertenece a este EA (magic distinto), se ignora por seguridad.");
      FileDelete(actionPath, FILE_COMMON);
      return;
   }

   if(action == "SET_BE")
      ApplyBreakEven(ticket);
   else if(action == "SET_TP_BE")
      ApplyTakeProfitBreakEven(ticket);
   else // "CLOSE"
      ApplyClose(ticket);

   FileDelete(actionPath, FILE_COMMON);
}

//+------------------------------------------------------------------+
//| Mueve el SL de una posición abierta a su precio de apertura      |
//| (break-even) — mismo cálculo para BUY y SELL. Asume que el       |
//| ticket ya está seleccionado (OrderSelect) por el llamador.       |
//+------------------------------------------------------------------+
void ApplyBreakEven(int ticket)
{
   double openPrice = OrderOpenPrice();

   ResetLastError();
   bool ok      = OrderModify(ticket, openPrice, openPrice, OrderTakeProfit(), 0, clrNONE);
   int  errCode = ok ? 0 : GetLastError();

   if(ok)
      Print("Kronos EA: ticket ", ticket, " movido a break-even (SL=",
            DoubleToString(openPrice, 5), ").");
   else
      Print("Kronos EA: ERROR al mover a break-even ticket ", ticket,
            ", error ", errCode);

   WriteActionResult(ticket, "SET_BE", ok, ok ? openPrice : 0.0, errCode);
}

//+------------------------------------------------------------------+
//| "BE inverso": mueve el TP (no el SL) al precio de apertura de la |
//| posición — deja la operación sin objetivo de ganancia, cerrando  |
//| solo si vuelve al precio de entrada. Mismo cálculo para BUY y    |
//| SELL, misma validación de magic number que ApplyBreakEven (ver   |
//| ProcessSingleAction). Asume que el ticket ya está seleccionado.  |
//+------------------------------------------------------------------+
void ApplyTakeProfitBreakEven(int ticket)
{
   double openPrice = OrderOpenPrice();

   ResetLastError();
   bool ok      = OrderModify(ticket, openPrice, OrderStopLoss(), openPrice, 0, clrNONE);
   int  errCode = ok ? 0 : GetLastError();

   if(ok)
      Print("Kronos EA: ticket ", ticket, " — TP movido a break-even (TP=",
            DoubleToString(openPrice, 5), ").");
   else
      Print("Kronos EA: ERROR al mover TP a break-even ticket ", ticket,
            ", error ", errCode);

   WriteActionResult(ticket, "SET_TP_BE", ok, ok ? openPrice : 0.0, errCode);
}

//+------------------------------------------------------------------+
//| Cierra a mercado una posición abierta. Asume que el ticket ya    |
//| está seleccionado (OrderSelect) por el llamador.                 |
//+------------------------------------------------------------------+
void ApplyClose(int ticket)
{
   string symbol = OrderSymbol();
   int    type   = OrderType();
   double lots   = OrderLots();

   RefreshRates();
   double closePrice = (type == OP_BUY) ? MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);

   ResetLastError();
   bool ok      = OrderClose(ticket, lots, closePrice, InpSlippage, clrNONE);
   int  errCode = ok ? 0 : GetLastError();

   if(ok)
      Print("Kronos EA: ticket ", ticket, " cerrado a mercado, precio=",
            DoubleToString(closePrice, 5));
   else
      Print("Kronos EA: ERROR al cerrar ticket ", ticket, ", error ", errCode);

   WriteActionResult(ticket, "CLOSE", ok, closePrice, errCode);
}

//+------------------------------------------------------------------+
//| Escribe orders/action_results/{ticket}-{action}.json — permite   |
//| al dashboard mostrar el resultado REAL del comando (ej. "Invalid |
//| stops") en vez de adivinar comparando el estado de la posición.  |
//| resultPrice: SL nuevo si SET_BE tuvo éxito, precio de cierre si  |
//| CLOSE tuvo éxito; 0.0 si falló (el dashboard no lo usa en fallo).|
//+------------------------------------------------------------------+
void WriteActionResult(int ticket, string action, bool success, double resultPrice, int errorCode)
{
   string errorMessage = success ? "" : ("MT4 error " + IntegerToString(errorCode));

   string json = "{\n";
   json += "  \"ticket\": " + IntegerToString(ticket) + ",\n";
   json += "  \"action\": \"" + action + "\",\n";
   json += "  \"success\": " + (success ? "true" : "false") + ",\n";
   json += "  \"result_price\": " + (success ? DoubleToString(resultPrice, 5) : "null") + ",\n";
   json += "  \"error_code\": " + (success ? "null" : IntegerToString(errorCode)) + ",\n";
   json += "  \"error_message\": " + (success ? "null" : ("\"" + JsonEscape(errorMessage) + "\"")) + ",\n";
   json += "  \"processed_at\": \"" + ToIso8601Utc(TimeGMT()) + "\"\n";
   json += "}\n";

   string path = ACTION_RESULTS_DIR_PREFIX + IntegerToString(ticket) + "-" + action + ".json";
   if(!WriteEntireFile(path, json))
      Print("Kronos EA: ERROR al escribir ", path, " — revisar permisos de Common\\Files");
}

//+------------------------------------------------------------------+
//| Escribe orders/status.json con TODAS las posiciones de mercado   |
//| (OP_BUY/OP_SELL) abiertas en la cuenta, propias del EA o          |
//| abiertas manualmente por el usuario en MT4 — cada una lleva el    |
//| flag "managed" para que el dashboard sepa cuáles puede operar     |
//| (SET_BE/CLOSE solo actúan sobre managed=true, ver                |
//| ProcessActionFile, que sigue filtrando por InpMagicNumber).       |
//| Se sobrescribe completo en cada ciclo.                            |
//+------------------------------------------------------------------+
void WritePositionsStatus()
{
   string positionsJson = "";
   int    count         = 0;

   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      int orderType = OrderType();
      if(orderType != OP_BUY && orderType != OP_SELL)
         continue; // solo posiciones de mercado ya ejecutadas

      bool managed = (OrderMagicNumber() == InpMagicNumber);

      string signalUid = OrderComment();
      string prefix     = "KronosBot:";
      if(StringFind(signalUid, prefix) == 0)
         signalUid = StringSubstr(signalUid, StringLen(prefix));
      else if(!managed)
         signalUid = ""; // comentario manual del usuario, no es un signal_uid

      string direction    = (orderType == OP_BUY) ? "BUY" : "SELL";
      double currentPrice = MarketInfo(OrderSymbol(), (orderType == OP_BUY) ? MODE_BID : MODE_ASK);

      if(count > 0)
         positionsJson += ",\n";

      positionsJson += "    {\n";
      positionsJson += "      \"ticket\": " + IntegerToString(OrderTicket()) + ",\n";
      positionsJson += "      \"managed\": " + (managed ? "true" : "false") + ",\n";
      positionsJson += "      \"signal_uid\": \"" + JsonEscape(signalUid) + "\",\n";
      positionsJson += "      \"symbol\": \"" + OrderSymbol() + "\",\n";
      positionsJson += "      \"direction\": \"" + direction + "\",\n";
      positionsJson += "      \"lot\": " + DoubleToString(OrderLots(), 2) + ",\n";
      positionsJson += "      \"open_price\": " + DoubleToString(OrderOpenPrice(), 5) + ",\n";
      positionsJson += "      \"current_price\": " + DoubleToString(currentPrice, 5) + ",\n";
      positionsJson += "      \"sl\": " + DoubleToString(OrderStopLoss(), 5) + ",\n";
      positionsJson += "      \"tp\": " + DoubleToString(OrderTakeProfit(), 5) + ",\n";
      positionsJson += "      \"profit\": " + DoubleToString(OrderProfit(), 2) + ",\n";
      positionsJson += "      \"open_time\": \"" + ToIso8601Utc(OrderOpenTime()) + "\"\n";
      positionsJson += "    }";

      count++;
   }

   string json = "{\n";
   json += "  \"updated_at\": \"" + ToIso8601Utc(TimeGMT()) + "\",\n";
   json += "  \"account\": {\n";
   json += "    \"number\": " + IntegerToString(AccountNumber()) + ",\n";
   json += "    \"balance\": " + DoubleToString(AccountBalance(), 2) + ",\n";
   json += "    \"equity\": " + DoubleToString(AccountEquity(), 2) + "\n";
   json += "  },\n";
   json += "  \"positions\": [\n";
   json += positionsJson;
   if(count > 0)
      json += "\n";
   json += "  ]\n";
   json += "}\n";

   if(!WriteEntireFile(STATUS_FILE_PATH, json))
      Print("Kronos EA: ERROR al escribir ", STATUS_FILE_PATH, " — revisar permisos de Common\\Files");
}

//+------------------------------------------------------------------+
//| Parseo y validación del JSON de entrada (punto de robustez 2)    |
//| Parser manual minimalista: el schema es plano y fijo (sin        |
//| anidamiento), así que no hace falta un parser JSON genérico.     |
//| Ver mt4-bridge/FORMATO_ARCHIVOS.md para el contrato exacto.       |
//+------------------------------------------------------------------+
bool ParseOrderJson(string json, PendingOrder &order, string &errorMsg)
{
   string sVal;

   if(!JsonGetValue(json, "signal_id", sVal) || sVal == "")
   {
      errorMsg = "signal_id ausente o inválido";
      return false;
   }
   order.signal_id = (int)StringToInteger(sVal);
   if(order.signal_id <= 0)
   {
      errorMsg = "signal_id debe ser un entero positivo";
      return false;
   }

   // Opcional: solo para logs/trazabilidad, no se valida su formato.
   if(!JsonGetValue(json, "signal_uid", order.signal_uid))
      order.signal_uid = "";

   if(!JsonGetValue(json, "instrument", order.instrument) || order.instrument == "")
   {
      errorMsg = "instrument ausente";
      return false;
   }

   if(!JsonGetValue(json, "direction", order.direction) ||
      (order.direction != "BUY" && order.direction != "SELL"))
   {
      errorMsg = "direction inválida (debe ser \"BUY\" o \"SELL\")";
      return false;
   }

   if(!JsonGetValue(json, "execution_type", order.execution_type) ||
      (order.execution_type != "MARKET" && order.execution_type != "LIMIT"))
   {
      errorMsg = "execution_type inválido (debe ser \"MARKET\" o \"LIMIT\")";
      return false;
   }

   if(!JsonGetValue(json, "entry_price", sVal) || sVal == "")
   {
      errorMsg = "entry_price ausente";
      return false;
   }
   order.entry_price = StringToDouble(sVal);
   if(order.entry_price <= 0)
   {
      errorMsg = "entry_price debe ser > 0";
      return false;
   }

   if(!JsonGetValue(json, "sl", sVal) || sVal == "")
   {
      errorMsg = "sl ausente";
      return false;
   }
   order.sl = StringToDouble(sVal);
   if(order.sl <= 0)
   {
      errorMsg = "sl debe ser > 0";
      return false;
   }

   if(!JsonGetValue(json, "tp", sVal) || sVal == "")
   {
      errorMsg = "tp ausente";
      return false;
   }
   order.tp = StringToDouble(sVal);
   if(order.tp <= 0)
   {
      errorMsg = "tp debe ser > 0";
      return false;
   }

   if(!JsonGetValue(json, "lot", sVal) || sVal == "")
   {
      errorMsg = "lot ausente";
      return false;
   }
   order.lot = StringToDouble(sVal);
   if(order.lot <= 0)
   {
      errorMsg = "lot debe ser > 0";
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Extrae el valor crudo (como string) de "key": <valor> en un JSON |
//| plano de un solo nivel. Soporta valores string, numéricos y      |
//| null. Devuelve false si la clave no existe.                      |
//+------------------------------------------------------------------+
bool JsonGetValue(string json, string key, string &value)
{
   string pattern = "\"" + key + "\"";
   int pos = StringFind(json, pattern);
   if(pos < 0)
      return false;

   pos = StringFind(json, ":", pos + StringLen(pattern));
   if(pos < 0)
      return false;

   int i   = pos + 1;
   int len = StringLen(json);

   // saltar espacios en blanco tras los dos puntos
   while(i < len)
   {
      ushort c = StringGetCharacter(json, i);
      if(c != ' ' && c != '\t' && c != '\n' && c != '\r')
         break;
      i++;
   }
   if(i >= len)
      return false;

   ushort first = StringGetCharacter(json, i);

   if(first == '"')
   {
      // valor string: hasta la siguiente comilla (los valores de este
      // schema nunca traen comillas escapadas internamente)
      int start = i + 1;
      int end   = StringFind(json, "\"", start);
      if(end < 0)
         return false;
      value = StringSubstr(json, start, end - start);
      return true;
   }

   if(first == 'n') // null
   {
      value = "";
      return true;
   }

   // valor numérico/booleano: hasta la coma, cierre de llave o salto de línea
   int start = i;
   int end   = start;
   while(end < len)
   {
      ushort c = StringGetCharacter(json, end);
      if(c == ',' || c == '}' || c == '\n' || c == '\r')
         break;
      end++;
   }
   value = StringSubstr(json, start, end - start);
   StringTrimRight(value);
   StringTrimLeft(value);
   return true;
}

//+------------------------------------------------------------------+
//| Escapa caracteres especiales para incrustar un string en JSON    |
//+------------------------------------------------------------------+
string JsonEscape(string s)
{
   string result = s;
   StringReplace(result, "\\", "\\\\");
   StringReplace(result, "\"", "\\\"");
   StringReplace(result, "\n", "\\n");
   StringReplace(result, "\r", "");
   return result;
}

//+------------------------------------------------------------------+
//| Intenta recuperar el signal_id desde el nombre del archivo       |
//| cuando el JSON no se pudo parsear (caso raro: n8n siempre nombra |
//| el archivo "{signal_id}.json"). Devuelve -1 si no es posible.    |
//+------------------------------------------------------------------+
int FallbackSignalIdFromFilename(string fileName)
{
   string base = fileName;
   int dotPos = StringFind(base, ".json");
   if(dotPos > 0)
      base = StringSubstr(base, 0, dotPos);

   if(StringLen(base) == 0)
      return -1;

   long asLong = StringToInteger(base);
   if(asLong <= 0)
      return -1;

   return (int)asLong;
}

//+------------------------------------------------------------------+
//| Lee un archivo completo de Common\Files como string (UTF-8),     |
//| sin usar FILE_TXT — FileReadString en modo texto tokeniza por    |
//| espacios y rompería el JSON. Se lee en binario y se decodifica.  |
//+------------------------------------------------------------------+
string ReadEntireFile(string relativePath)
{
   int handle = FileOpen(relativePath, FILE_READ | FILE_BIN | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return "";

   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      return "";
   }

   uchar buffer[];
   ArrayResize(buffer, fileSize);
   int bytesRead = FileReadArray(handle, buffer, 0, fileSize);
   FileClose(handle);

   if(bytesRead <= 0)
      return "";

   return CharArrayToString(buffer, 0, bytesRead, CP_UTF8);
}

//+------------------------------------------------------------------+
//| Igual que ReadEntireFile(path) de arriba, pero como bool + out   |
//| param: no distingue "vacío" de "no existe" en el valor de        |
//| retorno string, así que esta variante permite a los llamadores   |
//| tratar "el archivo no existe todavía" como caso normal (ej.      |
//| orders/config.json antes de que el dashboard lo escriba), sin    |
//| loggear error. No lanza error si el archivo simplemente falta.   |
//+------------------------------------------------------------------+
bool ReadEntireFile(string relativePath, string &outContent)
{
   int handle = FileOpen(relativePath, FILE_READ | FILE_BIN | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false; // caso normal: el archivo todavía no existe

   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      return false;
   }

   uchar buffer[];
   ArrayResize(buffer, fileSize);
   int bytesRead = FileReadArray(handle, buffer, 0, fileSize);
   FileClose(handle);

   if(bytesRead <= 0)
      return false;

   outContent = CharArrayToString(buffer, 0, bytesRead, CP_UTF8);
   return true;
}

//+------------------------------------------------------------------+
//| Escribe un string completo (UTF-8) en Common\Files, en binario   |
//| para evitar que MT4 agregue terminadores/formato de texto.       |
//+------------------------------------------------------------------+
bool WriteEntireFile(string relativePath, string content)
{
   int handle = FileOpen(relativePath, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false;

   uchar buffer[];
   int len = StringToCharArray(content, buffer, 0, WHOLE_ARRAY, CP_UTF8);
   // StringToCharArray agrega un terminador nulo final; se recorta para
   // no dejar un byte 0x00 colgado al final del JSON en disco.
   if(len > 0 && buffer[len - 1] == 0)
      len--;

   FileWriteArray(handle, buffer, 0, len);
   FileClose(handle);
   return true;
}

//+------------------------------------------------------------------+
//| Formatea un datetime como ISO 8601 UTC ("YYYY-MM-DDTHH:MM:SSZ")  |
//+------------------------------------------------------------------+
string ToIso8601Utc(datetime t)
{
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                        TimeYear(t), TimeMonth(t), TimeDay(t),
                        TimeHour(t), TimeMinute(t), TimeSeconds(t));
}
