//+------------------------------------------------------------------+
//|                                           GoldTradeManager.mq4   |
//|   Standalone trade manager: Breakeven, Trailing Stop,            |
//|   Partial Close. Works with orders opened by any EA or manually. |
//|   Broker-agnostic: adapts to Digits, StopLevel, LotStep.         |
//+------------------------------------------------------------------+
#property strict
#property description "Standalone trade manager - does NOT open trades."

//--- Trailing method
enum ENUM_TRAIL_MODE
{
   TRAIL_OFF    = 0,   // Off
   TRAIL_POINTS = 1,   // Fixed points
   TRAIL_ATR    = 2    // ATR based
};

//--- Which orders to manage
enum ENUM_FILTER_MODE
{
   FILTER_ALL   = 0,   // All orders on this symbol
   FILTER_MAGIC = 1    // Only orders with MagicFilter
};

//=== Inputs =========================================================
input string  s1              = "--- Order Filter ---";
input ENUM_FILTER_MODE FilterMode = FILTER_ALL;      // Which orders to manage
input int     MagicFilter     = 0;                   // Magic number (if FILTER_MAGIC)

input string  s2              = "--- Breakeven ---";
input bool    UseBreakeven    = true;                // Enable breakeven
input int     BE_TriggerPts   = 500;                 // Profit to trigger BE (points)
input int     BE_OffsetPts    = 50;                  // Lock-in above entry (points)

input string  s3              = "--- Trailing Stop ---";
input ENUM_TRAIL_MODE TrailMode = TRAIL_ATR;         // Trailing method
input int     Trail_StartPts  = 800;                 // Profit before trailing starts
input int     Trail_DistPts   = 600;                 // Distance (TRAIL_POINTS)
input int     Trail_StepPts   = 100;                 // Min move before update
input int     ATR_Period      = 14;                  // ATR period (TRAIL_ATR)
input double  ATR_Multiple    = 2.0;                 // ATR multiplier (TRAIL_ATR)
input ENUM_TIMEFRAMES ATR_TF  = PERIOD_CURRENT;      // ATR timeframe

input string  s4              = "--- Partial Close ---";
input bool    UsePartialClose = false;               // Enable partial close
input int     PC_TriggerPts   = 600;                 // Profit to trigger (points)
input double  PC_Percent      = 50.0;                // Percent of lot to close

input string  s5              = "--- General ---";
input int     Slippage        = 30;                  // Max slippage (points)
input int     TimerSeconds    = 1;                   // Timer interval (0 = tick only)
input bool    VerboseLog      = true;                // Print actions to log

//=== Globals ========================================================
double g_stopLevel   = 0;    // broker min distance for SL/TP (price units)
double g_freezeLevel = 0;    // broker freeze distance (price units)

//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs. A manager that runs with nonsense settings
   //--- is more dangerous than one that refuses to start.
   if(BE_TriggerPts <= BE_OffsetPts && UseBreakeven)
   {
      Print("ERROR: BE_TriggerPts must be greater than BE_OffsetPts");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(UsePartialClose && (PC_Percent <= 0 || PC_Percent >= 100))
   {
      Print("ERROR: PC_Percent must be between 0 and 100");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(TrailMode == TRAIL_ATR && ATR_Period < 1)
   {
      Print("ERROR: ATR_Period must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   RefreshBrokerLimits();

   if(TimerSeconds > 0) EventSetTimer(TimerSeconds);

   Print("=== GoldTradeManager started === ", Symbol(),
         " | Digits=", Digits,
         " | Point=", DoubleToString(Point, 8),
         " | StopLevel=", DoubleToString(g_stopLevel / Point, 0), " pts",
         " | FreezeLevel=", DoubleToString(g_freezeLevel / Point, 0), " pts");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("=== GoldTradeManager stopped === reason=", reason);
}

//+------------------------------------------------------------------+
//| Timer keeps managing when ticks stop arriving.                   |
//| Without this, trailing freezes during quiet or broken feed.      |
//+------------------------------------------------------------------+
void OnTimer() { ManageAllOrders(); }
void OnTick()  { ManageAllOrders(); }

//+------------------------------------------------------------------+
void RefreshBrokerLimits()
{
   g_stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL)   * Point;
   g_freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
}

//+------------------------------------------------------------------+
bool IsMyOrder()
{
   if(OrderSymbol() != Symbol()) return(false);
   if(OrderType() != OP_BUY && OrderType() != OP_SELL) return(false);
   if(FilterMode == FILTER_MAGIC && OrderMagicNumber() != MagicFilter) return(false);
   return(true);
}

//+------------------------------------------------------------------+
//| Profit of the selected order, in points.                         |
//+------------------------------------------------------------------+
double ProfitPoints()
{
   if(OrderType() == OP_BUY)  return((Bid - OrderOpenPrice()) / Point);
   else                       return((OrderOpenPrice() - Ask) / Point);
}

//+------------------------------------------------------------------+
//| Trailing distance in price units, per selected mode.             |
//+------------------------------------------------------------------+
double GetTrailDistance()
{
   if(TrailMode == TRAIL_POINTS) return(Trail_DistPts * Point);

   if(TrailMode == TRAIL_ATR)
   {
      double atr = iATR(Symbol(), ATR_TF, ATR_Period, 1);
      if(atr <= 0) return(0);          // bad data -> do nothing
      return(atr * ATR_Multiple);
   }
   return(0);
}

//+------------------------------------------------------------------+
//| Clamp a proposed SL so the broker will accept it.                |
//| Returns false if no legal price exists right now.                |
//+------------------------------------------------------------------+
bool ClampStopLoss(double &sl)
{
   if(OrderType() == OP_BUY)
   {
      double maxAllowed = Bid - g_stopLevel;
      if(sl > maxAllowed) sl = maxAllowed;
      if(sl <= 0) return(false);
   }
   else
   {
      double minAllowed = Ask + g_stopLevel;
      if(sl < minAllowed) sl = minAllowed;
   }
   sl = NormalizeDouble(sl, Digits);
   return(true);
}

//+------------------------------------------------------------------+
//| True if the new SL is genuinely better than the current one.     |
//| Guards against error 1 (modify with identical values) and        |
//| against ever moving a stop further from price.                   |
//+------------------------------------------------------------------+
bool IsBetterStop(double newSL, double minImprovePts)
{
   double cur     = OrderStopLoss();
   double improve = minImprovePts * Point;

   if(OrderType() == OP_BUY)
   {
      if(cur <= 0) return(newSL < Bid - g_stopLevel);
      return(newSL > cur + improve);
   }
   else
   {
      if(cur <= 0) return(newSL > Ask + g_stopLevel);
      return(newSL < cur - improve);
   }
}

//+------------------------------------------------------------------+
//| Modify SL with retry. Transient errors are normal, not bugs.     |
//+------------------------------------------------------------------+
bool ModifyStopLoss(double newSL, string reason)
{
   int ticket = OrderTicket();

   //--- Freeze level: broker forbids modifying orders too close to price
   double dist = MathAbs((OrderType() == OP_BUY ? Bid : Ask) - newSL);
   if(g_freezeLevel > 0 && dist < g_freezeLevel)
   {
      if(VerboseLog)
         Print("SKIP #", ticket, " | ", reason, " | inside freeze level");
      return(false);
   }

   for(int attempt = 1; attempt <= 3; attempt++)
   {
      if(OrderModify(ticket, OrderOpenPrice(), newSL,
                     OrderTakeProfit(), 0, clrNONE))
      {
         if(VerboseLog)
            Print("OK #", ticket, " | ", reason,
                  " | SL -> ", DoubleToString(newSL, Digits));
         return(true);
      }

      int err = GetLastError();

      //--- Nothing changed: not a failure, stop retrying
      if(err == 1) return(false);

      //--- Transient: refresh prices and try again
      if(err == 128 || err == 129 || err == 135 || err == 136 || err == 138)
      {
         Sleep(200);
         RefreshRates();
         RefreshBrokerLimits();
         if(!ClampStopLoss(newSL)) return(false);
         continue;
      }

      Print("FAIL #", ticket, " | ", reason, " | error=", err,
            " | SL=", DoubleToString(newSL, Digits));
      return(false);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Breakeven: move SL to entry + offset once profit passes trigger. |
//+------------------------------------------------------------------+
void ApplyBreakeven()
{
   if(!UseBreakeven) return;
   if(ProfitPoints() < BE_TriggerPts) return;

   double target;
   if(OrderType() == OP_BUY) target = OrderOpenPrice() + BE_OffsetPts * Point;
   else                      target = OrderOpenPrice() - BE_OffsetPts * Point;

   if(!IsBetterStop(target, 0)) return;   // already at or past BE
   if(!ClampStopLoss(target))   return;
   if(!IsBetterStop(target, 0)) return;   // clamping may have killed the gain

   ModifyStopLoss(target, "BREAKEVEN");
}

//+------------------------------------------------------------------+
//| Trailing stop: SL follows price at a fixed or ATR distance.      |
//+------------------------------------------------------------------+
void ApplyTrailing()
{
   if(TrailMode == TRAIL_OFF) return;
   if(ProfitPoints() < Trail_StartPts) return;

   double dist = GetTrailDistance();
   if(dist <= 0) return;

   double target;
   if(OrderType() == OP_BUY) target = Bid - dist;
   else                      target = Ask + dist;

   //--- Trail_StepPts stops us spamming the server with tiny updates
   if(!IsBetterStop(target, Trail_StepPts)) return;
   if(!ClampStopLoss(target))               return;
   if(!IsBetterStop(target, Trail_StepPts)) return;

   ModifyStopLoss(target, "TRAILING");
}

//+------------------------------------------------------------------+
//| Partial close.                                                   |
//|                                                                  |
//| STATE NOTE: MT4 gives the remainder a NEW ticket, so a ticket    |
//| list cannot track "already partially closed". We instead use the |
//| stop loss as the flag: partial close is only allowed while SL is |
//| still worse than entry, and we move SL to entry immediately      |
//| after. The remainder therefore never qualifies twice.            |
//| Consequence: with UsePartialClose = true, PC_TriggerPts should   |
//| be <= BE_TriggerPts, or breakeven will disarm it first.          |
//+------------------------------------------------------------------+
void ApplyPartialClose()
{
   if(!UsePartialClose) return;
   if(ProfitPoints() < PC_TriggerPts) return;

   //--- Already at or beyond entry -> partial was done (or BE fired)
   double cur = OrderStopLoss();
   if(OrderType() == OP_BUY  && cur > 0 && cur >= OrderOpenPrice()) return;
   if(OrderType() == OP_SELL && cur > 0 && cur <= OrderOpenPrice()) return;

   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   double closeLot = OrderLots() * PC_Percent / 100.0;
   closeLot = MathFloor(closeLot / lotStep) * lotStep;
   closeLot = NormalizeDouble(closeLot, 2);

   double remainder = NormalizeDouble(OrderLots() - closeLot, 2);

   //--- Both parts must be tradable, or the broker rejects the order
   if(closeLot < minLot || remainder < minLot)
   {
      if(VerboseLog)
         Print("SKIP #", OrderTicket(), " | PARTIAL | lot too small (close=",
               DoubleToString(closeLot, 2), " remain=",
               DoubleToString(remainder, 2), " min=",
               DoubleToString(minLot, 2), ")");
      return;
   }

   int    ticket = OrderTicket();
   double price  = (OrderType() == OP_BUY) ? Bid : Ask;

   if(OrderClose(ticket, closeLot, NormalizeDouble(price, Digits),
                 Slippage, clrNONE))
   {
      Print("OK #", ticket, " | PARTIAL | closed ",
            DoubleToString(closeLot, 2), " of ",
            DoubleToString(closeLot + remainder, 2), " lots");
   }
   else
   {
      Print("FAIL #", ticket, " | PARTIAL | error=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Main loop.                                                       |
//| Counts DOWN because closing an order re-indexes the pool.        |
//+------------------------------------------------------------------+
void ManageAllOrders()
{
   RefreshBrokerLimits();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsMyOrder()) continue;

      //--- Order matters: partial close first (it needs SL below entry),
      //--- then breakeven, then trailing.
      ApplyPartialClose();

      //--- Re-select: a partial close invalidates the current selection
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsMyOrder()) continue;

      ApplyBreakeven();
      ApplyTrailing();
   }
}
//+------------------------------------------------------------------+