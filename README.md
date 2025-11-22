# XAGUSD Trailing TP/SL Expert Advisor for MetaTrader 5

An intelligent Expert Advisor that automatically applies and manages trailing Take Profit and Stop Loss orders on manually entered XAGUSD (Silver) trades. Designed for high-leverage accounts (500x) with trend-based adaptive trailing logic.

## Features

- **Automatic SL/TP Application**: Automatically applies initial Stop Loss and Take Profit to manual trades that don't have them set
- **Trailing Stop Loss**: Dynamically trails the stop loss as price moves in your favor
- **Trailing Take Profit**: Extends take profit targets when strong trends are detected
- **Trend Detection**: Uses ADX (Average Directional Index) to identify trend strength
- **ATR-Based Distances**: Dynamically calculates SL/TP distances using ATR for market volatility adaptation
- **Break-Even Feature**: Automatically moves SL to break-even after specified profit
- **High Leverage Optimized**: Configured for 500x leverage accounts

## Installation

1. **Copy the EA file**:
   - Copy `XAGUSD_TrailingTPSL.mq5` to your MetaTrader 5 `Experts` folder
   - Typical path: `C:\Users\[Username]\AppData\Roaming\MetaQuotes\Terminal\[Instance]\MQL5\Experts\`

2. **Compile the EA**:
   - Open MetaEditor (F4 from MT5)
   - Open the file and press F7 to compile
   - Ensure no errors are present

3. **Attach to Chart**:
   - Open an XAGUSD chart in MT5
   - Drag the EA from the Navigator panel onto the chart
   - Enable "Allow Algo Trading" in the EA properties

## Configuration Parameters

### General Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpSymbol | XAGUSD | Symbol to monitor |
| InpMagicNumber | 0 | Magic number (0 = all manual trades) |
| InpCheckIntervalMs | 500 | Check interval in milliseconds |

### Initial SL/TP Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpApplyInitialSLTP | true | Apply initial SL/TP if not set |
| InpInitialSLPips | 50.0 | Initial Stop Loss distance (pips) |
| InpInitialTPPips | 100.0 | Initial Take Profit distance (pips) |

### Trailing Stop Loss Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpEnableTrailingSL | true | Enable Trailing Stop Loss |
| InpTrailingSLStart | 20.0 | Start trailing after X pips profit |
| InpTrailingSLDistance | 15.0 | Trailing SL distance (pips) |
| InpTrailingSLStep | 5.0 | Minimum SL move step (pips) |
| InpUseATRForSL | true | Use ATR for dynamic SL distance |

### Trailing Take Profit Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpEnableTrailingTP | true | Enable Trailing Take Profit |
| InpTPExtendThreshold | 30.0 | Extend TP after X pips in profit |
| InpTPExtendAmount | 20.0 | Amount to extend TP (pips) |
| InpMaxTPExtensions | 5 | Maximum TP extensions allowed |
| InpUseATRForTP | true | Use ATR for dynamic TP extension |

### Trend Detection Settings (ADX)
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpUseTrendFilter | true | Only trail in strong trends |
| InpADXPeriod | 14 | ADX Period |
| InpADXThreshold | 25.0 | ADX threshold for strong trend |
| InpStrongTrendADX | 35.0 | ADX for very strong trend (aggressive trailing) |

### ATR Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpATRPeriod | 14 | ATR Period |
| InpATRMultiplierSL | 1.5 | ATR Multiplier for SL distance |
| InpATRMultiplierTP | 2.5 | ATR Multiplier for TP distance |

### Risk Management
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpBreakEvenPips | 30.0 | Move SL to breakeven after X pips |
| InpBreakEvenOffset | 2.0 | Breakeven offset (pips in profit) |
| InpEnableBreakEven | true | Enable breakeven feature |

## How It Works

### Trailing Stop Loss Logic
1. Waits until position is in profit by `InpTrailingSLStart` pips
2. If trend filter is enabled, checks ADX for trend strength
3. Calculates trailing distance using either fixed pips or ATR-based distance
4. Moves SL to lock in profits, maintaining the trailing distance from current price
5. In very strong trends (ADX > 35), uses tighter stops (75% of normal distance)

### Trailing Take Profit Logic
1. Monitors positions that reach `InpTPExtendThreshold` pips in profit
2. When price approaches current TP (within 50% of extension amount), extends the TP
3. Extension amount is calculated using fixed pips or ATR
4. In very strong trends, extension amount is increased by 150%
5. Limited to `InpMaxTPExtensions` extensions per position

### Trend Detection
- **ADX < 25**: Weak/No trend - Trailing disabled (if filter enabled)
- **ADX 25-35**: Moderate trend - Normal trailing behavior
- **ADX > 35**: Strong trend - Aggressive trailing (tighter SL, larger TP extensions)

## Usage Tips

1. **For Conservative Trading**:
   - Increase `InpTrailingSLDistance` to 25-30 pips
   - Set `InpADXThreshold` to 30
   - Reduce `InpMaxTPExtensions` to 2-3

2. **For Aggressive Trading**:
   - Decrease `InpTrailingSLDistance` to 10 pips
   - Set `InpADXThreshold` to 20
   - Increase `InpMaxTPExtensions` to 7-10

3. **For High Volatility Periods**:
   - Enable ATR-based distances
   - Increase ATR multipliers

4. **For 500x Leverage**:
   - Use tighter initial SL (30-40 pips)
   - Enable break-even feature
   - Start trailing early (15-20 pips)

## Risk Warning

Trading with high leverage (500x) carries significant risk. This EA is designed to help manage risk through trailing stops, but it cannot guarantee profits or prevent losses. Always:

- Test on a demo account first
- Use appropriate position sizing
- Never risk more than you can afford to lose
- Monitor your trades regularly

## License

This Expert Advisor is provided as-is for educational and personal use.
