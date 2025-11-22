//+------------------------------------------------------------------+
//|                                         XAGUSD_TrailingTPSL.mq5 |
//|                        Trailing TP/SL EA for Manual XAGUSD Trades|
//|                                                                  |
//| Automatically applies and trails Take Profit and Stop Loss      |
//| on manually entered XAGUSD positions based on trend strength    |
//+------------------------------------------------------------------+
#property copyright "2024"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== General Settings ==="
input string   InpSymbol              = "XAGUSD";     // Symbol to monitor
input int      InpMagicNumber         = 0;            // Magic number (0 = all manual trades)
input int      InpCheckIntervalMs     = 500;          // Check interval in milliseconds

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
input double   InpMaxTPExtensions     = 5;            // Maximum TP extensions allowed
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
CPositionInfo  positionInfo;

int            adxHandle;
int            atrHandle;
double         adxBuffer[];
double         plusDIBuffer[];
double         minusDIBuffer[];
double         atrBuffer[];

struct PositionData
{
   ulong    ticket;
   double   entryPrice;
   double   initialTP;
   int      tpExtensions;
   bool     breakEvenSet;
   datetime openTime;
};

PositionData   trackedPositions[];
double         pipValue;
double         pipSize;
int            digits;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate symbol
   if(!SymbolSelect(InpSymbol, true))
   {
      Print("Error: Symbol ", InpSymbol, " not found!");
      return INIT_FAILED;
   }

   // Get symbol properties
   digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   // Calculate pip size for XAGUSD (typically 0.01 for silver)
   if(digits == 3)
      pipSize = 0.01;
   else if(digits == 2)
      pipSize = 0.01;
   else if(digits == 5)
      pipSize = 0.0001;
   else
      pipSize = SymbolInfoDouble(InpSymbol, SYMBOL_POINT) * 10;

   pipValue = pipSize;

   Print("Initialized for ", InpSymbol, " | Digits: ", digits, " | Pip Size: ", pipSize);

   // Initialize indicators
   adxHandle = iADX(InpSymbol, PERIOD_CURRENT, InpADXPeriod);
   atrHandle = iATR(InpSymbol, PERIOD_CURRENT, InpATRPeriod);

   if(adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Error creating indicators!");
      return INIT_FAILED;
   }

   // Set up arrays
   ArraySetAsSeries(adxBuffer, true);
   ArraySetAsSeries(plusDIBuffer, true);
   ArraySetAsSeries(minusDIBuffer, true);
   ArraySetAsSeries(atrBuffer, true);

   // Set up trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Set timer for regular checks
   EventSetMillisecondTimer(InpCheckIntervalMs);

   Print("==============================================");
   Print("XAGUSD Trailing TP/SL EA Initialized");
   Print("Monitoring symbol: ", InpSymbol);
   Print("Leverage: 500x (High leverage mode)");
   Print("Trailing SL: ", InpEnableTrailingSL ? "Enabled" : "Disabled");
   Print("Trailing TP: ", InpEnableTrailingTP ? "Enabled" : "Disabled");
   Print("Trend Filter: ", InpUseTrendFilter ? "Enabled" : "Disabled");
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
      IndicatorRelease(adxHandle);
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   Print("XAGUSD Trailing TP/SL EA Deinitialized");
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
      if(symbol != InpSymbol) continue;

      // Check magic number (0 = all manual trades)
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(InpMagicNumber != 0 && magic != InpMagicNumber) continue;

      // Process this position
      ProcessSinglePosition(ticket);
   }

   // Clean up tracked positions that no longer exist
   CleanupTrackedPositions();
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
   double volume = PositionGetDouble(POSITION_VOLUME);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;

   // Calculate profit in pips
   double profitPips = 0;
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
      ApplyInitialSLTP(ticket, posType, entryPrice, currentSL, currentTP, atrValue);
   }

   // Refresh position data after potential modification
   if(!PositionSelectByTicket(ticket))
      return;
   currentSL = PositionGetDouble(POSITION_SL);
   currentTP = PositionGetDouble(POSITION_TP);

   // Break-even logic
   if(InpEnableBreakEven && !trackedPositions[trackIndex].breakEvenSet)
   {
      if(profitPips >= InpBreakEvenPips)
      {
         ApplyBreakEven(ticket, posType, entryPrice, currentSL);
         trackedPositions[trackIndex].breakEvenSet = true;
      }
   }

   // Trailing Stop Loss
   if(InpEnableTrailingSL && profitPips >= InpTrailingSLStart)
   {
      // Check trend filter
      if(!InpUseTrendFilter || (isStrongTrend && trendMatchesPosition))
      {
         ApplyTrailingStopLoss(ticket, posType, currentPrice, currentSL, atrValue, isVeryStrongTrend);
      }
   }

   // Trailing Take Profit
   if(InpEnableTrailingTP && profitPips >= InpTPExtendThreshold)
   {
      // Only extend TP in strong trends that match position direction
      if(!InpUseTrendFilter || (isStrongTrend && trendMatchesPosition))
      {
         if(trackedPositions[trackIndex].tpExtensions < InpMaxTPExtensions)
         {
            if(ExtendTakeProfit(ticket, posType, currentPrice, currentTP, atrValue, isVeryStrongTrend))
            {
               trackedPositions[trackIndex].tpExtensions++;
               trackedPositions[trackIndex].initialTP = currentTP;
               Print("TP Extended for ticket ", ticket, " | Extensions: ", trackedPositions[trackIndex].tpExtensions);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Apply initial SL/TP if not set                                    |
//+------------------------------------------------------------------+
void ApplyInitialSLTP(ulong ticket, ENUM_POSITION_TYPE posType, double entryPrice,
                      double currentSL, double currentTP, double atrValue)
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
      if(currentSL == 0 || currentSL < 0.0001)
      {
         newSL = NormalizeDouble(entryPrice - slDistance, digits);
         needsModify = true;
      }
      if(currentTP == 0 || currentTP < 0.0001)
      {
         newTP = NormalizeDouble(entryPrice + tpDistance, digits);
         needsModify = true;
      }
   }
   else // SELL
   {
      if(currentSL == 0 || currentSL < 0.0001)
      {
         newSL = NormalizeDouble(entryPrice + slDistance, digits);
         needsModify = true;
      }
      if(currentTP == 0 || currentTP < 0.0001)
      {
         newTP = NormalizeDouble(entryPrice - tpDistance, digits);
         needsModify = true;
      }
   }

   if(needsModify)
   {
      if(trade.PositionModify(ticket, newSL, newTP))
      {
         Print("Initial SL/TP applied to ticket ", ticket, " | SL: ", newSL, " | TP: ", newTP);
      }
      else
      {
         Print("Failed to apply initial SL/TP to ticket ", ticket, " | Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Apply break-even stop loss                                        |
//+------------------------------------------------------------------+
void ApplyBreakEven(ulong ticket, ENUM_POSITION_TYPE posType, double entryPrice, double currentSL)
{
   double newSL;
   double offset = InpBreakEvenOffset * pipSize;

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = NormalizeDouble(entryPrice + offset, digits);
      if(currentSL >= newSL) return; // Already at or above breakeven
   }
   else
   {
      newSL = NormalizeDouble(entryPrice - offset, digits);
      if(currentSL != 0 && currentSL <= newSL) return; // Already at or below breakeven
   }

   double currentTP = PositionGetDouble(POSITION_TP);

   if(trade.PositionModify(ticket, newSL, currentTP))
   {
      Print("Break-even applied to ticket ", ticket, " | New SL: ", newSL);
   }
}

//+------------------------------------------------------------------+
//| Apply trailing stop loss                                          |
//+------------------------------------------------------------------+
void ApplyTrailingStopLoss(ulong ticket, ENUM_POSITION_TYPE posType, double currentPrice,
                           double currentSL, double atrValue, bool isVeryStrongTrend)
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

   double minStep = InpTrailingSLStep * pipSize;
   double newSL;

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = NormalizeDouble(currentPrice - trailDistance, digits);

      // Only move SL up, never down
      if(currentSL == 0 || newSL <= currentSL) return;

      // Check minimum step
      if((newSL - currentSL) < minStep) return;
   }
   else // SELL
   {
      newSL = NormalizeDouble(currentPrice + trailDistance, digits);

      // Only move SL down, never up
      if(currentSL != 0 && newSL >= currentSL) return;

      // Check minimum step
      if(currentSL != 0 && (currentSL - newSL) < minStep) return;
   }

   double currentTP = PositionGetDouble(POSITION_TP);

   if(trade.PositionModify(ticket, newSL, currentTP))
   {
      Print("Trailing SL updated for ticket ", ticket, " | New SL: ", newSL, " | Distance: ", trailDistance/pipSize, " pips");
   }
}

//+------------------------------------------------------------------+
//| Extend take profit in strong trends                               |
//+------------------------------------------------------------------+
bool ExtendTakeProfit(ulong ticket, ENUM_POSITION_TYPE posType, double currentPrice,
                      double currentTP, double atrValue, bool isVeryStrongTrend)
{
   if(currentTP == 0) return false;

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

   double newTP;
   double distanceToTP;

   if(posType == POSITION_TYPE_BUY)
   {
      distanceToTP = currentTP - currentPrice;
      // Only extend if price is getting close to TP (within 50% of extension amount)
      if(distanceToTP > extendAmount * 0.5) return false;

      newTP = NormalizeDouble(currentTP + extendAmount, digits);
   }
   else // SELL
   {
      distanceToTP = currentPrice - currentTP;
      // Only extend if price is getting close to TP
      if(distanceToTP > extendAmount * 0.5) return false;

      newTP = NormalizeDouble(currentTP - extendAmount, digits);
   }

   double currentSL = PositionGetDouble(POSITION_SL);

   if(trade.PositionModify(ticket, currentSL, newTP))
   {
      Print("TP Extended for ticket ", ticket, " | New TP: ", newTP, " | Extension: ", extendAmount/pipSize, " pips");
      return true;
   }

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

   trackedPositions[size].ticket = ticket;
   trackedPositions[size].entryPrice = entryPrice;
   trackedPositions[size].initialTP = initialTP;
   trackedPositions[size].tpExtensions = 0;
   trackedPositions[size].breakEvenSet = false;
   trackedPositions[size].openTime = openTime;

   Print("Now tracking position: ", ticket);

   return size;
}

//+------------------------------------------------------------------+
//| Clean up closed positions from tracking array                     |
//+------------------------------------------------------------------+
void CleanupTrackedPositions()
{
   for(int i = ArraySize(trackedPositions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(trackedPositions[i].ticket))
      {
         // Position no longer exists, remove from tracking
         Print("Position ", trackedPositions[i].ticket, " closed, removing from tracking");

         // Remove by shifting elements
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

   // Title
   CreateLabel(prefix + "Title", "=== Trailing TP/SL EA ===", x, y, clrGold);
   y += lineHeight + 5;

   // ADX Value
   string adxText = StringFormat("ADX: %.1f", adxBuffer[0]);
   color adxColor = adxBuffer[0] >= InpStrongTrendADX ? clrLime :
                    (adxBuffer[0] >= InpADXThreshold ? clrYellow : clrRed);
   CreateLabel(prefix + "ADX", adxText, x, y, adxColor);
   y += lineHeight;

   // ATR Value
   string atrText = StringFormat("ATR: %.4f", atrBuffer[0]);
   CreateLabel(prefix + "ATR", atrText, x, y, textColor);
   y += lineHeight;

   // Trend Direction
   string trendDir = plusDIBuffer[0] > minusDIBuffer[0] ? "BULLISH" : "BEARISH";
   color trendColor = plusDIBuffer[0] > minusDIBuffer[0] ? clrLime : clrRed;
   CreateLabel(prefix + "Trend", "Trend: " + trendDir, x, y, trendColor);
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
