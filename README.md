# XAGUSD Trailing TP/SL Expert Advisor for MetaTrader 5 (v2.00)

An Expert Advisor for MetaTrader 5 that automatically applies and manages adaptive trailing Take Profit, trailing Stop Loss, and break-even protection on manually entered XAGUSD (Silver) or other symbol trades using ADX trend strength and ATR volatility.

## Features (v2.00)

- **Broker-Suffix & Symbol Auto-Detection**: Defaults `InpSymbol=""` to monitor the active chart symbol (`_Symbol`) automatically — works seamlessly with broker suffixes such as `XAGUSD.m`, `XAGUSD#`, or `XAGUSDpro`, with optional manual symbol and `InpPipSizeOverride`.
- **Automatic Initial SL/TP**: Applies initial Stop Loss and Take Profit to manual trades that do not already have them set.
- **Trailing Stop Loss**: Dynamically trails SL as profit grows, including positions that initially have `SL = 0` on both BUY and SELL sides, respecting `InpTrailingSLStep`.
- **Trailing Take Profit**: Extends TP targets when price approaches TP during strong ADX-confirmed trends, capped at `InpMaxTPExtensions` while preserving `initialTP`.
- **Break-Even Protection**: Moves SL to entry plus `InpBreakEvenOffset` after `InpBreakEvenPips` profit, and only marks break-even complete once the broker modification succeeds (retrying automatically on transient errors).
- **Broker Stops, Freeze, Tick-Size & Spread Safety**:
  - Rounds all SL/TP prices to `SYMBOL_TRADE_TICK_SIZE` and symbol digits (`NormalizePrice()`).
  - Enforces `SYMBOL_TRADE_STOPS_LEVEL` and `SYMBOL_TRADE_FREEZE_LEVEL` before sending `PositionModify`.
  - Auto-detects the broker's supported `SYMBOL_FILLING_MODE` (`IOC` / `FOK` / `RETURN`).
  - Verifies terminal, EA, account, and symbol trading permissions before modifying orders.
  - Optional `InpMaxSpreadPips` filter to skip modifications during wide spreads.
- **Restart State Persistence**: Persists break-even state (`TTPSL_BE_<ticket>`) and TP extension counts (`TTPSL_EXT_<ticket>`) via MT5 Global Variables when `InpPersistState=true`, cleaning them up automatically when positions close.
- **Live Chart Dashboard**: Displays symbol, ADX, ATR, trend direction, current spread in pips, broker stops level, and tracked position count (`InpShowDashboard=true`), and cleans up all `TTPSL_*` chart objects on removal.

## Installation

1. **Copy the EA file**:
   - Copy `XAGUSD_TrailingTPSL.mq5` to your MetaTrader 5 `MQL5/Experts/` folder.
   - Typical Windows path: `C:\Users\[Username]\AppData\Roaming\MetaQuotes\Terminal\[Instance]\MQL5\Experts\`
   - Typical macOS (Wine/Crossover) path: check via MetaTrader 5 `File -> Open Data Folder`.

2. **Compile the EA**:
   - Open MetaEditor (`F4` from MT5).
   - Open `XAGUSD_TrailingTPSL.mq5` and press `F7` to compile.
   - Verify 0 errors in the Toolbox Errors tab.

3. **Attach to Chart & Load Preset (Optional)**:
   - Open your `XAGUSD` (or broker-suffixed, e.g. `XAGUSD.m`) chart in MT5.
   - Drag the EA from Navigator onto the chart.
   - Optionally click **Load** in the Inputs tab and select one of the presets in `presets/`:
     - `presets/XAGUSD_Default.set` — balanced defaults
     - `presets/XAGUSD_Conservative.set` — wider trailing distance, higher ADX filter, 5-pip spread guard
     - `presets/XAGUSD_Aggressive.set` — tighter trailing distance, earlier activation, more TP extensions
   - Enable **Allow Algo Trading** in both the EA properties and the MT5 toolbar.

## Configuration Parameters

### General Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpSymbol` | `""` | Symbol to monitor; leave empty (`""`) to use the current chart symbol (auto-handles broker suffixes) |
| `InpMagicNumber` | `0` | Magic number filter (`0` = manage all manual trades on the symbol) |
| `InpCheckIntervalMs` | `500` | Timer check interval in milliseconds (minimum `100`) |
| `InpPipSizeOverride` | `0.0` | Manual pip size override (`0.0` = auto-detect from `SYMBOL_DIGITS` / `SYMBOL_POINT`) |
| `InpMaxSpreadPips` | `0.0` | Maximum allowed spread in pips when modifying SL/TP (`0.0` = disabled) |
| `InpShowDashboard` | `true` | Display live on-chart status dashboard (`TTPSL_*` labels) |
| `InpPersistState` | `true` | Persist break-even and TP extension counts across EA/terminal restarts |

### Initial SL/TP Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpApplyInitialSLTP` | `true` | Apply initial SL/TP to positions missing them |
| `InpInitialSLPips` | `50.0` | Initial Stop Loss distance (pips) |
| `InpInitialTPPips` | `100.0` | Initial Take Profit distance (pips) |

### Trailing Stop Loss Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpEnableTrailingSL` | `true` | Enable Trailing Stop Loss |
| `InpTrailingSLStart` | `20.0` | Minimum profit in pips before trailing SL activates |
| `InpTrailingSLDistance` | `15.0` | Base trailing SL distance (pips) |
| `InpTrailingSLStep` | `5.0` | Minimum SL improvement step (pips) when an SL is already set |
| `InpUseATRForSL` | `true` | Use ATR (`InpATRMultiplierSL`) for dynamic SL distance |

### Trailing Take Profit Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpEnableTrailingTP` | `true` | Enable Trailing Take Profit extension |
| `InpTPExtendThreshold` | `30.0` | Minimum profit in pips before TP extension is considered |
| `InpTPExtendAmount` | `20.0` | Base TP extension distance (pips) |
| `InpMaxTPExtensions` | `5` | Maximum number of TP extensions per position (`int`) |
| `InpUseATRForTP` | `true` | Use ATR (`InpATRMultiplierTP`) for dynamic TP extension |

### Trend Detection Settings (ADX)
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseTrendFilter` | `true` | Require ADX trend strength & directional DI alignment before trailing |
| `InpADXPeriod` | `14` | ADX indicator period (minimum `2`) |
| `InpADXThreshold` | `25.0` | ADX threshold for a strong trend |
| `InpStrongTrendADX` | `35.0` | ADX threshold for a very strong trend (tighter SL, larger TP extensions; must be `>= InpADXThreshold`) |

### ATR Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpATRPeriod` | `14` | ATR indicator period (minimum `2`) |
| `InpATRMultiplierSL` | `1.5` | ATR multiplier for Stop Loss distance |
| `InpATRMultiplierTP` | `2.5` | ATR multiplier for Take Profit distance/extension |

### Risk Management
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpBreakEvenPips` | `30.0` | Profit in pips required to move SL to break-even |
| `InpBreakEvenOffset` | `2.0` | Break-even offset in pips past entry price |
| `InpEnableBreakEven` | `true` | Enable automatic break-even stop loss |

## How It Works

### Stops, Freeze-Level & Tick-Size Compliance
Before any `PositionModify` call, the EA:
1. Normalizes target prices using `SYMBOL_TRADE_TICK_SIZE` and `SYMBOL_DIGITS`.
2. Checks terminal, EA, account, and symbol trading permissions.
3. Checks `InpMaxSpreadPips` if configured.
4. Verifies existing SL/TP are outside `SYMBOL_TRADE_FREEZE_LEVEL` and proposed SL/TP satisfy `MathMax(SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL)`.
5. Logs `ResultRetcode()` and `ResultRetcodeDescription()` on any modification failure.

### Persistence Across Restarts
When `InpPersistState` is `true`, each tracked ticket stores `TTPSL_BE_<ticket>` and `TTPSL_EXT_<ticket>` in MT5 Terminal Global Variables. If MT5 restarts or the EA is reloaded, `breakEvenSet` and `tpExtensions` are restored so TP extension caps are still respected. When the position closes, those variables are deleted in `CleanupTrackedPositions()`.

### Testing
Run the static MQL5 + reference logic test suite locally with Python's standard library:

```bash
python3 -m unittest discover -s tests -v
```

## Risk Warning

Trading CFDs, precious metals (XAGUSD), and leveraged forex products carries a high level of risk and may not be suitable for all investors. High leverage (such as 500x) magnifies both gains and losses and can lead to rapid account depletion. Slippage, spread widening, broker stops/freeze levels, and weekend gaps can prevent stop orders from executing at exact target prices.

Always:
- Test thoroughly on a demo account before running on live funds
- Use conservative position sizing appropriate for your equity
- Never trade capital you cannot afford to lose
- Monitor open positions and broker connectivity regularly

## License

Licensed under the [MIT License](LICENSE). Copyright (c) 2026 flowmar47.
