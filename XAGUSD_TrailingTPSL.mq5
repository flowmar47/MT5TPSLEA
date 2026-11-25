//+------------------------------------------------------------------+
//|                                         XAGUSD_TrailingTPSL.mq5  |
//|                        Trailing TP/SL EA for Manual XAGUSD Trades|
//|                                                                  |
//| Automatically applies and trails Take Profit and Stop Loss       |
//| on manually entered XAGUSD positions based on trend strength     |
//+------------------------------------------------------------------+
#property copyright "2024-2026 flowmar47"
#property link      "https://github.com/flowmar47/MT5TPSLEA"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== General Settings ==="
input string   InpSymbol              = "";           // Symbol to monitor (empty = current chart symbol)
input int      InpMagicNumber         = 0;            // Magic number (0 = all manual trades)
input int      InpCheckIntervalMs     = 500;          // Check interval in milliseconds
input double   InpPipSizeOverride     = 0.0;          // Pip size override (0 = auto-detect)
input double   InpMaxSpreadPips       = 0.0;          // Max spread filter in pips (0 = disabled)
input bool     InpShowDashboard       = true;         // Show chart dashboard
input bool     InpPersistState        = true;         // Persist BE/TP state across restarts

input group "=== Initial SL/TP Settings ==="
input bool     InpApplyInitialSLTP    = true;         // Apply initial SL/TP if not set
input double   InpInitialSLPips       = 50.0;         // Initial Stop Loss (in pips)
input double   InpInitialTPPips       = 100.0;        // Initial Take Profit (in pips)

input group "=== Trailing Stop Loss Settings ==="
input bool     InpEnableTrailingSL    = true;         // Enable Trailing Stop Loss
input double   InpTrailingSLStart     = 20.0;         // Start trailing after X pips profit
input double   InpTrailingSLDistance  = 15.0;         // Trailing SL distance (pips)
input double   InpTrailingSLStep      = 5.0;          // Minimum SL move step (pips)
input bool     InpUseATRForSL         = true;         // Use ATR for dynamic SL distance

input group "=== Trailing Take Profit Settings ==="
input bool     InpEnableTrailingTP    = true;         // Enable Trailing Take Profit
input double   InpTPExtendThreshold   = 30.0;         // Extend TP after X pips in profit
input double   InpTPExtendAmount      = 20.0;         // Amount to extend TP (pips)
input int      InpMaxTPExtensions     = 5;            // Maximum TP extensions allowed
input bool     InpUseATRForTP         = true;         // Use ATR for dynamic TP extension

input group "=== Trend Detection Settings (ADX) ==="
input bool     InpUseTrendFilter      = true;         // Only trail in strong trends
input int      InpADXPeriod           = 14;           // ADX Period
input double   InpADXThreshold        = 25.0;         // ADX threshold for strong trend
input double   InpStrongTrendADX      = 35.0;         // ADX for very strong trend (aggressive trailing)

input group "=== ATR Settings ==="
input int      InpATRPeriod           = 14;           // ATR Period
input double   InpATRMultiplierSL     = 1.5;          // ATR Multiplier for SL
input double   InpATRMultiplierTP     = 2.5;          // ATR Multiplier for TP

input group "=== Risk Management ==="
input double   InpBreakEvenPips       = 30.0;         // Move SL to breakeven after X pips
input double   InpBreakEvenOffset     = 2.0;          // Breakeven offset (pips in profit)
input bool     InpEnableBreakEven     = true;         // Enable breakeven feature

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;

int            adxHandle = INVALID_HANDLE;
int            atrHandle = INVALID_HANDLE;
double         adxBuffer[];
double         plusDIBuffer[];
double         minusDIBuffer[];
double         atrBuffer[];

struct PositionData
{
   ulong    ticket;
   double   entryPrice;
   double   initialTP;
   double   lastExtendedTP;
   int      tpExtensions;
   bool     breakEvenSet;
   datetime openTime;
};

PositionData   trackedPositions[];
string         workSymbol;
double         pipSize;
int            digits;

//+------------------------------------------------------------------+
//| Global variable key helpers for restart persistence               |
//+------------------------------------------------------------------+
string GetBEGlobalVarName(ulong ticket)
{
   return "TTPSL_BE_" + IntegerToString(ticket);
}

string GetExtGlobalVarName(ulong ticket)
{
   return "TTPSL_EXT_" + IntegerToString(ticket);
}

//+------------------------------------------------------------------+
//| Price and stop-distance helpers                                   |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   if(price <= 0.0)
      return 0.0;

   double tickSize = SymbolInfoDouble(workSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      price = MathRound(price / tickSize) * tickSize;

   return NormalizeDouble(price, digits);
}

double GetMinStopDistance()
{
   long stopsLevel  = SymbolInfoInteger(workSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(workSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double point     = SymbolInfoDouble(workSymbol, SYMBOL_POINT);
   return (double)MathMax(stopsLevel, freezeLevel) * point;
}

bool IsModifyRetcodeSuccess(uint retcode)
{
   return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL);
}

bool IsModifySafe(ENUM_POSITION_TYPE posType, double bid, double ask,
                  double currentSL, double currentTP, double newSL, double newTP)
{
   if(bid <= 0.0 || ask <= 0.0)
      return false;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("Modify blocked: Terminal trading is disabled");
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("Modify blocked: EA automated trading is disabled");
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("Modify blocked: Account trading is disabled");
      return false;
   }
   if(SymbolInfoInteger(workSymbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Modify blocked: Trading disabled for symbol ", workSymbol);
      return false;
   }

   if(InpMaxSpreadPips > 0.0)
   {
      double spreadPips = (ask - bid) / pipSize;
      if(spreadPips > InpMaxSpreadPips)
      {
         return false;
      }
   }

   double point      = SymbolInfoDouble(workSymbol, SYMBOL_POINT);
   long freezeLevel  = SymbolInfoInteger(workSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double freezeDist = (double)freezeLevel * point;
   double refPrice   = (posType == POSITION_TYPE_BUY) ? bid : ask;

   if(freezeDist > 0.0)
   {
      if(currentSL > 0.0 && MathAbs(refPrice - currentSL) <= freezeDist)
         return false;
      if(currentTP > 0.0 && MathAbs(refPrice - currentTP) <= freezeDist)
         return false;
   }

   double minStopDist = GetMinStopDistance();
   double eps         = point * 0.01;

   if(posType == POSITION_TYPE_BUY)
   {
      if(newSL > 0.0 && (newSL >= bid || (bid - newSL) + eps < minStopDist))
         return false;
      if(newTP > 0.0 && (newTP <= bid || (newTP - bid) + eps < minStopDist))
         return false;
   }
   else
   {
      if(newSL > 0.0 && (newSL <= ask || (newSL - ask) + eps < minStopDist))
         return false;
      if(newTP > 0.0 && (newTP >= ask || (ask - newTP) + eps < minStopDist))
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate input parameters
   if(InpCheckIntervalMs < 100)
   {
      Print("Error: InpCheckIntervalMs must be >= 100 ms");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpADXPeriod < 2)
   {
      Print("Error: InpADXPeriod must be >= 2");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpATRPeriod < 2)
   {
      Print("Error: InpATRPeriod must be >= 2");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpInitialSLPips < 0.0 || InpInitialTPPips < 0.0 ||
      InpTrailingSLStart < 0.0 || InpTrailingSLDistance < 0.0 || InpTrailingSLStep < 0.0 ||
      InpTPExtendThreshold < 0.0 || InpTPExtendAmount < 0.0 ||
      InpATRMultiplierSL < 0.0 || InpATRMultiplierTP < 0.0 ||
      InpBreakEvenPips < 0.0 || InpBreakEvenOffset < 0.0 ||
      InpPipSizeOverride < 0.0 || InpMaxSpreadPips < 0.0)
   {
      Print("Error: Pip, multiplier, spread, and override inputs must be non-negative");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpADXThreshold < 0.0 || InpStrongTrendADX < InpADXThreshold)
   {
      Print("Error: InpADXThreshold must be >= 0 and InpStrongTrendADX >= InpADXThreshold");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxTPExtensions < 0)
   {
      Print("Error: InpMaxTPExtensions must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Resolve working symbol (supports broker suffixes automatically when InpSymbol == "")
   string trimmedSymbol = InpSymbol;
   StringTrimLeft(trimmedSymbol);
   StringTrimRight(trimmedSymbol);
   workSymbol = (trimmedSymbol == "") ? _Symbol : trimmedSymbol;

   // Validate symbol
   if(!SymbolSelect(workSymbol, true))
   {
      Print("Error: Symbol ", workSymbol, " not found!");
      return INIT_FAILED;
   }

   // Get symbol properties
   digits = (int)SymbolInfoInteger(workSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(workSymbol, SYMBOL_POINT);

   // Calculate pip size (override or auto-detect from digits/point)
   if(InpPipSizeOverride > 0.0)
   {
      pipSize = InpPipSizeOverride;
   }
   else
   {
      if(digits == 3 || digits == 2)
         pipSize = 0.01;
      else if(digits == 5 || digits == 4)
         pipSize = 0.0001;
      else
         pipSize = point * 10.0;
   }

   if(pipSize <= 0.0 || point <= 0.0)
   {
      Print("Error: Invalid pip size (", pipSize, ") or point (", point, ") for ", workSymbol);
      return INIT_PARAMETERS_INCORRECT;
   }

   Print("Initialized for ", workSymbol, " | Digits: ", digits, " | Pip Size: ", pipSize);

   // Initialize indicators
   adxHandle = iADX(workSymbol, PERIOD_CURRENT, InpADXPeriod);
   atrHandle = iATR(workSymbol, PERIOD_CURRENT, InpATRPeriod);

   if(adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Error creating indicators for ", workSymbol, " | Error: ", GetLastError());
      if(adxHandle != INVALID_HANDLE)
      {
         IndicatorRelease(adxHandle);
         adxHandle = INVALID_HANDLE;
      }
      if(atrHandle != INVALID_HANDLE)
      {
         IndicatorRelease(atrHandle);
         atrHandle = INVALID_HANDLE;
      }
      return INIT_FAILED;
   }

   // Set up arrays
   ArraySetAsSeries(adxBuffer, true);
   ArraySetAsSeries(plusDIBuffer, true);
   ArraySetAsSeries(minusDIBuffer, true);
   ArraySetAsSeries(atrBuffer, true);

   // Set up trade object with auto-detected broker filling mode
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

   long fillingMode = SymbolInfoInteger(workSymbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   if(!InpShowDashboard)
      ObjectsDeleteAll(0, "TTPSL_");

   // Set timer for regular checks
   EventSetMillisecondTimer(InpCheckIntervalMs);

   Print("==============================================");
   Print("XAGUSD Trailing TP/SL EA v2.00 Initialized");
   Print("Monitoring symbol: ", workSymbol);
   Print("Trailing SL: ", InpEnableTrailingSL ? "Enabled" : "Disabled");
   Print("Trailing TP: ", InpEnableTrailingTP ? "Enabled" : "Disabled");
   Print("Trend Filter: ", InpUseTrendFilter ? "Enabled" : "Disabled");
   Print("State Persistence: ", InpPersistState ? "Enabled" : "Disabled");
   Print("==============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(adxHandle != INVALID_HANDLE)
   {
      IndicatorRelease(adxHandle);
      adxHandle = INVALID_HANDLE;
   }
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }

   ObjectsDeleteAll(0, "TTPSL_");

   Print("XAGUSD Trailing TP/SL EA v2.00 Deinitialized");
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessPositions();
}

//+------------------------------------------------------------------+
//| Tick function                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   ProcessPositions();
}

//+------------------------------------------------------------------+
//| Main position processing function                                 |
//+------------------------------------------------------------------+
void ProcessPositions()
{
   // Update indicator values
   if(!UpdateIndicators())
      return;

   // Loop through all positions
   int totalPositions = PositionsTotal();

   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // Check if position is for our symbol
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(symbol != workSymbol) continue;

      // Check magic number (0 = all manual trades)
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(InpMagicNumber != 0 && magic != InpMagicNumber) continue;

      // Process this position
      ProcessSinglePosition(ticket);
   }

   // Clean up tracked positions that no longer exist
   CleanupTrackedPositions();

   // Update chart dashboard
   if(InpShowDashboard)
      DisplayDashboard();
}

//+------------------------------------------------------------------+
//| Process a single position                                         |
//+------------------------------------------------------------------+
void ProcessSinglePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

   double bid = SymbolInfoDouble(workSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(workSymbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;

   // Calculate profit in pips
   double profitPips = 0.0;
   if(posType == POSITION_TYPE_BUY)
      profitPips = (currentPrice - entryPrice) / pipSize;
   else
      profitPips = (entryPrice - currentPrice) / pipSize;

   // Get or create position tracking data
   int trackIndex = GetPositionTrackIndex(ticket);
   if(trackIndex == -1)
   {
      trackIndex = AddTrackedPosition(ticket, entryPrice, currentTP, openTime);
   }

   // Get trend information
   double adxValue = adxBuffer[0];
   double plusDI = plusDIBuffer[0];
   double minusDI = minusDIBuffer[0];
   double atrValue = atrBuffer[0];

   bool isStrongTrend = adxValue >= InpADXThreshold;
   bool isVeryStrongTrend = adxValue >= InpStrongTrendADX;
   bool trendMatchesPosition = (posType == POSITION_TYPE_BUY && plusDI > minusDI) ||
                               (posType == POSITION_TYPE_SELL && minusDI > plusDI);

   // Apply initial SL/TP if not set
   if(InpApplyInitialSLTP)
   {
      ApplyInitialSLTP(ticket, posType, entryPrice, currentSL, currentTP, atrValue, bid, ask);
   }

   // Refresh position data after potential modification
   if(!PositionSelectByTicket(ticket))
      return;
   currentSL = PositionGetDouble(POSITION_SL);
   currentTP = PositionGetDouble(POSITION_TP);

   if(trackedPositions[trackIndex].initialTP == 0.0 && currentTP > 0.0)
   {
      trackedPositions[trackIndex].initialTP = currentTP;
      trackedPositions[trackIndex].lastExtendedTP = currentTP;
   }

   // Break-even logic (only mark breakEvenSet when ApplyBreakEven confirms success)
   if(InpEnableBreakEven && !trackedPositions[trackIndex].breakEvenSet)
   {
      if(profitPips >= InpBreakEvenPips)
      {
         if(ApplyBreakEven(ticket, posType, entryPrice, currentSL, currentTP, bid, ask))
         {
            trackedPositions[trackIndex].breakEvenSet = true;
            if(InpPersistState)
               GlobalVariableSet(GetBEGlobalVarName(ticket), 1.0);

            if(PositionSelectByTicket(ticket))
               currentSL = PositionGetDouble(POSITION_SL);
         }
      }
   }

   // Trailing Stop Loss
   if(InpEnableTrailingSL && profitPips >= InpTrailingSLStart)
   {
      // Check trend filter
      if(!InpUseTrendFilter || (isStrongTrend && trendMatchesPosition))
      {
         ApplyTrailingStopLoss(ticket, posType, currentPrice, currentSL, currentTP, atrValue, isVeryStrongTrend, bid, ask);
      }
   }

   // Refresh SL/TP before trailing TP
   if(!PositionSelectByTicket(ticket))
      return;
   currentSL = PositionGetDouble(POSITION_SL);
   currentTP = PositionGetDouble(POSITION_TP);

   // Trailing Take Profit
   if(InpEnableTrailingTP && profitPips >= InpTPExtendThreshold)
   {
      // Only extend TP in strong trends that match position direction
      if(!InpUseTrendFilter || (isStrongTrend && trendMatchesPosition))
      {
         if(trackedPositions[trackIndex].tpExtensions < InpMaxTPExtensions)
         {
            double extendedTP = currentTP;
            if(ExtendTakeProfit(ticket, posType, currentPrice, currentSL, currentTP, atrValue, isVeryStrongTrend, bid, ask, extendedTP))
            {
               trackedPositions[trackIndex].tpExtensions++;
               trackedPositions[trackIndex].lastExtendedTP = extendedTP;
               if(InpPersistState)
                  GlobalVariableSet(GetExtGlobalVarName(ticket), (double)trackedPositions[trackIndex].tpExtensions);

               Print("TP Extended for ticket ", ticket, " | Extensions: ", trackedPositions[trackIndex].tpExtensions,
                     " | InitialTP: ", trackedPositions[trackIndex].initialTP, " | LastTP: ", extendedTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Apply initial SL/TP if not set                                    |
//+------------------------------------------------------------------+
void ApplyInitialSLTP(ulong ticket, ENUM_POSITION_TYPE posType, double entryPrice,
                      double currentSL, double currentTP, double atrValue,
                      double bid, double ask)
{
   double newSL = currentSL;
   double newTP = currentTP;
   bool needsModify = false;

   // Calculate SL distance
   double slDistance = InpInitialSLPips * pipSize;
   if(InpUseATRForSL)
      slDistance = MathMax(slDistance, atrValue * InpATRMultiplierSL);

   // Calculate TP distance
   double tpDistance = InpInitialTPPips * pipSize;
   if(InpUseATRForTP)
      tpDistance = MathMax(tpDistance, atrValue * InpATRMultiplierTP);

   if(posType == POSITION_TYPE_BUY)
   {
      if(currentSL <= 0.0 && slDistance > 0.0)
      {
         newSL = NormalizePrice(entryPrice - slDistance);
         needsModify = true;
      }
      if(currentTP <= 0.0 && tpDistance > 0.0)
      {
         newTP = NormalizePrice(entryPrice + tpDistance);
         needsModify = true;
      }
   }
   else // SELL
   {
      if(currentSL <= 0.0 && slDistance > 0.0)
      {
         newSL = NormalizePrice(entryPrice + slDistance);
         needsModify = true;
      }
      if(currentTP <= 0.0 && tpDistance > 0.0)
      {
         newTP = NormalizePrice(entryPrice - tpDistance);
         needsModify = true;
      }
   }

   if(!needsModify)
      return;

   if(!IsModifySafe(posType, bid, ask, currentSL, currentTP, newSL, newTP))
      return;

   if(trade.PositionModify(ticket, newSL, newTP) && IsModifyRetcodeSuccess(trade.ResultRetcode()))
   {
      Print("Initial SL/TP applied to ticket ", ticket, " | SL: ", newSL, " | TP: ", newTP);
   }
   else
   {
      Print("Failed to apply initial SL/TP to ticket ", ticket,
            " | Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
   }
}

//+------------------------------------------------------------------+
//| Apply break-even stop loss                                        |
//+------------------------------------------------------------------+
bool ApplyBreakEven(ulong ticket, ENUM_POSITION_TYPE posType, double entryPrice,
                    double currentSL, double currentTP, double bid, double ask)
{
   double newSL;
   double offset = InpBreakEvenOffset * pipSize;

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = NormalizePrice(entryPrice + offset);
      if(currentSL >= newSL)
         return true; // Already at or above breakeven
   }
   else
   {
      newSL = NormalizePrice(entryPrice - offset);
      if(currentSL != 0.0 && currentSL <= newSL)
         return true; // Already at or below breakeven
   }

   if(!IsModifySafe(posType, bid, ask, currentSL, currentTP, newSL, currentTP))
      return false;

   if(trade.PositionModify(ticket, newSL, currentTP) && IsModifyRetcodeSuccess(trade.ResultRetcode()))
   {
      Print("Break-even applied to ticket ", ticket, " | New SL: ", newSL);
      return true;
   }

   Print("Failed to apply break-even to ticket ", ticket,
         " | Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
   return false;
}

//+------------------------------------------------------------------+
//| Apply trailing stop loss                                          |
//+------------------------------------------------------------------+
void ApplyTrailingStopLoss(ulong ticket, ENUM_POSITION_TYPE posType, double currentPrice,
                           double currentSL, double currentTP, double atrValue,
                           bool isVeryStrongTrend, double bid, double ask)
{
   // Calculate trailing distance
   double trailDistance = InpTrailingSLDistance * pipSize;

   if(InpUseATRForSL)
   {
      double atrDistance = atrValue * InpATRMultiplierSL;
      // Use tighter stops in very strong trends
      if(isVeryStrongTrend)
         atrDistance *= 0.75;
      trailDistance = MathMax(trailDistance * 0.5, atrDistance);
   }

   if(trailDistance <= 0.0)
      return;

   double minStep = InpTrailingSLStep * pipSize;
   double newSL;

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = NormalizePrice(currentPrice - trailDistance);
      if(newSL <= 0.0)
         return;

      // Only move SL up, never down (allow setting initial trailing SL when currentSL == 0)
      if(currentSL != 0.0 && newSL <= currentSL) return;

      // Check minimum step when SL is already set
      if(currentSL != 0.0 && (newSL - currentSL) < minStep) return;
   }
   else // SELL
   {
      newSL = NormalizePrice(currentPrice + trailDistance);
      if(newSL <= 0.0)
         return;

      // Only move SL down, never up
      if(currentSL != 0.0 && newSL >= currentSL) return;

      // Check minimum step when SL is already set
      if(currentSL != 0.0 && (currentSL - newSL) < minStep) return;
   }

   if(!IsModifySafe(posType, bid, ask, currentSL, currentTP, newSL, currentTP))
      return;

   if(trade.PositionModify(ticket, newSL, currentTP) && IsModifyRetcodeSuccess(trade.ResultRetcode()))
   {
      Print("Trailing SL updated for ticket ", ticket, " | New SL: ", newSL, " | Distance: ", trailDistance / pipSize, " pips");
   }
   else
   {
      Print("Failed to update trailing SL for ticket ", ticket,
            " | Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
   }
}

//+------------------------------------------------------------------+
//| Extend take profit in strong trends                               |
//+------------------------------------------------------------------+
bool ExtendTakeProfit(ulong ticket, ENUM_POSITION_TYPE posType, double currentPrice,
                      double currentSL, double currentTP, double atrValue,
                      bool isVeryStrongTrend, double bid, double ask, double &outNewTP)
{
   if(currentTP <= 0.0)
      return false;

   // Calculate extension amount
   double extendAmount = InpTPExtendAmount * pipSize;

   if(InpUseATRForTP)
   {
      double atrExtend = atrValue * InpATRMultiplierTP;
      // Extend more aggressively in very strong trends
      if(isVeryStrongTrend)
         atrExtend *= 1.5;
      extendAmount = MathMax(extendAmount, atrExtend);
   }

   if(extendAmount <= 0.0)
      return false;

   double newTP;
   double distanceToTP;

   if(posType == POSITION_TYPE_BUY)
   {
      distanceToTP = currentTP - currentPrice;
      // Only extend if price is getting close to TP (within 50% of extension amount)
      if(distanceToTP > extendAmount * 0.5)
         return false;

      newTP = NormalizePrice(currentTP + extendAmount);
   }
   else // SELL
   {
      distanceToTP = currentPrice - currentTP;
      // Only extend if price is getting close to TP
      if(distanceToTP > extendAmount * 0.5)
         return false;

      newTP = NormalizePrice(currentTP - extendAmount);
      if(newTP <= 0.0)
         return false;
   }

   if(!IsModifySafe(posType, bid, ask, currentSL, currentTP, currentSL, newTP))
      return false;

   if(trade.PositionModify(ticket, currentSL, newTP) && IsModifyRetcodeSuccess(trade.ResultRetcode()))
   {
      outNewTP = newTP;
      Print("TP Extended for ticket ", ticket, " | New TP: ", newTP, " | Extension: ", extendAmount / pipSize, " pips");
      return true;
   }

   Print("Failed to extend TP for ticket ", ticket,
         " | Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
   return false;
}

//+------------------------------------------------------------------+
//| Update indicator buffers                                          |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(adxHandle, 0, 0, 3, adxBuffer) < 3) return false;
   if(CopyBuffer(adxHandle, 1, 0, 3, plusDIBuffer) < 3) return false;
   if(CopyBuffer(adxHandle, 2, 0, 3, minusDIBuffer) < 3) return false;
   if(CopyBuffer(atrHandle, 0, 0, 3, atrBuffer) < 3) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Get tracked position index                                        |
//+------------------------------------------------------------------+
int GetPositionTrackIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(trackedPositions); i++)
   {
      if(trackedPositions[i].ticket == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Add position to tracking array                                    |
//+------------------------------------------------------------------+
int AddTrackedPosition(ulong ticket, double entryPrice, double initialTP, datetime openTime)
{
   int size = ArraySize(trackedPositions);
   ArrayResize(trackedPositions, size + 1);

   bool restoredBE = false;
   int restoredExt = 0;

   if(InpPersistState)
   {
      string beVar  = GetBEGlobalVarName(ticket);
      string extVar = GetExtGlobalVarName(ticket);

      if(GlobalVariableCheck(beVar))
         restoredBE = (GlobalVariableGet(beVar) > 0.5);
      if(GlobalVariableCheck(extVar))
         restoredExt = (int)MathMax(0.0, GlobalVariableGet(extVar));
   }

   trackedPositions[size].ticket         = ticket;
   trackedPositions[size].entryPrice     = entryPrice;
   trackedPositions[size].initialTP      = initialTP;
   trackedPositions[size].lastExtendedTP = initialTP;
   trackedPositions[size].tpExtensions   = restoredExt;
   trackedPositions[size].breakEvenSet   = restoredBE;
   trackedPositions[size].openTime       = openTime;

   Print("Now tracking position: ", ticket,
         " | Restored BE: ", restoredBE ? "true" : "false",
         " | Restored TP Ext: ", restoredExt);

   return size;
}

//+------------------------------------------------------------------+
//| Clean up closed positions from tracking array                     |
//+------------------------------------------------------------------+
void CleanupTrackedPositions()
{
   for(int i = ArraySize(trackedPositions) - 1; i >= 0; i--)
   {
      ulong ticket = trackedPositions[i].ticket;
      if(!PositionSelectByTicket(ticket))
      {
         // Position no longer exists, clean up persisted globals and tracking entry
         string beVar  = GetBEGlobalVarName(ticket);
         string extVar = GetExtGlobalVarName(ticket);
         if(GlobalVariableCheck(beVar))
            GlobalVariableDel(beVar);
         if(GlobalVariableCheck(extVar))
            GlobalVariableDel(extVar);

         Print("Position ", ticket, " closed, removing from tracking");

         for(int j = i; j < ArraySize(trackedPositions) - 1; j++)
         {
            trackedPositions[j] = trackedPositions[j + 1];
         }
         ArrayResize(trackedPositions, ArraySize(trackedPositions) - 1);
      }
   }
}

//+------------------------------------------------------------------+
//| Chart event handler for display                                   |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   // Can be used for GUI elements if needed
}

//+------------------------------------------------------------------+
//| Display dashboard on chart                                        |
//+------------------------------------------------------------------+
void DisplayDashboard()
{
   string prefix = "TTPSL_";
   int x = 10, y = 30;
   int lineHeight = 18;
   color textColor = clrWhite;

   double bid = SymbolInfoDouble(workSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(workSymbol, SYMBOL_ASK);
   double spreadPips = (bid > 0.0 && ask > 0.0 && pipSize > 0.0) ? ((ask - bid) / pipSize) : 0.0;
   long stopsLevel = SymbolInfoInteger(workSymbol, SYMBOL_TRADE_STOPS_LEVEL);

   // Title
   CreateLabel(prefix + "Title", "=== Trailing TP/SL EA v2.00 ===", x, y, clrGold);
   y += lineHeight + 5;

   // Symbol
   CreateLabel(prefix + "Symbol", "Symbol: " + workSymbol, x, y, textColor);
   y += lineHeight;

   // ADX Value
   string adxText = StringFormat("ADX: %.1f", adxBuffer[0]);
   color adxColor = adxBuffer[0] >= InpStrongTrendADX ? clrLime :
                    (adxBuffer[0] >= InpADXThreshold ? clrYellow : clrRed);
   CreateLabel(prefix + "ADX", adxText, x, y, adxColor);
   y += lineHeight;

   // ATR Value
   string atrText = StringFormat("ATR: %.*f", MathMax(digits, 4), atrBuffer[0]);
   CreateLabel(prefix + "ATR", atrText, x, y, textColor);
   y += lineHeight;

   // Trend Direction
   string trendDir = plusDIBuffer[0] > minusDIBuffer[0] ? "BULLISH" : "BEARISH";
   color trendColor = plusDIBuffer[0] > minusDIBuffer[0] ? clrLime : clrRed;
   CreateLabel(prefix + "Trend", "Trend: " + trendDir, x, y, trendColor);
   y += lineHeight;

   // Spread in pips
   string spreadText = StringFormat("Spread: %.1f pips", spreadPips);
   color spreadColor = (InpMaxSpreadPips > 0.0 && spreadPips > InpMaxSpreadPips) ? clrOrangeRed : textColor;
   CreateLabel(prefix + "Spread", spreadText, x, y, spreadColor);
   y += lineHeight;

   // Stops level
   string stopsText = StringFormat("Stops Level: %d pts", stopsLevel);
   CreateLabel(prefix + "Stops", stopsText, x, y, textColor);
   y += lineHeight;

   // Tracked positions count
   string posText = StringFormat("Tracking: %d positions", ArraySize(trackedPositions));
   CreateLabel(prefix + "Positions", posText, x, y, textColor);
}

//+------------------------------------------------------------------+
//| Create text label on chart                                        |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}
//+------------------------------------------------------------------+
