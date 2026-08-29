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
#property description "Lee orders/config.json en cada ciclo (perfil de cuenta activo,"
#property description "ver ENUM_KRONOS_PROFILE) y escribe orders/status.json con las"
#property description "posiciones abiertas de este EA (magic number) en cada ciclo."
#property description ""
#property description "orders/actions/*.json: comandos de break-even (SET_BE), BE inverso sobre el TP (SET_TP_BE) y cierre"
#property description "a mercado (CLOSE) sobre posiciones ya abiertas, generados desde"
#property description "el dashboard web — solo actúa sobre tickets con el magic number"
#property description "de este EA, nunca sobre operativa manual del usuario."

//+------------------------------------------------------------------+
//| Perfiles de cuenta soportados. Un único input tipo enum (no dos   |
//| inputs de texto libre) para que cuenta esperada y sufijo de       |
//| símbolo nunca puedan desincronizarse entre sí — bug real ya       |
//| ocurrido: orders/config.json traía "-VIP" mientras la cuenta      |
//| conectada era la real (23096429, "-STD"), causando OrderSend      |
//| error 130 (ERR_INVALID_STOPS) en cada señal confirmada (ver       |
//| STATUS.md, punto 14). Elegir el perfil correcto en Properties >   |
//| Inputs al adjuntar el EA a un gráfico.                            |
//+------------------------------------------------------------------+
enum ENUM_KRONOS_PROFILE
{
   PROFILE_PROD_STD, // PROD — cuenta real 23096429, símbolo *-STD
   PROFILE_DEMO_VIP  // DEMO — cuenta demo 911260411, símbolo *-VIP (sufijo sin verificar end-to-end todavía, ver DEV_SETUP.md)
};

//--- Parámetros configurables desde las propiedades del EA en MT4
input ENUM_KRONOS_PROFILE InpProfile           = PROFILE_PROD_STD; // Perfil de cuenta esperado — valor INICIAL, hasta que orders/config.json traiga un "profile" válido (ver UpdateProfileFromConfig); ver g_ActiveProfile
input int                 InpPollIntervalSeconds = 1;              // Intervalo de polling de orders/pending/ y orders/actions/ (segundos)
input int                 InpSlippage            = 5;              // Slippage máximo en puntos
input int                 InpMagicNumber         = 20260814;       // Magic number para identificar órdenes de este EA
input int                 InpMaxSignalAgeMinutes = 5;              // Antigüedad máxima (minutos) de orders/pending/*.json antes de descartarlo sin ejecutar (protocolo sección 4.3, mismo umbral que ya valida n8n)

//--- Rutas relativas a Common\Files (todas via FILE_COMMON)
#define PENDING_DIR_PATTERN "orders\\pending\\*.json"
#define PENDING_DIR_PREFIX  "orders\\pending\\"
#define RESULTS_DIR_PREFIX  "orders\\results\\"
#define STATUS_FILE_PATH    "orders\\status.json"
#define ACTIONS_DIR_PATTERN "orders\\actions\\*.json"
#define ACTIONS_DIR_PREFIX  "orders\\actions\\"
#define ACTION_RESULTS_DIR_PREFIX "orders\\action_results\\"
#define CLOSED_DIR_PREFIX   "orders\\closed\\"
#define CLOSED_GVAR_PREFIX  "KronosClosedReported_"
#define CONFIG_FILE_PATH    "orders\\config.json"

//--- Perfil efectivo en uso: arranca en InpProfile (OnInit) y puede
//    actualizarse en caliente vía orders/config.json en cada OnTimer
//    (ver UpdateProfileFromConfig). ValidateAccountProfile() SIEMPRE
//    valida contra este valor, nunca contra InpProfile directamente
//    — así el chequeo de seguridad corre igual sin importar de dónde
//    salió el perfil.
ENUM_KRONOS_PROFILE g_ActiveProfile;
datetime            g_ProfileUpdatedAt = 0; // 0 = nunca actualizado desde config.json (sigue en el valor de InpProfile)

//--- Sufijo de símbolo efectivo: derivado de g_ActiveProfile (ver
//    GetProfileInfo), recalculado cada vez que g_ActiveProfile cambia.
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
   datetime created_at;      // UTC, desde el JSON ("created_at" ISO 8601); 0 si ausente o no se pudo parsear (ver STALE_SIGNAL en ProcessSingleFile)
};

//+------------------------------------------------------------------+
//| Mapeo instrumento -> símbolo real del bróker. Solo los dos        |
//| instrumentos que se operan hoy (XAUUSD, EURUSD) están permitidos  |
//| — cualquier otro se rechaza explícitamente, sin intentar operar.  |
//| El sufijo real depende del perfil de cuenta activo                |
//| (g_ActiveProfile, ver GetProfileInfo), que puede venir de         |
//| InpProfile o de orders/config.json (ver UpdateProfileFromConfig)  |
//| — en ambos casos, siempre validado contra AccountNumber() antes   |
//| de operar (ver ValidateAccountProfile).                           |
//+------------------------------------------------------------------+
bool ResolveBrokerSymbol(const string instrument, string &brokerSymbol)
{
   if(instrument != "XAUUSD" && instrument != "EURUSD")
      return false;

   brokerSymbol = instrument + g_SymbolSuffix;
   return true;
}

//+------------------------------------------------------------------+
//| Mapeo perfil -> (cuenta esperada, sufijo esperado). Hardcodeado a |
//| propósito (no configurable en runtime): el punto es que cuenta y  |
//| sufijo NUNCA se puedan desincronizar entre sí, como pasó con el   |
//| viejo InpSymbolSuffix suelto.                                     |
//+------------------------------------------------------------------+
struct KronosProfileInfo
{
   long   expectedAccount;
   string expectedSuffix;
   string label; // solo para logs legibles
};

KronosProfileInfo GetProfileInfo(ENUM_KRONOS_PROFILE profile)
{
   KronosProfileInfo info;
   switch(profile)
   {
      case PROFILE_DEMO_VIP:
         info.expectedAccount = 911260411;
         info.expectedSuffix  = "-VIP";
         info.label           = "DEMO_VIP";
         break;
      case PROFILE_PROD_STD:
      default:
         info.expectedAccount = 23096429;
         info.expectedSuffix  = "-STD";
         info.label           = "PROD_STD";
         break;
   }
   return info;
}

//--- Estado de bloqueo por discrepancia de cuenta, consultado desde
//    OnTimer() antes de operar nada, y reportado en
//    WritePositionsStatus() como "account_mismatch".
bool g_AccountMismatch         = false;
long g_AccountMismatchExpected = 0;
long g_AccountMismatchActual   = 0;

//+------------------------------------------------------------------+
//| Valida AccountNumber() contra el perfil activo (g_ActiveProfile). |
//| Se llama desde OnInit() (para no arrancar mal configurado) y      |
//| desde OnTimer() en cada ciclo (por si el usuario cambia de cuenta |
//| sin reiniciar el EA — MT4 lo permite). Mientras hay discrepancia, |
//| el llamador NO debe procesar orders/pending/ ni orders/actions/;  |
//| a diferencia del caso de JSON inválido, los archivos de pending/  |
//| NO se borran acá — la señal sigue siendo potencialmente válida,   |
//| solo no se puede ejecutar todavía con seguridad (ver también el   |
//| chequeo de antigüedad en ProcessSingleFile, que sí borra, pero es |
//| un caso distinto).                                                |
//+------------------------------------------------------------------+
bool ValidateAccountProfile()
{
   KronosProfileInfo info    = GetProfileInfo(g_ActiveProfile);
   long              actual  = AccountNumber();

   if(actual != info.expectedAccount)
   {
      bool wasAlreadyMismatched = g_AccountMismatch;
      g_AccountMismatch         = true;
      g_AccountMismatchExpected = info.expectedAccount;
      g_AccountMismatchActual   = actual;

      if(!wasAlreadyMismatched)
         Print("Kronos EA: ACCOUNT MISMATCH — perfil '", info.label,
               "' espera cuenta ", info.expectedAccount,
               " pero la cuenta conectada es ", actual,
               ". No se ejecutará ninguna orden ni acción hasta resolverlo.");
      return false;
   }

   if(g_AccountMismatch)
      Print("Kronos EA: discrepancia de cuenta resuelta — perfil '", info.label,
            "' confirmado, cuenta ", actual, ".");

   g_AccountMismatch = false;
   return true;
}

//+------------------------------------------------------------------+
//| Convierte el string de config.json a ENUM_KRONOS_PROFILE. Solo    |
//| acepta los dos valores exactos soportados — cualquier otra cosa   |
//| (typo, campo vacío, mayúsculas distintas) se rechaza sin          |
//| intentar adivinar, devolviendo false.                             |
//+------------------------------------------------------------------+
bool StringToProfile(const string value, ENUM_KRONOS_PROFILE &profile)
{
   if(value == "PROD_STD")
   {
      profile = PROFILE_PROD_STD;
      return true;
   }
   if(value == "DEMO_VIP")
   {
      profile = PROFILE_DEMO_VIP;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Lee orders/config.json (si existe) y actualiza g_ActiveProfile    |
//| cuando trae una clave "profile" válida ("PROD_STD" o "DEMO_VIP"). |
//| Nunca rompe el ciclo: si el archivo no existe, no parsea, o el    |
//| valor no es uno de los dos permitidos, se deja g_ActiveProfile    |
//| como estaba (InpProfile o el último valor válido leído). El       |
//| sufijo (g_SymbolSuffix) se recalcula junto con el perfil para que |
//| nunca queden desincronizados entre sí.                            |
//+------------------------------------------------------------------+
void UpdateProfileFromConfig()
{
   string content;
   if(!ReadEntireFile(CONFIG_FILE_PATH, content))
      return; // no existe orders/config.json todavía — caso normal

   string profileStr;
   if(!JsonGetValue(content, "profile", profileStr))
      return; // JSON sin la clave esperada, se ignora

   ENUM_KRONOS_PROFILE newProfile;
   if(!StringToProfile(profileStr, newProfile))
      return; // valor no soportado, se ignora (validación estricta)

   if(newProfile != g_ActiveProfile)
   {
      KronosProfileInfo oldInfo = GetProfileInfo(g_ActiveProfile);
      KronosProfileInfo newInfo = GetProfileInfo(newProfile);
      Print("Kronos EA: perfil actualizado desde orders/config.json: ",
            oldInfo.label, " -> ", newInfo.label);
      g_ActiveProfile    = newProfile;
      g_SymbolSuffix      = newInfo.expectedSuffix;
      g_ProfileUpdatedAt = TimeGMT();
   }
}

//+------------------------------------------------------------------+
//| OnInit / OnDeinit — arranca y detiene el polling por timer       |
//| (punto de robustez 1: OnTimer, no OnTick — no depende de que     |
//| lleguen ticks de precio para revisar archivos pendientes)        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_ActiveProfile = InpProfile;
   g_SymbolSuffix  = GetProfileInfo(g_ActiveProfile).expectedSuffix;
   ValidateAccountProfile(); // no bloquea el arranque del timer: solo loguea/marca estado, OnTimer respeta el bloqueo en cada ciclo

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
   UpdateProfileFromConfig();

   // Mientras hay discrepancia de cuenta, no se toca orders/pending/ ni
   // orders/actions/ (podrían corresponder a una cuenta distinta a la
   // conectada ahora mismo) ni se corre DetectClosedPositions (leería
   // el historial de la cuenta equivocada). WritePositionsStatus() SÍ
   // sigue corriendo siempre — es lo que le avisa al dashboard del
   // bloqueo (campo "account_mismatch").
   if(!ValidateAccountProfile())
   {
      WritePositionsStatus();
      return;
   }

   ProcessPendingOrders();
   ProcessPositionActions();
   WritePositionsStatus();
   DetectClosedPositions();
}

//+------------------------------------------------------------------+
//| Detecta posiciones de este EA (InpMagicNumber) que aparecen en el|
//| historial como cerradas y todavía no fueron reportadas — escribe |
//| orders/closed/<ticket>.json con el motivo inferido (TP_REACHED / |
//| SL_REACHED / CLOSED_MANUAL) para que n8n actualice signals.status.|
//| El "ya reportado" se marca con una variable global de terminal    |
//| (persiste entre reinicios del EA, se resetea solo si se borra la  |
//| plataforma) para no reescribir el mismo archivo en cada ciclo.    |
//+------------------------------------------------------------------+
void DetectClosedPositions()
{
   int total = OrdersHistoryTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;

      if(OrderMagicNumber() != InpMagicNumber)
         continue;

      int orderType = OrderType();
      if(orderType != OP_BUY && orderType != OP_SELL)
         continue; // ignora cancelaciones de pendientes, no son cierres de mercado

      int ticket = OrderTicket();
      string gvarName = CLOSED_GVAR_PREFIX + IntegerToString(ticket);
      if(GlobalVariableCheck(gvarName))
         continue; // ya reportado en un ciclo anterior

      double closePrice = OrderClosePrice();
      double tp          = OrderTakeProfit();
      double sl           = OrderStopLoss();
      double pointTolerance = 3 * Point; // margen por slippage/spread al momento del cierre

      string reason = "CLOSED_MANUAL";
      if(tp > 0 && MathAbs(closePrice - tp) <= pointTolerance)
         reason = "TP_REACHED";
      else if(sl > 0 && MathAbs(closePrice - sl) <= pointTolerance)
         reason = "SL_REACHED";

      string signalUid = OrderComment();
      string prefix     = "KronosBot:";
      if(StringFind(signalUid, prefix) == 0)
         signalUid = StringSubstr(signalUid, StringLen(prefix));

      string json = "{\n";
      json += "  \"ticket\": " + IntegerToString(ticket) + ",\n";
      json += "  \"signal_uid\": \"" + JsonEscape(signalUid) + "\",\n";
      json += "  \"symbol\": \"" + OrderSymbol() + "\",\n";
      json += "  \"reason\": \"" + reason + "\",\n";
      json += "  \"close_price\": " + DoubleToString(closePrice, 5) + ",\n";
      json += "  \"profit\": " + DoubleToString(OrderProfit() + OrderSwap() + OrderCommission(), 2) + ",\n";
      json += "  \"close_time\": \"" + ToIso8601Utc(OrderCloseTime()) + "\"\n";
      json += "}\n";

      string closedPath = CLOSED_DIR_PREFIX + IntegerToString(ticket) + ".json";
      if(WriteEntireFile(closedPath, json))
         GlobalVariableSet(gvarName, 1);
      else
         Print("Kronos EA: ERROR al escribir ", closedPath, " — revisar permisos de Common\\Files");
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

   // STALE_SIGNAL: descarta (sin ejecutar) señales de apertura nueva
   // demasiado viejas — mismo umbral de 5 min que ya valida n8n antes
   // de confirmar (protocolo sección 4.3). Evita ejecutar en cascada,
   // a precio ya desactualizado, señales acumuladas en pending/ mientras
   // el EA estuvo bloqueado (ej. por ACCOUNT MISMATCH) o caído. Solo
   // aplica a orders/pending/ (aperturas nuevas) — NO a
   // orders/actions/ (BE/cierre sobre posiciones ya abiertas, que
   // siguen siendo válidas sin importar cuánto tiempo pasó).
   if(order.created_at > 0)
   {
      double ageMinutes = (double)(TimeGMT() - order.created_at) / 60.0;
      if(ageMinutes > InpMaxSignalAgeMinutes)
      {
         string staleMsg = StringFormat(
            "STALE_SIGNAL: created_at hace %.1f min, excede InpMaxSignalAgeMinutes=%d",
            ageMinutes, InpMaxSignalAgeMinutes);
         Print("Kronos EA: signal_id=", order.signal_id, " (", order.signal_uid,
               ") descartada sin ejecutar: ", staleMsg);
         WriteResult(order.signal_id, false, 0, 0.0, -3, staleMsg);
         FileDelete(claimedPath, FILE_COMMON);
         return;
      }
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
   json += "    \"equity\": " + DoubleToString(AccountEquity(), 2) + ",\n";
   // capital_real (decisión explícita del usuario, 2026-08-28, reemplaza la regla
   // anterior de PROTOCOLOS_KRONOS_BOT.md sección 5.2): el lotaje se calcula sobre
   // AccountBalance() completo, incluyendo crédito del bróker.
   json += "    \"capital_real\": " + DoubleToString(AccountBalance(), 2) + "\n";
   json += "  },\n";
   json += "  \"active_profile\": \"" + GetProfileInfo(g_ActiveProfile).label + "\",\n";
   if(g_ProfileUpdatedAt > 0)
      json += "  \"active_profile_updated_at\": \"" + ToIso8601Utc(g_ProfileUpdatedAt) + "\",\n";
   json += "  \"account_mismatch\": " + (g_AccountMismatch ? "true" : "false") + ",\n";
   if(g_AccountMismatch)
   {
      json += "  \"account_mismatch_expected\": " + IntegerToString(g_AccountMismatchExpected) + ",\n";
      json += "  \"account_mismatch_actual\": " + IntegerToString(g_AccountMismatchActual) + ",\n";
   }
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

   // Opcional: si falta o no se puede parsear, order.created_at queda en
   // 0 y ProcessSingleFile se salta el chequeo de antigüedad (no bloquea
   // la ejecución por esto — el contrato de campos obligatorios de
   // FORMATO_ARCHIVOS.md no incluye created_at como requerido).
   order.created_at = 0;
   string createdAtStr;
   if(JsonGetValue(json, "created_at", createdAtStr) && createdAtStr != "")
   {
      datetime parsed;
      if(ParseIso8601Utc(createdAtStr, parsed))
         order.created_at = parsed;
      else
         Print("Kronos EA: created_at con formato inesperado (\"", createdAtStr,
               "\"), se omite el chequeo de antigüedad para esta señal.");
   }

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
//| tratar "el archivo no existe todavía" como caso normal (ej. un   |
//| archivo de orders/actions/ que ya fue procesado y borrado), sin  |
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

//+------------------------------------------------------------------+
//| Inversa de ToIso8601Utc(): parsea "YYYY-MM-DDTHH:MM:SSZ" (formato |
//| que escribe n8n en "created_at") a datetime UTC. StrToTime() de   |
//| MQL4 espera "YYYY.MM.DD HH:MI:SS" (puntos, espacio, sin "Z"), así |
//| que se reescribe el string a ese formato antes de parsear.        |
//| Devuelve false si el formato no matchea lo esperado.              |
//+------------------------------------------------------------------+
bool ParseIso8601Utc(string iso, datetime &out)
{
   string s = iso;
   StringReplace(s, "-", ".");
   StringReplace(s, "T", " ");
   StringReplace(s, "Z", "");
   StringTrimRight(s);
   StringTrimLeft(s);

   if(StringLen(s) != 19) // "YYYY.MM.DD HH:MI:SS"
      return false;

   ResetLastError();
   datetime parsed = StrToTime(s);
   if(parsed <= 0 || GetLastError() != 0)
      return false;

   out = parsed;
   return true;
}
