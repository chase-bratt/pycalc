import json
import math
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Resources"))

import kernel

KERNEL_PATH = os.path.join(os.path.dirname(__file__), "..", "Resources", "kernel.py")


def run(code):
    return kernel.Kernel().run({"op": "run", "id": 1, "code": code})


class TestRun:
    def test_last_expression_is_the_value(self):
        result = run("a = 2\na * 21")
        assert result["ok"] is True
        assert result["value"] == "42"

    def test_print_is_captured(self):
        result = run("print('hi')\nprint(1 + 1)")
        assert result["stdout"] == "hi\n2\n"
        assert result["value"] is None

    def test_math_is_preloaded(self):
        assert run("sqrt(16) + floor(pi)")["value"] == "7.0"

    def test_none_value_is_hidden(self):
        assert run("None")["value"] is None

    def test_runtime_error_reports_user_line(self):
        result = run("x = 1\ny = x / 0\n")
        assert result["ok"] is False
        assert result["error"]["type"] == "ZeroDivisionError"
        assert result["error"]["line"] == 2
        assert "y = x / 0" in result["error"]["traceback"]

    def test_syntax_error_reports_line(self):
        result = run("x = 1\nif x\n  pass")
        assert result["error"]["type"] == "SyntaxError"
        assert result["error"]["line"] == 2

    def test_output_before_error_is_kept(self):
        result = run("print('before')\nraise ValueError('boom')")
        assert result["stdout"] == "before\n"
        assert result["error"]["message"] == "boom"

    def test_input_is_rejected(self):
        result = run("input('n?')")
        assert result["error"]["type"] == "RuntimeError"

    def test_namespace_is_fresh_each_run(self):
        k = kernel.Kernel()
        k.run({"id": 1, "code": "secret = 1"})
        result = k.run({"id": 2, "code": "secret"})
        assert result["error"]["type"] == "NameError"

    def test_system_exit_is_contained(self):
        assert run("raise SystemExit(3)")["error"]["type"] == "SystemExit"

    def test_long_output_is_truncated(self):
        result = run("print('x' * 300000)")
        assert result["stdout"].endswith("output truncated")


class TestPlots:
    def test_function_plot_registers_item(self):
        result = run("plot(lambda x: x**2)\nplot('sin(x)', color='#fff', label='wave')")
        kinds = [(p["kind"], p["label"]) for p in result["plots"]]
        assert kinds == [("function", None), ("function", "wave")]
        assert result["plots"][1]["color"] == "#fff"

    def test_named_function_gets_label(self):
        result = run("def f(x):\n    return x\nplot(f)")
        assert result["plots"][0]["label"] == "f(x)"

    def test_constant_plot(self):
        assert run("plot(3)")["plots"][0]["label"] == "y = 3"

    def test_colors_cycle_through_palette(self):
        result = run("plot(1, 2)")
        assert [p["color"] for p in result["plots"]] == kernel.PALETTE[:2]

    def test_invalid_plot_argument_is_an_error(self):
        assert run("plot(object())")["error"]["type"] == "PlotError"

    def test_scatter_pairs_and_lists(self):
        result = run("scatter([1, 2], [3, 4])\nscatter([(5, 6)])")
        assert result["plots"][0]["points"] == [[1.0, 3.0], [2.0, 4.0]]
        assert result["plots"][1]["points"] == [[5.0, 6.0]]

    def test_scatter_length_mismatch(self):
        assert run("scatter([1], [1, 2])")["error"]["type"] == "PlotError"

    def test_parametric_circle(self):
        result = run("parametric(cos, sin, samples=5)")
        points = result["plots"][0]["points"]
        assert len(points) == 5
        assert points[0] == pytest.approx([1.0, 0.0])

    def test_polar_string_uses_theta(self):
        result = run("polar('2', samples=3)")
        assert result["plots"][0]["points"][0] == pytest.approx([2.0, 0.0])

    def test_vline_and_window(self):
        result = run("vline(2)\nwindow(-1, 1, -2, 2)")
        assert result["plots"][0]["x"] == 2.0
        assert result["window"] == [-1.0, 1.0, -2.0, 2.0]

    def test_bad_window(self):
        assert run("window(1, 0, 0, 1)")["error"]["type"] == "PlotError"


class TestCalculatorFeatures:
    def test_ans_carries_previous_result(self):
        k = kernel.Kernel()
        assert k.run({"id": 1, "code": "ans"})["value"] is None
        k.run({"id": 2, "code": "6 * 7"})
        assert k.run({"id": 3, "code": "ans + 1"})["value"] == "43"

    def test_ans_survives_failed_run(self):
        k = kernel.Kernel()
        k.run({"id": 1, "code": "5"})
        k.run({"id": 2, "code": "1/0"})
        assert k.run({"id": 3, "code": "ans"})["value"] == "5"

    def test_annotations_cover_expressions_and_assignments(self):
        result = run("x = 2\nx + 1\nprint('hi')\nf = lambda t: t\ny = [1,\n  2]\nx * 10")
        assert result["annotations"] == {"1": "2", "2": "3", "6": "[1, 2]", "7": "20"}

    def test_annotations_ignore_nested_statements(self):
        assert run("for i in range(3):\n    i")["annotations"] == {}

    def test_degrees_mode(self):
        k = kernel.Kernel()
        assert k.run({"id": 1, "code": "round(sin(30), 9)", "angle": "deg"})["value"] == "0.5"
        assert k.run({"id": 2, "code": "round(degrees(asin(0.5)), 6)", "angle": "rad"})["value"] == "30.0"
        assert k.run({"id": 3, "code": "round(atan2(1, 1), 9)", "angle": "deg"})["value"] == "45.0"

    def test_variables_exclude_builtins_and_callables(self):
        result = run("import os\nr = 2\narea = pi * r**2\ndef f(x):\n    return x\n_hidden = 1")
        names = [name for name, _ in result["variables"]]
        assert names == ["r", "area"]

    @pytest.mark.parametrize(
        "value,label,text",
        [
            (1234567, "grouped", "1,234,567"),
            (255, "hex", "0xff"),
            (0.75, "fraction", "3/4"),
            (math.pi / 2, "π multiple", "π/2"),
            (-2 * math.pi, "π multiple", "-2π"),
            (complex(0, 2), "polar", "2 ∠ 90°"),
            (0.000125, "scientific", "1.250000e-04"),
        ],
    )
    def test_alternate_forms(self, value, label, text):
        forms = {f["label"]: f["text"] for f in kernel.alternate_forms(value)}
        assert forms[label] == text

    def test_ordinary_floats_skip_scientific(self):
        assert "scientific" not in {f["label"] for f in kernel.alternate_forms(59.37)}

    def test_no_alternates_for_bool_or_text(self):
        assert kernel.alternate_forms(True) == []
        assert kernel.alternate_forms("x") == []


class TestRobustness:
    def test_non_string_label_is_stringified(self):
        assert run("plot(1, label=5)")["plots"][0]["label"] == "5"

    def test_infinite_window_is_rejected(self):
        assert run("window(0, float('inf'), -1, 1)")["error"]["type"] == "PlotError"

    def test_broken_repr_and_str(self):
        code = "class B:\n    def __repr__(self):\n        raise ValueError\nB()"
        assert run(code)["value"].startswith("<unrepresentable B")
        code = "class E(Exception):\n    def __str__(self):\n        raise ValueError\nraise E()"
        assert run(code)["error"]["message"] == "<unprintable exception>"

    def test_reply_size_is_bounded(self):
        assert len(run("plot(1, label='x' * 10000)")["plots"][0]["label"]) == kernel.MAX_LABEL_CHARS
        assert run("for i in range(600):\n    plot(i)")["error"]["type"] == "PlotError"
        assert run("for i in range(20):\n    scatter([(j, j) for j in range(15000)])")["error"]["type"] == "PlotError"
        message = run("raise ValueError('m' * 50000)")["error"]["message"]
        assert len(message) == kernel.MAX_ERROR_CHARS

    def test_sigint_outside_user_code_is_ignored(self):
        kernel._on_sigint(2, None)  # must not raise while idle


class TestSample:
    def test_sample_evaluates_functions(self):
        k = kernel.Kernel()
        k.run({"id": 1, "code": "plot(lambda x: x * 2)"})
        reply = k.sample({"id": 2, "xmin": 0, "xmax": 1, "n": 3})
        assert reply["series"]["p1"] == [0.0, 1.0, 2.0]

    def test_invalid_points_become_none(self):
        k = kernel.Kernel()
        k.run({"id": 1, "code": "plot('log(x)')\nplot('1/x')"})
        reply = k.sample({"id": 2, "xmin": -1, "xmax": 1, "n": 3, "ids": ["p1", "p2"]})
        assert reply["series"]["p1"] == [None, None, 0.0]
        assert reply["series"]["p2"] == [-1.0, None, 1.0]

    def test_sample_uses_script_namespace(self):
        k = kernel.Kernel()
        k.run({"id": 1, "code": "a = 3\nplot('a * x')"})
        assert k.sample({"id": 2, "xmin": 1, "xmax": 2, "n": 2})["series"]["p1"] == [
            3.0,
            6.0,
        ]

    def test_sample_count_is_capped(self):
        k = kernel.Kernel()
        k.run({"id": 1, "code": "plot(0)"})
        assert k.sample({"id": 2, "xmin": 0, "xmax": 1, "n": 10**9})["n"] == kernel.MAX_SAMPLES

    def test_bad_range_is_error(self):
        assert kernel.Kernel().sample({"id": 1, "xmin": 2, "xmax": 1, "n": 3})["op"] == "error"


class TestToReal:
    @pytest.mark.parametrize(
        "value,expected",
        [
            (1, 1.0),
            (True, 1.0),
            (complex(2, 0), 2.0),
            (complex(0, 1), None),
            (math.inf, None),
            (math.nan, None),
            ("x", None),
        ],
    )
    def test_conversion(self, value, expected):
        assert kernel.to_real(value) == expected


def test_handle_unknown_op():
    assert kernel.Kernel().handle({"op": "nope", "id": 9})["op"] == "error"


def test_process_protocol_round_trip():
    proc = subprocess.Popen(
        [sys.executable, KERNEL_PATH],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert json.loads(proc.stdout.readline())["op"] == "ready"
        code = "import os\nos.write(1, b'stray')\nprint('ok')\n6 * 7"
        proc.stdin.write(json.dumps({"op": "run", "id": 1, "code": code}) + "\n")
        proc.stdin.flush()
        reply = json.loads(proc.stdout.readline())
        assert reply["value"] == "42"
        assert reply["stdout"] == "ok\n"
        proc.stdin.write("not json\n")
        proc.stdin.flush()
        assert json.loads(proc.stdout.readline())["op"] == "error"
        proc.stdin.write(json.dumps({"op": "sample", "id": 7, "xmin": "a", "xmax": 1, "n": 2}) + "\n")
        proc.stdin.flush()
        assert json.loads(proc.stdout.readline())["id"] == 7
    finally:
        proc.stdin.close()
        proc.wait(timeout=5)
