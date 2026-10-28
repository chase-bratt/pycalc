"""PyCalc kernel.

Runs editor scripts in a fresh namespace and keeps that namespace alive so the
graph can re-sample plotted functions whenever the viewport changes.

Protocol: one JSON object per line on stdin, one JSON reply per line on the
protocol channel (a private duplicate of the original stdout). Anything user
code writes to file descriptor 1 is redirected to stderr so it can never
corrupt the protocol stream.

Compatible with Python 3.9+.
"""

import ast
import builtins
import cmath
import fractions
import io
import json
import math
import os
import signal
import sys
import time
import traceback
from contextlib import contextmanager, redirect_stderr, redirect_stdout

FILENAME = "<script>"
PALETTE = ["#C4AEF4", "#DCCE40", "#F2A7C3", "#7EE0C3", "#8EC7FF", "#FF9E8A"]
MAX_SAMPLES = 8000
MAX_STATIC_POINTS = 20000
MAX_OUTPUT_CHARS = 200_000
MAX_VALUE_CHARS = 20_000
MAX_ANNOTATION_CHARS = 80
MAX_VARIABLES = 60
MAX_PLOT_ITEMS = 500
MAX_TOTAL_POINTS = 200_000
MAX_LABEL_CHARS = 200
MAX_ERROR_CHARS = 20_000
RECORDER = "__pycalc_record__"

try:  # numpy is optional; exposed as `np` when installed.
    import numpy as _np
except Exception:  # pragma: no cover - depends on environment
    _np = None


class PlotError(ValueError):
    """Raised for invalid arguments to the plotting helpers."""


class Registry:
    """Everything a single script run asked the graph to draw."""

    def __init__(self):
        self.items = []
        self.total_points = 0
        self.functions = {}
        self.window = None

    def _next_id(self):
        return f"p{len(self.items) + 1}"

    def _color(self, color):
        if color is not None:
            return _clip(str(color), 32)
        return PALETTE[len(self.items) % len(PALETTE)]

    def add(self, kind, color, label, **fields):
        # Keep replies bounded no matter how many plots a script makes.
        if len(self.items) >= MAX_PLOT_ITEMS:
            raise PlotError(f"too many plots (limit {MAX_PLOT_ITEMS})")
        points = len(fields.get("points") or [])
        if self.total_points + points > MAX_TOTAL_POINTS:
            raise PlotError(f"too many plotted points in total (limit {MAX_TOTAL_POINTS})")
        self.total_points += points
        item = {
            "id": self._next_id(),
            "kind": kind,
            "color": self._color(color),
            "label": None if label is None else _clip(str(label), MAX_LABEL_CHARS),
        }
        item.update(fields)
        self.items.append(item)
        return item


def _clip(text, limit):
    return text if len(text) <= limit else text[: limit - 1] + "…"


def to_real(value):
    """Convert a numeric result to a finite float, or None if not plottable."""
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, complex):
        if abs(value.imag) > 1e-12 * max(1.0, abs(value.real)):
            return None
        value = value.real
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if math.isnan(number) or math.isinf(number):
        return None
    return number


def _expression_function(expr, namespace, var):
    try:
        code = compile(expr, "<plot>", "eval")
    except SyntaxError as exc:
        raise PlotError(f"invalid expression {expr!r}: {exc.msg}")

    def evaluate(value):
        return eval(code, namespace, {var: value})

    return evaluate


def _as_function(spec, namespace, var="x"):
    """Return (callable, default_label) for a plot specification."""
    if isinstance(spec, str):
        return _expression_function(spec, namespace, var), f"y = {spec.strip()}"
    if callable(spec):
        name = getattr(spec, "__name__", "f")
        label = f"{name}({var})" if name != "<lambda>" else None
        return spec, label
    constant = to_real(spec)
    if constant is not None:
        return (lambda _x, c=constant: c), f"y = {_fmt(constant)}"
    raise PlotError(f"cannot plot {spec!r}: pass a function, an expression string or a number")


def _fmt(number):
    text = f"{number:.6g}"
    return text


def _range(bounds, name):
    try:
        lo, hi = float(bounds[0]), float(bounds[1])
    except (TypeError, ValueError, IndexError):
        raise PlotError(f"{name} must be a (start, end) pair")
    if not (math.isfinite(lo) and math.isfinite(hi)):
        raise PlotError(f"{name} must be finite")
    if not lo < hi:
        raise PlotError(f"{name} start must be less than end")
    return lo, hi


def _linspace(lo, hi, n):
    if n < 2:
        return [lo]
    step = (hi - lo) / (n - 1)
    return [lo + i * step for i in range(n)]


def _safe_call(func, value):
    try:
        return to_real(func(value))
    except Exception:
        return None


def _pairs(xs, ys):
    if ys is None:
        points = list(xs)
        try:
            return [(to_real(p[0]), to_real(p[1])) for p in points]
        except (TypeError, IndexError):
            raise PlotError("points must be (x, y) pairs, or pass xs and ys separately")
    xs, ys = list(xs), list(ys)
    if len(xs) != len(ys):
        raise PlotError(f"xs and ys must have the same length ({len(xs)} != {len(ys)})")
    return [(to_real(x), to_real(y)) for x, y in zip(xs, ys)]


def _finite_points(pairs):
    points = [[x, y] for x, y in pairs if x is not None and y is not None]
    if len(points) > MAX_STATIC_POINTS:
        raise PlotError(f"too many points ({len(points)} > {MAX_STATIC_POINTS})")
    return points


def make_plot_api(registry, namespace):
    """Build the plotting helpers injected into each script's namespace."""

    def plot(*specs, color=None, label=None):
        """plot(f, g, ...) — graph functions of x. Accepts callables, "x**2" strings or numbers."""
        if not specs:
            raise PlotError("plot() needs at least one function")
        for spec in specs:
            items = spec if isinstance(spec, (list, tuple)) else [spec]
            for single in items:
                func, default_label = _as_function(single, namespace)
                item = registry.add("function", color, label or default_label)
                registry.functions[item["id"]] = func

    def scatter(xs, ys=None, color=None, label=None):
        """scatter(xs, ys) or scatter([(x, y), ...]) — plot discrete points."""
        registry.add("points", color, label, points=_finite_points(_pairs(xs, ys)))

    def line(xs, ys=None, color=None, label=None):
        """line(xs, ys) or line([(x, y), ...]) — connect points with straight segments."""
        registry.add("curve", color, label, points=_finite_points(_pairs(xs, ys)))

    def point(x, y, label=None, color=None):
        """point(x, y) — mark a single labelled point."""
        coords = (to_real(x), to_real(y))
        if None in coords:
            raise PlotError("point() needs finite real coordinates")
        registry.add("points", color, label, points=[list(coords)])

    def parametric(fx, fy, t=(0, 2 * math.pi), samples=1500, color=None, label=None):
        """parametric(fx, fy, t=(start, end)) — curve (fx(t), fy(t))."""
        lo, hi = _range(t, "t")
        gx, _ = _as_function(fx, namespace, "t")
        gy, _ = _as_function(fy, namespace, "t")
        n = max(2, min(int(samples), MAX_STATIC_POINTS))
        pairs = [(_safe_call(gx, v), _safe_call(gy, v)) for v in _linspace(lo, hi, n)]
        registry.add(
            "curve",
            color,
            label,
            points=[[x, y] if x is not None and y is not None else None for x, y in pairs],
        )

    def polar(r, theta=(0, 2 * math.pi), samples=1500, color=None, label=None):
        """polar(r, theta=(start, end)) — curve r(θ); strings use the variable `theta`."""
        lo, hi = _range(theta, "theta")
        gr, _ = _as_function(r, namespace, "theta")
        n = max(2, min(int(samples), MAX_STATIC_POINTS))
        points = []
        for angle in _linspace(lo, hi, n):
            radius = _safe_call(gr, angle)
            points.append(None if radius is None else [radius * math.cos(angle), radius * math.sin(angle)])
        registry.add("curve", color, label, points=points)

    def vline(x, color=None, label=None):
        """vline(x) — vertical line at x."""
        value = to_real(x)
        if value is None:
            raise PlotError("vline() needs a finite real x")
        registry.add("vline", color, label or f"x = {_fmt(value)}", x=value)

    def window(xmin, xmax, ymin, ymax):
        """window(xmin, xmax, ymin, ymax) — set the initial graph viewport."""
        lo_x, hi_x = _range((xmin, xmax), "x range")
        lo_y, hi_y = _range((ymin, ymax), "y range")
        registry.window = [lo_x, hi_x, lo_y, hi_y]

    return {
        "plot": plot,
        "scatter": scatter,
        "line": line,
        "point": point,
        "parametric": parametric,
        "polar": polar,
        "vline": vline,
        "window": window,
    }


def _no_input(*_args, **_kwargs):
    raise RuntimeError("input() is not available in PyCalc — assign the value in your script instead")


def _degree_functions():
    """Trig functions that take and return degrees, for the DEG angle mode."""

    def wrap_in(func):
        def wrapper(x):
            return func(math.radians(x))

        wrapper.__name__ = func.__name__
        return wrapper

    def wrap_out(func):
        def wrapper(*args):
            return math.degrees(func(*args))

        wrapper.__name__ = func.__name__
        return wrapper

    funcs = {name: wrap_in(getattr(math, name)) for name in ("sin", "cos", "tan")}
    funcs.update({name: wrap_out(getattr(math, name)) for name in ("asin", "acos", "atan", "atan2")})
    return funcs


def make_namespace(registry, angle="rad", ans=None):
    namespace = {"__name__": "__main__", "__builtins__": builtins}
    exec("from math import *", namespace)
    namespace["math"] = math
    namespace["cmath"] = cmath
    if _np is not None:
        namespace["np"] = _np
    namespace["input"] = _no_input
    namespace["ans"] = ans
    if angle == "deg":
        namespace.update(_degree_functions())
    namespace.update(make_plot_api(registry, namespace))
    return namespace


def _short_repr(value, limit=MAX_ANNOTATION_CHARS):
    text = format_value(value).replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _instrument(tree):
    """Record the value of every top-level bare expression and simple assignment.

    Returns the tree with recorder calls inserted, so each line's result can be
    shown beside it in the editor.
    """
    body = []
    for node in tree.body:
        end = getattr(node, "end_lineno", node.lineno)
        if isinstance(node, ast.Expr):
            call = ast.Call(ast.Name(RECORDER, ast.Load()), [ast.Constant(end), node.value], [])
            body.append(ast.copy_location(ast.Expr(call), node))
            continue
        body.append(node)
        targets = []
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            targets = [node.targets[0]]
        elif isinstance(node, (ast.AugAssign, ast.AnnAssign)) and getattr(node, "value", None) is not None:
            targets = [node.target]
        if targets and isinstance(targets[0], ast.Name):
            name = ast.Name(targets[0].id, ast.Load())
            call = ast.Call(ast.Name(RECORDER, ast.Load()), [ast.Constant(end), name], [])
            body.append(ast.copy_location(ast.Expr(call), node))
    tree.body = body
    return ast.fix_missing_locations(tree)


def alternate_forms(value):
    """Other useful renderings of a numeric result (grouped, scientific, fraction, hex…)."""
    forms = []
    if isinstance(value, bool):
        return forms
    if isinstance(value, int):
        if abs(value) >= 1000:
            forms.append({"label": "grouped", "text": f"{value:,}"})
        if abs(value) >= 1e6:
            forms.append({"label": "scientific", "text": f"{value:.6e}"})
        if 0 <= value < 2**64:
            forms.append({"label": "hex", "text": hex(value)})
            if value < 2**16:
                forms.append({"label": "binary", "text": bin(value)})
    elif isinstance(value, float) and math.isfinite(value):
        if abs(value) >= 1000:
            forms.append({"label": "grouped", "text": f"{value:,.6f}".rstrip("0").rstrip(".")})
        if value != 0 and (abs(value) >= 1e6 or abs(value) < 1e-3):
            forms.append({"label": "scientific", "text": f"{value:.6e}"})
        approx = fractions.Fraction(value).limit_denominator(1000)
        if approx.denominator > 1 and abs(float(approx) - value) <= 1e-9 * max(1.0, abs(value)):
            forms.append({"label": "fraction", "text": f"{approx.numerator}/{approx.denominator}"})
        ratio = value / math.pi
        if value != 0 and abs(ratio - round(ratio * 12) / 12) < 1e-12 and abs(ratio) < 100:
            frac = fractions.Fraction(round(ratio * 12), 12)
            sign = "-" if frac < 0 else ""
            numerator = "π" if abs(frac.numerator) == 1 else f"{abs(frac.numerator)}π"
            denominator = "" if frac.denominator == 1 else f"/{frac.denominator}"
            forms.append({"label": "π multiple", "text": sign + numerator + denominator})
    elif isinstance(value, fractions.Fraction):
        forms.append({"label": "decimal", "text": repr(float(value))})
    elif isinstance(value, complex):
        forms.append({"label": "polar", "text": f"{abs(value):.6g} ∠ {math.degrees(cmath.phase(value)):.6g}°"})
    return forms


def collect_variables(namespace, baseline):
    """User-defined, non-callable names and their short reprs, in definition order."""
    found = []
    for name, value in namespace.items():
        if name.startswith("_") or (name in baseline and baseline[name] is value):
            continue
        if callable(value) or isinstance(value, type(math)):
            continue
        found.append([name, _short_repr(value, 120)])
        if len(found) >= MAX_VARIABLES:
            break
    return found


_interruptible = False


def _on_sigint(_signum, _frame):
    """Stop raises KeyboardInterrupt only inside user code, never mid-protocol."""
    if _interruptible:
        raise KeyboardInterrupt


@contextmanager
def _user_code():
    global _interruptible
    _interruptible = True
    try:
        yield
    finally:
        _interruptible = False


def _safe_str(obj, fallback):
    try:
        return str(obj)
    except Exception:
        return fallback


def format_value(value):
    try:
        text = repr(value)
    except Exception as exc:
        text = f"<unrepresentable {type(value).__name__}: {_safe_str(exc, '?')}>"
    if len(text) > MAX_VALUE_CHARS:
        text = text[:MAX_VALUE_CHARS] + " …"
    return text


def _error_from_exception(exc, source_lines):
    frames = [f for f in traceback.extract_tb(exc.__traceback__) if f.filename == FILENAME]
    line = frames[-1].lineno if frames else None
    lines = ["Traceback (most recent call last):"]
    for frame in frames:
        lines.append(f"  line {frame.lineno}, in {frame.name}")
        if frame.lineno and 0 < frame.lineno <= len(source_lines):
            lines.append("    " + source_lines[frame.lineno - 1].strip())
    try:
        lines.extend(part.rstrip("\n") for part in traceback.format_exception_only(type(exc), exc))
    except Exception:
        lines.append(f"{type(exc).__name__}: <unprintable exception>")
    return {
        "type": type(exc).__name__,
        "message": _clip(_safe_str(exc, "<unprintable exception>"), MAX_ERROR_CHARS),
        "line": line,
        "traceback": _clip("\n".join(lines), MAX_ERROR_CHARS),
    }


def _syntax_error(exc):
    detail = f"{type(exc).__name__}: {exc.msg}"
    text = (exc.text or "").rstrip("\n")
    report = [f"  line {exc.lineno}"]
    if text:
        report.append("    " + text.strip())
    report.append(detail)
    return {
        "type": type(exc).__name__,
        "message": exc.msg,
        "line": exc.lineno,
        "traceback": _clip("\n".join(report), MAX_ERROR_CHARS),
    }


class Kernel:
    def __init__(self):
        self.registry = Registry()
        self.run_id = None
        self.ans = None

    def run(self, request):
        code = request.get("code", "")
        self.registry = Registry()
        self.run_id = request.get("id")
        angle = "deg" if request.get("angle") == "deg" else "rad"
        namespace = make_namespace(self.registry, angle, self.ans)
        baseline = dict(namespace)
        annotations = {}

        def record(line, result):
            if result is not None and not callable(result) and not isinstance(result, type(math)):
                annotations[str(line)] = _short_repr(result)
            return result

        namespace[RECORDER] = record
        output = io.StringIO()
        value = None
        alternates = []
        error = None
        started = time.perf_counter()
        saved_stdin = sys.stdin
        try:
            tree = ast.parse(code, FILENAME, "exec")
            last_expr = None
            if tree.body and isinstance(tree.body[-1], ast.Expr):
                last = tree.body.pop()
                last_line = getattr(last, "end_lineno", last.lineno)
                last_expr = ast.Expression(last.value)
            tree = _instrument(tree)
            sys.stdin = io.StringIO("")
            with redirect_stdout(output), redirect_stderr(output):
                with _user_code():
                    exec(compile(tree, FILENAME, "exec"), namespace)
                    result = None if last_expr is None else eval(compile(last_expr, FILENAME, "eval"), namespace)
                if result is not None:
                    value = format_value(result)
                    alternates = alternate_forms(result)
                    annotations[str(last_line)] = _short_repr(result)
                    self.ans = result
        except SyntaxError as exc:
            error = _syntax_error(exc)
        except (Exception, KeyboardInterrupt, SystemExit) as exc:
            error = _error_from_exception(exc, code.splitlines())
            if isinstance(exc, KeyboardInterrupt):
                error["message"] = "Execution stopped"
        finally:
            sys.stdin = saved_stdin
        stdout = output.getvalue()
        if len(stdout) > MAX_OUTPUT_CHARS:
            stdout = stdout[:MAX_OUTPUT_CHARS] + "\n… output truncated"
        return {
            "op": "result",
            "id": request.get("id"),
            "ok": error is None,
            "stdout": stdout,
            "value": value,
            "error": error,
            "plots": self.registry.items,
            "window": self.registry.window,
            "annotations": annotations,
            "alternates": alternates,
            "variables": collect_variables(namespace, baseline),
            "duration_ms": round((time.perf_counter() - started) * 1000, 2),
        }

    def sample(self, request):
        try:
            xmin, xmax = _range((request["xmin"], request["xmax"]), "x range")
            n = max(2, min(int(request["n"]), MAX_SAMPLES))
        except (KeyError, TypeError, ValueError) as exc:
            return {"op": "error", "id": request.get("id"), "message": str(exc)}
        xs = _linspace(xmin, xmax, n)
        series = {}
        ids = request.get("ids") or list(self.registry.functions)
        sink = io.StringIO()
        with redirect_stdout(sink), redirect_stderr(sink):
            for plot_id in ids:
                func = self.registry.functions.get(plot_id)
                if func is not None:
                    series[plot_id] = [_safe_call(func, x) for x in xs]
        return {
            "op": "samples",
            "id": request.get("id"),
            "xmin": xmin,
            "xmax": xmax,
            "n": n,
            "series": series,
        }

    def handle(self, request):
        op = request.get("op")
        if op == "run":
            return self.run(request)
        if op == "sample":
            return self.sample(request)
        if op == "ping":
            return {"op": "pong", "id": request.get("id")}
        return {
            "op": "error",
            "id": request.get("id"),
            "message": f"unknown op {op!r}",
        }


def hello():
    return {
        "op": "ready",
        "python": sys.version.split()[0],
        "numpy": _np is not None,
        "executable": sys.executable,
    }


def main():
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)

    def send(message):
        protocol.write(json.dumps(message, allow_nan=False) + "\n")
        protocol.flush()

    signal.signal(signal.SIGINT, _on_sigint)
    kernel = Kernel()
    send(hello())
    while True:
        request_id = None
        try:
            line = sys.stdin.readline()
            if not line:
                break
            if not line.strip():
                continue
            request = json.loads(line)
            request_id = request.get("id") if isinstance(request, dict) else None
            reply = json.dumps(kernel.handle(request), allow_nan=False)
            protocol.write(reply + "\n")
            protocol.flush()
        except Exception as exc:  # keep the kernel alive and always answer the request
            send({"op": "error", "id": request_id, "message": f"kernel: {_safe_str(exc, type(exc).__name__)}"})


if __name__ == "__main__":
    main()
