"""CI check results."""

PASS, FAIL, SKIPPED = "pass", "fail", "skipped"

# CI providers report statuses in different words.
STATUS_ALIASES = {
    "pass": PASS, "passed": PASS, "success": PASS, "ok": PASS,
    "fail": FAIL, "failed": FAIL, "failure": FAIL, "error": FAIL,
    "skipped": SKIPPED, "skip": SKIPPED, "neutral": SKIPPED,
}

CHECK_NAMES = ("unit", "integration", "security", "perf")

REQUIRED, OPTIONAL = "required", "optional"


def normalize(raw):
    """Map provider statuses to pass/fail/skipped. Anything unknown counts as
    a failure, so a new status can never let a change through."""
    out = {}
    for name in CHECK_NAMES:
        status = str(raw.get(name, "")).strip().lower()
        out[name] = STATUS_ALIASES.get(status, FAIL)
    return out


def perf_requirement(tier):
    if tier == 1:
        return REQUIRED
    else:
        return OPTIONAL


def security_ok(results, tier):
    s = results["security"]
    if s == PASS:
        return True
    return s == SKIPPED and tier == 3


def perf_ok(results, tier):
    if perf_requirement(tier) == OPTIONAL:
        return True
    return results["perf"] == PASS


def all_green(results, tier):
    core = results["unit"] == PASS and results["integration"] == PASS
    return core and security_ok(results, tier) and perf_ok(results, tier)


def failing(results, tier):
    """Names of checks that block, for the status message."""
    out = [n for n in ("unit", "integration") if results[n] != PASS]
    if not security_ok(results, tier):
        out.append("security")
    if not perf_ok(results, tier):
        out.append("perf")
    return out
