import math
import re
import unittest
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MQ5_PATH = ROOT / "XAGUSD_TrailingTPSL.mq5"
README_PATH = ROOT / "README.md"
PRESETS_DIR = ROOT / "presets"


def strip_mql_comments_and_strings(source: str) -> str:
    """Remove MQL5 string literals, char literals, and // or /* */ comments."""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            i += 2
            while i < n and source[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (source[i] == "*" and source[i + 1] == "/"):
                i += 1
            i += 2
        elif ch == '"':
            i += 1
            while i < n:
                if source[i] == "\\" and i + 1 < n:
                    i += 2
                elif source[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            out.append(" ")
        elif ch == "'":
            i += 1
            while i < n:
                if source[i] == "\\" and i + 1 < n:
                    i += 2
                elif source[i] == "'":
                    i += 1
                    break
                else:
                    i += 1
            out.append(" ")
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def extract_function_body(source: str, func_name: str) -> str:
    """Extract the brace-delimited body of a named MQL5 function."""
    pattern = re.compile(rf"\b{re.escape(func_name)}\s*\([^)]*\)\s*\{{", re.MULTILINE)
    match = pattern.search(source)
    if not match:
        raise AssertionError(f"Function {func_name} not found")
    start = match.end() - 1
    cleaned = strip_mql_comments_and_strings(source[start:])
    depth = 0
    for idx, ch in enumerate(cleaned):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return cleaned[: idx + 1]
    raise AssertionError(f"Unbalanced braces in function {func_name}")


def parse_mq5_inputs(source: str) -> dict[str, str]:
    """Return mapping of input variable name -> MQL5 type from the EA source."""
    inputs: dict[str, str] = {}
    pattern = re.compile(
        r"^\s*input\s+(?!group\b)(string|int|double|bool)\s+(Inp\w+)\s*=",
        re.MULTILINE,
    )
    for m in pattern.finditer(source):
        inputs[m.group(2)] = m.group(1)
    return inputs


# ---------------------------------------------------------------------------
# Pure-Python reference model mirroring XAGUSD_TrailingTPSL.mq5 v2.00 logic
# ---------------------------------------------------------------------------
@dataclass
class SymbolSpec:
    digits: int = 3
    point: float = 0.001
    tick_size: float = 0.001
    stops_level: int = 10
    freeze_level: int = 0
    trade_disabled: bool = False


@dataclass
class Permissions:
    terminal_allowed: bool = True
    mql_allowed: bool = True
    account_allowed: bool = True


@dataclass
class SimPosition:
    ticket: int
    pos_type: str  # "BUY" or "SELL"
    entry_price: float
    sl: float = 0.0
    tp: float = 0.0
    initial_tp: float = 0.0
    last_extended_tp: float = 0.0
    tp_extensions: int = 0
    break_even_set: bool = False


class ReferenceEA:
    """Exact pure-Python simulation of v2.00 EA risk/trailing calculations."""

    def __init__(
        self,
        spec: SymbolSpec | None = None,
        perms: Permissions | None = None,
        *,
        pip_size_override: float = 0.0,
        max_spread_pips: float = 0.0,
        initial_sl_pips: float = 50.0,
        initial_tp_pips: float = 100.0,
        trailing_sl_start: float = 20.0,
        trailing_sl_distance: float = 15.0,
        trailing_sl_step: float = 5.0,
        use_atr_for_sl: bool = True,
        tp_extend_threshold: float = 30.0,
        tp_extend_amount: float = 20.0,
        max_tp_extensions: int = 5,
        use_atr_for_tp: bool = True,
        atr_mult_sl: float = 1.5,
        atr_mult_tp: float = 2.5,
        break_even_pips: float = 30.0,
        break_even_offset: float = 2.0,
    ) -> None:
        self.spec = spec or SymbolSpec()
        self.perms = perms or Permissions()
        self.max_spread_pips = max_spread_pips
        self.initial_sl_pips = initial_sl_pips
        self.initial_tp_pips = initial_tp_pips
        self.trailing_sl_start = trailing_sl_start
        self.trailing_sl_distance = trailing_sl_distance
        self.trailing_sl_step = trailing_sl_step
        self.use_atr_for_sl = use_atr_for_sl
        self.tp_extend_threshold = tp_extend_threshold
        self.tp_extend_amount = tp_extend_amount
        self.max_tp_extensions = max_tp_extensions
        self.use_atr_for_tp = use_atr_for_tp
        self.atr_mult_sl = atr_mult_sl
        self.atr_mult_tp = atr_mult_tp
        self.break_even_pips = break_even_pips
        self.break_even_offset = break_even_offset

        if pip_size_override > 0.0:
            self.pip_size = pip_size_override
        elif self.spec.digits in (2, 3):
            self.pip_size = 0.01
        elif self.spec.digits in (4, 5):
            self.pip_size = 0.0001
        else:
            self.pip_size = self.spec.point * 10.0

        self.modify_should_succeed = True
        self.modify_calls: list[tuple[int, float, float]] = []

    def normalize_price(self, price: float) -> float:
        if price <= 0.0:
            return 0.0
        if self.spec.tick_size > 0.0:
            price = round(price / self.spec.tick_size) * self.spec.tick_size
        return round(price, self.spec.digits)

    def get_min_stop_distance(self) -> float:
        return max(self.spec.stops_level, self.spec.freeze_level) * self.spec.point

    def is_modify_safe(
        self,
        pos_type: str,
        bid: float,
        ask: float,
        current_sl: float,
        current_tp: float,
        new_sl: float,
        new_tp: float,
    ) -> bool:
        if bid <= 0.0 or ask <= 0.0:
            return False
        if (
            not self.perms.terminal_allowed
            or not self.perms.mql_allowed
            or not self.perms.account_allowed
            or self.spec.trade_disabled
        ):
            return False
        if self.max_spread_pips > 0.0:
            spread_pips = (ask - bid) / self.pip_size
            if spread_pips > self.max_spread_pips:
                return False

        freeze_dist = self.spec.freeze_level * self.spec.point
        ref_price = bid if pos_type == "BUY" else ask
        if freeze_dist > 0.0:
            if current_sl > 0.0 and abs(ref_price - current_sl) <= freeze_dist:
                return False
            if current_tp > 0.0 and abs(ref_price - current_tp) <= freeze_dist:
                return False

        min_stop_dist = self.get_min_stop_distance()
        eps = self.spec.point * 0.01
        if pos_type == "BUY":
            if new_sl > 0.0 and (new_sl >= bid or (bid - new_sl) + eps < min_stop_dist):
                return False
            if new_tp > 0.0 and (new_tp <= bid or (new_tp - bid) + eps < min_stop_dist):
                return False
        else:
            if new_sl > 0.0 and (new_sl <= ask or (new_sl - ask) + eps < min_stop_dist):
                return False
            if new_tp > 0.0 and (new_tp >= ask or (ask - new_tp) + eps < min_stop_dist):
                return False
        return True

    def _modify(self, pos: SimPosition, new_sl: float, new_tp: float) -> bool:
        self.modify_calls.append((pos.ticket, new_sl, new_tp))
        if not self.modify_should_succeed:
            return False
        pos.sl = new_sl
        pos.tp = new_tp
        return True

    def apply_initial_sl_tp(self, pos: SimPosition, atr: float, bid: float, ask: float) -> bool:
        new_sl = pos.sl
        new_tp = pos.tp
        needs_modify = False

        sl_dist = self.initial_sl_pips * self.pip_size
        if self.use_atr_for_sl:
            sl_dist = max(sl_dist, atr * self.atr_mult_sl)

        tp_dist = self.initial_tp_pips * self.pip_size
        if self.use_atr_for_tp:
            tp_dist = max(tp_dist, atr * self.atr_mult_tp)

        if pos.pos_type == "BUY":
            if pos.sl <= 0.0 and sl_dist > 0.0:
                new_sl = self.normalize_price(pos.entry_price - sl_dist)
                needs_modify = True
            if pos.tp <= 0.0 and tp_dist > 0.0:
                new_tp = self.normalize_price(pos.entry_price + tp_dist)
                needs_modify = True
        else:
            if pos.sl <= 0.0 and sl_dist > 0.0:
                new_sl = self.normalize_price(pos.entry_price + sl_dist)
                needs_modify = True
            if pos.tp <= 0.0 and tp_dist > 0.0:
                new_tp = self.normalize_price(pos.entry_price - tp_dist)
                needs_modify = True

        if not needs_modify:
            return False
        if not self.is_modify_safe(pos.pos_type, bid, ask, pos.sl, pos.tp, new_sl, new_tp):
            return False
        ok = self._modify(pos, new_sl, new_tp)
        if ok and pos.initial_tp == 0.0 and pos.tp > 0.0:
            pos.initial_tp = pos.tp
            pos.last_extended_tp = pos.tp
        return ok

    def apply_break_even(self, pos: SimPosition, bid: float, ask: float) -> bool:
        current_price = bid if pos.pos_type == "BUY" else ask
        profit_pips = (
            (current_price - pos.entry_price) / self.pip_size
            if pos.pos_type == "BUY"
            else (pos.entry_price - current_price) / self.pip_size
        )
        if profit_pips < self.break_even_pips or pos.break_even_set:
            return pos.break_even_set

        offset = self.break_even_offset * self.pip_size
        if pos.pos_type == "BUY":
            new_sl = self.normalize_price(pos.entry_price + offset)
            if pos.sl >= new_sl:
                pos.break_even_set = True
                return True
        else:
            new_sl = self.normalize_price(pos.entry_price - offset)
            if pos.sl != 0.0 and pos.sl <= new_sl:
                pos.break_even_set = True
                return True

        if not self.is_modify_safe(pos.pos_type, bid, ask, pos.sl, pos.tp, new_sl, pos.tp):
            return False
        if self._modify(pos, new_sl, pos.tp):
            pos.break_even_set = True
            return True
        return False

    def apply_trailing_sl(
        self, pos: SimPosition, atr: float, is_very_strong_trend: bool, bid: float, ask: float
    ) -> bool:
        current_price = bid if pos.pos_type == "BUY" else ask
        profit_pips = (
            (current_price - pos.entry_price) / self.pip_size
            if pos.pos_type == "BUY"
            else (pos.entry_price - current_price) / self.pip_size
        )
        if profit_pips < self.trailing_sl_start:
            return False

        trail_dist = self.trailing_sl_distance * self.pip_size
        if self.use_atr_for_sl:
            atr_dist = atr * self.atr_mult_sl
            if is_very_strong_trend:
                atr_dist *= 0.75
            trail_dist = max(trail_dist * 0.5, atr_dist)
        if trail_dist <= 0.0:
            return False

        min_step = self.trailing_sl_step * self.pip_size
        if pos.pos_type == "BUY":
            new_sl = self.normalize_price(current_price - trail_dist)
            if new_sl <= 0.0:
                return False
            if pos.sl != 0.0 and new_sl <= pos.sl:
                return False
            if pos.sl != 0.0 and (new_sl - pos.sl) < min_step:
                return False
        else:
            new_sl = self.normalize_price(current_price + trail_dist)
            if new_sl <= 0.0:
                return False
            if pos.sl != 0.0 and new_sl >= pos.sl:
                return False
            if pos.sl != 0.0 and (pos.sl - new_sl) < min_step:
                return False

        if not self.is_modify_safe(pos.pos_type, bid, ask, pos.sl, pos.tp, new_sl, pos.tp):
            return False
        return self._modify(pos, new_sl, pos.tp)

    def extend_tp(
        self, pos: SimPosition, atr: float, is_very_strong_trend: bool, bid: float, ask: float
    ) -> bool:
        current_price = bid if pos.pos_type == "BUY" else ask
        profit_pips = (
            (current_price - pos.entry_price) / self.pip_size
            if pos.pos_type == "BUY"
            else (pos.entry_price - current_price) / self.pip_size
        )
        if profit_pips < self.tp_extend_threshold:
            return False
        if pos.tp_extensions >= self.max_tp_extensions or pos.tp <= 0.0:
            return False

        extend_amt = self.tp_extend_amount * self.pip_size
        if self.use_atr_for_tp:
            atr_ext = atr * self.atr_mult_tp
            if is_very_strong_trend:
                atr_ext *= 1.5
            extend_amt = max(extend_amt, atr_ext)
        if extend_amt <= 0.0:
            return False

        if pos.pos_type == "BUY":
            if (pos.tp - current_price) > extend_amt * 0.5:
                return False
            new_tp = self.normalize_price(pos.tp + extend_amt)
        else:
            if (current_price - pos.tp) > extend_amt * 0.5:
                return False
            new_tp = self.normalize_price(pos.tp - extend_amt)
            if new_tp <= 0.0:
                return False

        if not self.is_modify_safe(pos.pos_type, bid, ask, pos.sl, pos.tp, pos.sl, new_tp):
            return False
        if self._modify(pos, pos.sl, new_tp):
            pos.tp_extensions += 1
            pos.last_extended_tp = new_tp
            return True
        return False


class TestMQ5StaticValidation(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = MQ5_PATH.read_text(encoding="utf-8")
        cls.cleaned = strip_mql_comments_and_strings(cls.source)
        cls.readme = README_PATH.read_text(encoding="utf-8")
        cls.inputs = parse_mq5_inputs(cls.source)

    def test_balanced_braces_and_parentheses(self) -> None:
        pairs = {"{": "}", "(": ")"}
        closing = {"}": "{", ")": "("}
        stack: list[str] = []
        for idx, ch in enumerate(self.cleaned):
            if ch in pairs:
                stack.append(ch)
            elif ch in closing:
                self.assertTrue(stack, f"Unmatched '{ch}' near char {idx}")
                top = stack.pop()
                self.assertEqual(
                    pairs[top], ch, f"Mismatched '{top}' and '{ch}' near char {idx}"
                )
        self.assertEqual(stack, [], f"Unclosed delimiters: {stack}")

    def test_properties_and_version(self) -> None:
        self.assertRegex(self.source, r'#property\s+strict\b')
        self.assertRegex(self.source, r'#property\s+version\s+"2\.00"')
        self.assertEqual(self.inputs.get("InpMaxTPExtensions"), "int")
        self.assertNotIn("positionInfo", self.cleaned)
        self.assertNotIn("pipValue", self.cleaned)

    def test_work_symbol_and_filling_autodetect(self) -> None:
        self.assertIn("workSymbol", self.cleaned)
        self.assertIn("SYMBOL_FILLING_MODE", self.cleaned)
        self.assertIn("SYMBOL_FILLING_FOK", self.cleaned)
        self.assertIn("SYMBOL_FILLING_IOC", self.cleaned)
        # InpSymbol should only be used inside OnInit to resolve workSymbol
        on_init_body = extract_function_body(self.source, "OnInit")
        self.assertIn("InpSymbol", on_init_body)
        without_inputs_and_oninit = self.cleaned.replace(on_init_body, "")
        self.assertNotRegex(without_inputs_and_oninit, r"(?<!input string   )InpSymbol\b")

    def test_dashboard_wired_and_cleaned_up(self) -> None:
        process_body = extract_function_body(self.source, "ProcessPositions")
        self.assertIn("DisplayDashboard()", process_body)
        deinit_body = extract_function_body(self.source, "OnDeinit")
        self.assertIn("ObjectsDeleteAll", deinit_body)
        deinit_raw = self.source[self.source.index("void OnDeinit"):self.source.index("void OnTimer")]
        self.assertIn('ObjectsDeleteAll(0, "TTPSL_")', deinit_raw)
        dashboard_raw = self.source[self.source.index("void DisplayDashboard"):self.source.index("void CreateLabel")]
        self.assertIn('"TTPSL_"', dashboard_raw)

    def test_break_even_returns_bool_and_checked_at_callsite(self) -> None:
        self.assertRegex(self.cleaned, r"\bbool\s+ApplyBreakEven\s*\(")
        single_pos_body = extract_function_body(self.source, "ProcessSinglePosition")
        self.assertRegex(
            single_pos_body,
            r"if\s*\(\s*ApplyBreakEven\s*\([^)]*\)\s*\)",
        )

    def test_buy_trailing_sl_allows_zero_sl(self) -> None:
        trail_body = extract_function_body(self.source, "ApplyTrailingStopLoss")
        self.assertNotIn("currentSL == 0 || newSL <= currentSL", trail_body)
        self.assertNotIn("currentSL == 0.0 || newSL <= currentSL", trail_body)
        self.assertRegex(trail_body, r"currentSL\s*!=\s*0(?:\.0)?\s*&&\s*newSL\s*<=\s*currentSL")
        self.assertRegex(
            trail_body,
            r"currentSL\s*!=\s*0(?:\.0)?\s*&&\s*\(\s*newSL\s*-\s*currentSL\s*\)\s*<\s*minStep",
        )

    def test_stops_freeze_ticksize_and_persistence_exist(self) -> None:
        for symbol in (
            "SYMBOL_TRADE_STOPS_LEVEL",
            "SYMBOL_TRADE_FREEZE_LEVEL",
            "SYMBOL_TRADE_TICK_SIZE",
            "NormalizePrice",
            "GetMinStopDistance",
            "IsModifySafe",
            "TERMINAL_TRADE_ALLOWED",
            "MQL_TRADE_ALLOWED",
            "ACCOUNT_TRADE_ALLOWED",
            "GlobalVariableSet",
            "GlobalVariableGet",
            "GlobalVariableDel",
            "lastExtendedTP",
            "ResultRetcode",
            "ResultRetcodeDescription",
        ):
            self.assertIn(symbol, self.cleaned, f"Missing expected symbol: {symbol}")

    def test_every_input_documented_in_readme(self) -> None:
        self.assertGreaterEqual(len(self.inputs), 25)
        for name in self.inputs:
            self.assertIn(name, self.readme, f"Input {name} missing from README.md")

    def test_presets_match_mq5_inputs(self) -> None:
        expected_presets = {
            "XAGUSD_Default.set",
            "XAGUSD_Conservative.set",
            "XAGUSD_Aggressive.set",
        }
        actual_presets = {p.name for p in PRESETS_DIR.glob("*.set")}
        self.assertEqual(actual_presets, expected_presets)

        for preset_path in sorted(PRESETS_DIR.glob("*.set")):
            keys_seen: set[str] = set()
            for lineno, raw_line in enumerate(
                preset_path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                line = raw_line.strip()
                if not line or line.startswith((";", "#")):
                    continue
                self.assertIn("=", line, f"{preset_path.name}:{lineno} missing '='")
                key, val = line.split("=", 1)
                val = val.split("||", 1)[0].strip()
                self.assertIn(
                    key,
                    self.inputs,
                    f"{preset_path.name}:{lineno} unknown input '{key}'",
                )
                keys_seen.add(key)

                typ = self.inputs[key]
                if typ == "bool":
                    self.assertIn(val.lower(), {"true", "false", "0", "1"})
                elif typ == "int":
                    int(val)
                elif typ == "double":
                    self.assertTrue(math.isfinite(float(val)))

            self.assertEqual(
                keys_seen,
                set(self.inputs.keys()),
                f"{preset_path.name} should define all EA inputs",
            )


class TestReferenceSimulation(unittest.TestCase):
    def test_initial_sl_tp_buy_and_sell(self) -> None:
        ea = ReferenceEA(use_atr_for_sl=True, use_atr_for_tp=True)
        # 50 pips = 0.50, ATR*1.5 = 0.60 -> 0.60 wins
        # 100 pips = 1.00, ATR*2.5 = 1.00 -> 1.00
        buy = SimPosition(ticket=1, pos_type="BUY", entry_price=30.000)
        self.assertTrue(ea.apply_initial_sl_tp(buy, atr=0.40, bid=30.010, ask=30.030))
        self.assertEqual(buy.sl, 29.400)
        self.assertEqual(buy.tp, 31.000)
        self.assertEqual(buy.initial_tp, 31.000)

        # Already set SL/TP should not be overwritten
        self.assertFalse(ea.apply_initial_sl_tp(buy, atr=0.40, bid=30.010, ask=30.030))

        sell = SimPosition(ticket=2, pos_type="SELL", entry_price=30.000)
        self.assertTrue(ea.apply_initial_sl_tp(sell, atr=0.40, bid=29.970, ask=29.990))
        self.assertEqual(sell.sl, 30.600)
        self.assertEqual(sell.tp, 29.000)

    def test_break_even_retries_on_failure_then_succeeds(self) -> None:
        ea = ReferenceEA(break_even_pips=30.0, break_even_offset=2.0)
        pos = SimPosition(ticket=10, pos_type="BUY", entry_price=30.000, sl=29.500, tp=31.000)

        # Simulate broker modify failure: break_even_set MUST stay False
        ea.modify_should_succeed = False
        self.assertFalse(ea.apply_break_even(pos, bid=30.350, ask=30.370))
        self.assertFalse(pos.break_even_set)
        self.assertEqual(pos.sl, 29.500)

        # Next tick succeeds -> break_even_set becomes True at entry + 2 pips (0.02)
        ea.modify_should_succeed = True
        self.assertTrue(ea.apply_break_even(pos, bid=30.350, ask=30.370))
        self.assertTrue(pos.break_even_set)
        self.assertEqual(pos.sl, 30.020)

        # SELL already past breakeven -> returns True without modifying
        sell = SimPosition(ticket=11, pos_type="SELL", entry_price=30.000, sl=29.950, tp=29.000)
        calls_before = len(ea.modify_calls)
        self.assertTrue(ea.apply_break_even(sell, bid=29.600, ask=29.620))
        self.assertTrue(sell.break_even_set)
        self.assertEqual(len(ea.modify_calls), calls_before)

    def test_buy_trailing_sl_works_from_zero_sl_and_enforces_step(self) -> None:
        ea = ReferenceEA(
            trailing_sl_start=20.0,
            trailing_sl_distance=15.0,
            trailing_sl_step=5.0,
            use_atr_for_sl=False,
        )
        # BUY with SL=0.0 at +25 pips profit (30.250): should set SL to 30.250 - 0.150 = 30.100
        buy = SimPosition(ticket=20, pos_type="BUY", entry_price=30.000, sl=0.0)
        self.assertTrue(ea.apply_trailing_sl(buy, atr=0.10, is_very_strong_trend=False, bid=30.250, ask=30.270))
        self.assertEqual(buy.sl, 30.100)

        # +3 pips move (30.280 -> new_sl=30.130, delta=0.03 < 0.05 step): blocked
        self.assertFalse(ea.apply_trailing_sl(buy, atr=0.10, is_very_strong_trend=False, bid=30.280, ask=30.300))
        self.assertEqual(buy.sl, 30.100)

        # +6 pips move (30.310 -> new_sl=30.160, delta=0.06 >= 0.05 step): updated
        self.assertTrue(ea.apply_trailing_sl(buy, atr=0.10, is_very_strong_trend=False, bid=30.310, ask=30.330))
        self.assertEqual(buy.sl, 30.160)

        # Price retraces: never moves SL downward
        self.assertFalse(ea.apply_trailing_sl(buy, atr=0.10, is_very_strong_trend=False, bid=30.220, ask=30.240))
        self.assertEqual(buy.sl, 30.160)

    def test_stops_and_freeze_level_validation(self) -> None:
        # 50 points = 0.050 minimum stop distance; freeze_level = 20 points = 0.020
        spec = SymbolSpec(digits=3, point=0.001, tick_size=0.001, stops_level=50, freeze_level=20)
        ea = ReferenceEA(
            spec=spec,
            trailing_sl_start=10.0,
            trailing_sl_distance=3.0,  # 0.030 < 0.050 min_stop_dist -> must be rejected
            trailing_sl_step=1.0,
            use_atr_for_sl=False,
        )
        buy = SimPosition(ticket=30, pos_type="BUY", entry_price=30.000, sl=0.0, tp=31.000)
        self.assertFalse(ea.apply_trailing_sl(buy, atr=0.02, is_very_strong_trend=False, bid=30.200, ask=30.220))
        self.assertEqual(buy.sl, 0.0)

        # Existing SL within freeze distance (|30.200 - 30.185| = 0.015 <= 0.020) blocks TP modification
        frozen_buy = SimPosition(ticket=31, pos_type="BUY", entry_price=30.000, sl=30.185, tp=30.260)
        self.assertFalse(ea.extend_tp(frozen_buy, atr=0.05, is_very_strong_trend=False, bid=30.200, ask=30.220))

    def test_tp_extension_cap_and_immutable_initial_tp(self) -> None:
        ea = ReferenceEA(
            tp_extend_threshold=30.0,
            tp_extend_amount=20.0,
            max_tp_extensions=2,
            use_atr_for_tp=False,
        )
        buy = SimPosition(
            ticket=40,
            pos_type="BUY",
            entry_price=30.000,
            sl=30.020,
            tp=30.500,
            initial_tp=30.500,
            last_extended_tp=30.500,
        )
        # Price at 30.420 (0.080 away <= 0.5 * 0.200 = 0.100): extends #1 to 30.700
        self.assertTrue(ea.extend_tp(buy, atr=0.10, is_very_strong_trend=False, bid=30.420, ask=30.440))
        self.assertEqual(buy.tp, 30.700)
        self.assertEqual(buy.tp_extensions, 1)
        self.assertEqual(buy.initial_tp, 30.500)
        self.assertEqual(buy.last_extended_tp, 30.700)

        # Price at 30.650: extends #2 to 30.900
        self.assertTrue(ea.extend_tp(buy, atr=0.10, is_very_strong_trend=False, bid=30.650, ask=30.670))
        self.assertEqual(buy.tp, 30.900)
        self.assertEqual(buy.tp_extensions, 2)
        self.assertEqual(buy.initial_tp, 30.500)

        # Price at 30.880: capped at max_tp_extensions=2
        self.assertFalse(ea.extend_tp(buy, atr=0.10, is_very_strong_trend=False, bid=30.880, ask=30.900))
        self.assertEqual(buy.tp, 30.900)
        self.assertEqual(buy.tp_extensions, 2)

    def test_spread_filter_and_permissions(self) -> None:
        ea = ReferenceEA(max_spread_pips=4.0)
        pos = SimPosition(ticket=50, pos_type="BUY", entry_price=30.000, sl=29.500, tp=31.000)

        # Spread = 0.060 / 0.01 = 6.0 pips > 4.0 -> blocked
        self.assertFalse(ea.apply_break_even(pos, bid=30.400, ask=30.460))
        self.assertFalse(pos.break_even_set)

        # Spread = 0.030 / 0.01 = 3.0 pips <= 4.0 -> allowed
        self.assertTrue(ea.apply_break_even(pos, bid=30.400, ask=30.430))
        self.assertTrue(pos.break_even_set)

        # Disabled trading permission blocks modify
        ea_disabled = ReferenceEA(perms=Permissions(account_allowed=False))
        sell = SimPosition(ticket=51, pos_type="SELL", entry_price=30.000, sl=0.0, tp=0.0)
        self.assertFalse(ea_disabled.apply_initial_sl_tp(sell, atr=0.10, bid=29.980, ask=30.000))


if __name__ == "__main__":
    unittest.main()
