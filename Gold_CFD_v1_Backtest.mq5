//+------------------------------------------------------------------+
//|                                    Gold_CFD_v1_Backtest.mq5     |
//|                       Gold CFD Lab — Phase 1 Character Study     |
//|                    Backtest only — no WebRequest, no Supabase    |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Inputs
input int    MagicNumber       = 2001;   // EA magic number
input int    MovingPeriod      = 12;     // SMA period
input int    MovingShift       = 6;      // SMA shift
input double SLMultiplier      = 1.5;    // SL = ATR(14) * SLMultiplier
input double RRRatio           = 1.9;    // TP = SL * RRRatio
input double ATRMinimumPoints  = 50.0;   // Minimum ATR gate (in _Point units)
input int    SessionStartHour  = 7;      // Session open hour (server time)
input int    SessionEndHour    = 20;     // Session close hour (server time)
input double MaximumRisk       = 0.01;   // Risk fraction per trade (1%)

//--- Indicator handles
int ExtHandle  = INVALID_HANDLE;   // SMA handle
int atrHandle  = INVALID_HANDLE;   // ATR(14) handle
int atr5Handle = INVALID_HANDLE;   // ATR(5)  handle
int adxHandle  = INVALID_HANDLE;   // ADX(14) handle

//--- Trade object
CTrade ExtTrade;

//--- Persistent trade state (captured at entry, used at exit)
string   g_direction             = "";
double   g_entry_price           = 0;
double   g_sl_price              = 0;
double   g_tp_price              = 0;
double   g_lot_size              = 0;
double   g_risk_amount           = 0;
datetime g_entry_time            = 0;
double   g_ma_value              = 0;
double   g_atr14                 = 0;
double   g_atr5                  = 0;
double   g_atr_ratio             = 0;
double   g_adx14                 = 0;
double   g_di_plus               = 0;
double   g_di_minus              = 0;
int      g_session_hour          = 0;
int      g_day_of_week           = 0;
double   g_candle_body_pct       = 0;
double   g_price_ma_dist_pips    = 0;
double   g_prev_candle_range_pct = 0;
double   g_mfe_pips              = 0;
double   g_mae_pips              = 0;
bool     g_position_was_open     = false;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double PipSize()
{
   return (_Digits == 5 || _Digits == 3) ? _Point * 10 : _Point;
}

string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:         return "UNK";
   }
}

//+------------------------------------------------------------------+
//| Reset all trade state globals                                    |
//+------------------------------------------------------------------+
void ResetTradeState()
{
   g_direction             = "";
   g_entry_price           = 0;
   g_sl_price              = 0;
   g_tp_price              = 0;
   g_lot_size              = 0;
   g_risk_amount           = 0;
   g_entry_time            = 0;
   g_ma_value              = 0;
   g_atr14                 = 0;
   g_atr5                  = 0;
   g_atr_ratio             = 0;
   g_adx14                 = 0;
   g_di_plus               = 0;
   g_di_minus              = 0;
   g_session_hour          = 0;
   g_day_of_week           = 0;
   g_candle_body_pct       = 0;
   g_price_ma_dist_pips    = 0;
   g_prev_candle_range_pct = 0;
   g_mfe_pips              = 0;
   g_mae_pips              = 0;
   g_position_was_open     = false;
}

//+------------------------------------------------------------------+
//| Snapshot indicators and context at entry                         |
//+------------------------------------------------------------------+
void CaptureEntryContext(ENUM_ORDER_TYPE signal, double price,
                         double sl, double tp, double lot)
{
   g_direction   = (signal == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   g_entry_price = price;
   g_sl_price    = sl;
   g_tp_price    = tp;
   g_lot_size    = lot;
   g_entry_time  = TimeCurrent();

   //--- Risk amount: tick-value-aware for any instrument
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double sl_dist   = MathAbs(price - sl);
   g_risk_amount    = (tick_size > 0) ? (sl_dist / tick_size) * tick_val * lot : 0;

   //--- Indicators
   double ma_buf[1], atr14_buf[1], atr5_buf[1], adx_buf[1], dp_buf[1], dm_buf[1];
   if(CopyBuffer(ExtHandle,  0, 0, 1, ma_buf)    == 1) g_ma_value = ma_buf[0];
   if(CopyBuffer(atrHandle,  0, 0, 1, atr14_buf) == 1) g_atr14   = atr14_buf[0];
   if(CopyBuffer(atr5Handle, 0, 0, 1, atr5_buf)  == 1) g_atr5    = atr5_buf[0];
   if(CopyBuffer(adxHandle,  0, 0, 1, adx_buf)   == 1) g_adx14   = adx_buf[0];
   if(CopyBuffer(adxHandle,  1, 0, 1, dp_buf)    == 1) g_di_plus  = dp_buf[0];
   if(CopyBuffer(adxHandle,  2, 0, 1, dm_buf)    == 1) g_di_minus = dm_buf[0];
   g_atr_ratio = (g_atr14 > 0) ? g_atr5 / g_atr14 : 0;

   //--- Datetime context
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_session_hour = dt.hour;
   g_day_of_week  = dt.day_of_week;

   //--- Candle metrics (rt[0] = signal candle, rt[1] = current forming bar)
   MqlRates rt[2];
   if(CopyRates(_Symbol, _Period, 0, 2, rt) == 2)
   {
      double body  = MathAbs(rt[0].close - rt[0].open);
      double range = rt[0].high - rt[0].low;
      g_candle_body_pct = (range > 0) ? (body / range) * 100.0 : 0;

      double pip = PipSize();
      g_price_ma_dist_pips = (pip > 0) ? MathAbs(price - g_ma_value) / pip : 0;
      g_prev_candle_range_pct = (g_atr14 > 0) ? (range / g_atr14) * 100.0 : 0;
   }

   g_mfe_pips = 0;
   g_mae_pips = 0;
}

//+------------------------------------------------------------------+
//| Track maximum favourable / adverse excursion (in pip units)      |
//+------------------------------------------------------------------+
void UpdateMFEMAE()
{
   if(g_entry_price == 0) return;

   double pip = PipSize();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double pnl_pips;
   if(g_direction == "BUY")
      pnl_pips = (bid - g_entry_price) / pip;
   else
      pnl_pips = (g_entry_price - ask) / pip;

   if(pnl_pips > g_mfe_pips) g_mfe_pips = pnl_pips;
   if(-pnl_pips > g_mae_pips) g_mae_pips = -pnl_pips;
   if(g_mae_pips < 0) g_mae_pips = 0;
}

//+------------------------------------------------------------------+
//| Log closed trade to CSV (source = BACKTEST)                      |
//+------------------------------------------------------------------+
void LogTradeToCSV(ulong deal_ticket)
{
   double   exit_price = HistoryDealGetDouble(deal_ticket,  DEAL_PRICE);
   datetime exit_time  = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

   double pip = PipSize();
   double sl_dist_pips    = MathAbs(g_sl_price    - g_entry_price) / pip;
   double tp_dist_pips    = MathAbs(g_tp_price    - g_entry_price) / pip;
   double price_move_pips = (g_direction == "BUY")
                            ? (exit_price - g_entry_price) / pip
                            : (g_entry_price - exit_price) / pip;

   double r_multiple = (sl_dist_pips > 0) ? price_move_pips / sl_dist_pips : 0;
   double rr_target  = (sl_dist_pips > 0) ? tp_dist_pips / sl_dist_pips    : RRRatio;
   double mfe_pct_tp = (tp_dist_pips > 0) ? (g_mfe_pips / tp_dist_pips) * 100.0 : 0;
   double mae_pct_sl = (sl_dist_pips > 0) ? (g_mae_pips / sl_dist_pips) * 100.0 : 0;
   double duration_h = (double)(exit_time - g_entry_time) / 3600.0;

   string result_str;
   if     (r_multiple >  0.05) result_str = "WIN";
   else if(r_multiple < -0.05) result_str = "LOSS";
   else                         result_str = "BE";

   string close_reason;
   switch(reason)
   {
      case DEAL_REASON_TP:     close_reason = "TP";       break;
      case DEAL_REASON_SL:     close_reason = "SL";       break;
      case DEAL_REASON_EXPERT: close_reason = "EA_CLOSE"; break;
      case DEAL_REASON_CLIENT: close_reason = "MANUAL";   break;
      default:                 close_reason = "OTHER";    break;
   }

   //--- Open CSV in common files folder
   string csv_file = "gold_cfd_log_" + _Symbol + "_" + TimeframeToString(_Period) + ".csv";
   int fh = FileOpen(csv_file, FILE_READ | FILE_WRITE | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      fh = FileOpen(csv_file, FILE_WRITE | FILE_ANSI | FILE_COMMON);
      if(fh == INVALID_HANDLE)
      {
         Print("LogTradeToCSV: FileOpen failed, error=", GetLastError());
         return;
      }
   }

   FileSeek(fh, 0, SEEK_END);
   long file_size = FileTell(fh);

   //--- Write header if file is empty
   if(file_size == 0)
   {
      FileWriteString(fh,
                      "trade_id,symbol,timeframe,direction,"
                      "entry_time,exit_time,duration_hours,"
                      "entry_price,sl_price,tp_price,exit_price,"
                      "lot_size,risk_amount,rr_target,r_multiple,"
                      "result,close_reason,"
                      "mfe_pips,mae_pips,mfe_pct_tp,mae_pct_sl,"
                      "ma_value,atr14,atr5,atr_ratio,"
                      "adx14,di_plus,di_minus,"
                      "session_hour,day_of_week,"
                      "candle_body_pct,price_ma_distance_pips,prev_candle_range_pct,"
                      "source\n");
   }

   //--- Build and write data row
   string row = StringFormat(
                   "%I64u,%s,%s,%s,"
                   "%s,%s,%.4f,"
                   "%s,%s,%s,%s,"
                   "%.2f,%.2f,%.4f,%.4f,"
                   "%s,%s,"
                   "%.2f,%.2f,%.2f,%.2f,"
                   "%s,%.5f,%.5f,%.4f,"
                   "%.2f,%.2f,%.2f,"
                   "%d,%d,"
                   "%.2f,%.2f,%.2f,"
                   "%s\n",
                   deal_ticket,
                   _Symbol,
                   TimeframeToString(_Period),
                   g_direction,
                   TimeToString(g_entry_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                   TimeToString(exit_time,    TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                   duration_h,
                   DoubleToString(g_entry_price, _Digits),
                   DoubleToString(g_sl_price,    _Digits),
                   DoubleToString(g_tp_price,    _Digits),
                   DoubleToString(exit_price,    _Digits),
                   g_lot_size,
                   g_risk_amount,
                   rr_target,
                   r_multiple,
                   result_str,
                   close_reason,
                   g_mfe_pips, g_mae_pips, mfe_pct_tp, mae_pct_sl,
                   DoubleToString(g_ma_value, _Digits),
                   g_atr14, g_atr5, g_atr_ratio,
                   g_adx14, g_di_plus, g_di_minus,
                   g_session_hour, g_day_of_week,
                   g_candle_body_pct, g_price_ma_dist_pips, g_prev_candle_range_pct,
                   "BACKTEST"
                );

   FileWriteString(fh, row);
   FileClose(fh);

   Print("Trade logged | ticket:", deal_ticket,
         " | ", g_direction,
         " | result:", result_str,
         " | R:", DoubleToString(r_multiple, 2),
         " | exit:", DoubleToString(exit_price, _Digits));
}

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   ExtHandle  = iMA(_Symbol, _Period, MovingPeriod, MovingShift, MODE_SMA, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, _Period, 14);
   atr5Handle = iATR(_Symbol, _Period, 5);
   adxHandle  = iADX(_Symbol, _Period, 14);

   if(ExtHandle  == INVALID_HANDLE ||
      atrHandle  == INVALID_HANDLE ||
      atr5Handle == INVALID_HANDLE ||
      adxHandle  == INVALID_HANDLE)
   {
      Print("Indicator initialization failed");
      return INIT_FAILED;
   }

   ChartIndicatorAdd(0, 0, ExtHandle);
   ExtTrade.SetExpertMagicNumber(MagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(ExtHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(atr5Handle);
   IndicatorRelease(adxHandle);
}

//+------------------------------------------------------------------+
//| Session filter: Tue/Wed/Thu AND within SessionStartHour-EndHour  |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week < 2 || dt.day_of_week > 4) return false;
   if(dt.hour < SessionStartHour || dt.hour >= SessionEndHour) return false;
   return true;
}

//+------------------------------------------------------------------+
//| ATR gate: reject low-volatility environments                     |
//+------------------------------------------------------------------+
bool IsATRValid()
{
   double atr[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) != 1) return false;
   return (atr[0] / _Point >= ATRMinimumPoints);
}

//+------------------------------------------------------------------+
//| Lot sizing: point-value aware, works for gold and indices        |
//+------------------------------------------------------------------+
double CalculateLot(double sl_price_dist)
{
   if(sl_price_dist <= 0) return 0;

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * MaximumRisk;

   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_val <= 0 || tick_size <= 0) return 0;

   //--- $ risk per lot for this SL distance
   double risk_per_lot = (sl_price_dist / tick_size) * tick_val;
   if(risk_per_lot <= 0) return 0;

   double raw_lot = risk_amount / risk_per_lot;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minvol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxvol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   raw_lot = step * MathFloor(raw_lot / step);
   return NormalizeDouble(MathMax(minvol, MathMin(raw_lot, maxvol)), 2);
}

//+------------------------------------------------------------------+
//| Check for entry signal on bar open                               |
//+------------------------------------------------------------------+
void CheckForOpen()
{
   if(!IsWithinSession() || !IsATRValid()) return;

   //--- Only act on the first tick of a new bar
   MqlRates rt[2];
   if(CopyRates(_Symbol, _Period, 0, 2, rt) != 2 || rt[1].tick_volume > 1) return;

   double ma[1];
   if(CopyBuffer(ExtHandle, 0, 0, 1, ma) != 1) return;

   //--- SMA(12, shift 6) crossover: candle opens one side, closes other side
   bool isBuy  = rt[0].open < ma[0] && rt[0].close > ma[0];
   bool isSell = rt[0].open > ma[0] && rt[0].close < ma[0];

   ENUM_ORDER_TYPE signal = isBuy  ? ORDER_TYPE_BUY
                          : isSell ? ORDER_TYPE_SELL
                          : (ENUM_ORDER_TYPE)-1;
   if(signal == (ENUM_ORDER_TYPE)-1) return;

   //--- ATR-based SL/TP
   double atr14_buf[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr14_buf) != 1) return;

   double sl_dist = atr14_buf[0] * SLMultiplier;
   double tp_dist = sl_dist * RRRatio;

   double price = SymbolInfoDouble(_Symbol,
                    signal == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
   double sl = NormalizeDouble(
                 (signal == ORDER_TYPE_BUY) ? price - sl_dist : price + sl_dist, _Digits);
   double tp = NormalizeDouble(
                 (signal == ORDER_TYPE_BUY) ? price + tp_dist : price - tp_dist, _Digits);

   double lot = CalculateLot(sl_dist);
   if(lot <= 0) return;

   if(ExtTrade.PositionOpen(_Symbol, signal, lot, price, sl, tp, ""))
      CaptureEntryContext(signal, price, sl, tp, lot);
}

//+------------------------------------------------------------------+
//| Scan history for most recent OUT deal on this symbol/magic       |
//+------------------------------------------------------------------+
ulong FindLastCloseDeal()
{
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_INOUT) continue;
      return ticket;
   }
   return 0;
}

//+------------------------------------------------------------------+
void OnTick()
{
   bool position_open = PositionSelect(_Symbol) &&
                        (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber;

   //--- Detect open→closed transition (OnTick fallback for close detection)
   if(g_position_was_open && !position_open && g_entry_price != 0)
   {
      ulong deal_ticket = FindLastCloseDeal();
      if(deal_ticket > 0)
      {
         LogTradeToCSV(deal_ticket);
         ResetTradeState();
      }
   }

   g_position_was_open = position_open;

   if(position_open)
      UpdateMFEMAE();
   else
      CheckForOpen();
}

//+------------------------------------------------------------------+
//| Fires on every deal — primary close detection path               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type   != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol)                    return;

   HistorySelect(0, TimeCurrent());
   if(!HistoryDealSelect(trans.deal)) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;

   ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_INOUT) return;

   //--- Guard: if already logged by OnTick fallback, skip
   if(g_entry_price == 0) return;

   LogTradeToCSV(trans.deal);
   ResetTradeState();
}
//+------------------------------------------------------------------+
