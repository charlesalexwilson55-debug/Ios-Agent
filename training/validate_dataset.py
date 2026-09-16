"""Validate a generated Conduit SFT dataset.

Run after make_dataset.py and before spending money on a GPU. Training on a
malformed dataset is the most expensive mistake available here: it costs the
GPU hour, and the resulting model is worse than the base in ways that look
like bad luck rather than bad data.

Two classes of check:

**Structural** — the message sequence must be renderable by Qwen's chat
template. A tool result with no preceding tool call, or a tool call with no
result, produces a prompt shape the template either rejects or renders
incoherently, and the model learns from the wreckage.

**Behavioural** — the honesty invariant. Any turn whose tool result says
`awaiting_user_confirmation` must be followed by an assistant reply that does
NOT claim the thing was sent. This is the one property the whole app is built
around, and a handful of bad rows is enough to teach the opposite.

Usage:
    python training/validate_dataset.py
    python training/validate_dataset.py --data training/data/conduit_sft.jsonl
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import re
import sys
from pathlib import Path

# Phrases that assert a completed send. Matched case-insensitively against the
# assistant reply that follows a staged (awaiting-confirmation) tool result.
CLAIMS_COMPLETION = (
    "sent to", "i've sent", "ive sent", "i have sent", "i sent",
    "message sent", "email sent", "text sent", "has been sent",
    "already sent", "sent it",
)

# Wording that correctly conveys "staged, your turn".
CONVEYS_PENDING = ("tap send", "drafted", "draft", "ready to send", "when you're happy")

# A hand-off reply must not claim an outcome Conduit cannot see...
CLAIMS_HANDOFF_OUTCOME = (
    "it worked", "that worked", "it's done", "all done", "is now on", "is running now",
    "has run", "successfully", "should be going now", "is on now",
)
# ...but "I can't see whether it worked" is the correct reply, and a plain
# substring match flags it. A claim phrase preceded by one of these words is a
# question or a denial, not an assertion.
NEGATING_CONTEXT = ("whether", "if", "not", "can't tell", "cannot tell", "don't know")


def asserts(text: str, phrases: tuple[str, ...]) -> bool:
    """True when `text` asserts any phrase, ignoring negated or conditional uses."""
    lowered = text.lower()
    for phrase in phrases:
        start = 0
        while (position := lowered.find(phrase, start)) != -1:
            preceding = lowered[max(0, position - 24):position]
            if not any(re.search(rf"\b{re.escape(word)}\b", preceding)
                       for word in NEGATING_CONTEXT):
                return True
            start = position + len(phrase)
    return False
# ...and must not tell the user to send something that does not exist.
WRONG_FOR_HANDOFF = ("tap send",)

# A persona refusing ordinary work. The model on device said "I'm not a
# mathematician" when asked a sum; no training row may teach that.
ROLE_REFUSALS = (
    "not a mathematician", "as an ai", "as a language model", "don't have the capability",
    "do not have the capability", "i'm just a", "i am just a", "only here to help with",
    "i can only help with",
)

# Must mirror the word list in App/Agent/ToolPolicy.swift. A web search the
# user did not ask for throws them out to the browser.
SEARCH_WORDS = (
    "search", "google", "look up", "look it up", "lookup", "look online", "online",
    "the web", "internet", "browse", "browser", "safari", "duckduckgo", "bing", "website",
)

# Tools whose date arguments must not fall before "today".
DATED_ARGUMENTS = {
    "create_event": ("start",),
    "create_reminder": ("due",),
    "check_availability": ("start",),
    "schedule_notification": ("at",),
}


def load(path: Path) -> list[dict]:
    rows = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise SystemExit(f"{path}:{line_number}: not valid JSON: {error}")
    return rows


def check_dates(messages: list[dict], problems: collections.Counter) -> None:
    """The calendar the model is taught must be a real one.

    An earlier generator labelled 16 September 2026 a Tuesday (it is a
    Wednesday) and resolved "on Friday" to a Saturday. Both would train the
    model on wrong date arithmetic, which is the failure get_current_time
    exists to prevent, so they are checked for directly here.
    """
    today = None
    for message in messages:
        if message.get("role") != "tool":
            continue
        try:
            payload = json.loads(message.get("content", ""))
        except json.JSONDecodeError:
            continue
        if payload.get("action") == "get_current_time" and payload.get("iso"):
            stamp = dt.datetime.fromisoformat(payload["iso"])
            today = stamp.date()
            if payload.get("weekday") != stamp.strftime("%A"):
                problems["get_current_time weekday does not match its date"] += 1

    if today is None:
        return

    for message in messages:
        if message.get("role") != "assistant":
            continue
        for call in message.get("tool_calls", []):
            function = call.get("function", {})
            fields = DATED_ARGUMENTS.get(function.get("name"))
            if not fields:
                continue
            try:
                arguments = json.loads(function.get("arguments", "{}"))
            except json.JSONDecodeError:
                continue
            for field in fields:
                value = arguments.get(field)
                if not value:
                    continue
                try:
                    when = dt.datetime.fromisoformat(value).date()
                except ValueError:
                    problems[f"{function['name']}.{field} is not ISO 8601"] += 1
                    continue
                if when < today:
                    problems[f"{function['name']}.{field} is before today"] += 1

        # A reply that names a weekday and a date must name them consistently.
        text = message.get("content") or ""
        for weekday, day, month in re.findall(
            r"\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) "
            r"(\d{1,2}) (January|February|March|April|May|June|July|August|"
            r"September|October|November|December)\b", text):
            for year in (today.year, today.year + 1):
                try:
                    named = dt.datetime.strptime(f"{day} {month} {year}", "%d %B %Y").date()
                except ValueError:
                    continue
                if named >= today:
                    if named.strftime("%A") != weekday:
                        problems["reply names a weekday that does not match its date"] += 1
                    break


def validate(rows: list[dict]) -> tuple[collections.Counter, dict[str, list[str]]]:
    problems: collections.Counter = collections.Counter()
    # Keyed by what the reply got wrong, so the report can say which rule broke.
    dishonest: dict[str, list[str]] = {"claims a send": [], "claims a hand-off result": []}

    for row in rows:
        messages = row.get("messages")
        if not messages:
            problems["row has no messages"] += 1
            continue
        if not row.get("tools"):
            problems["row has no tools field"] += 1
        if messages[0].get("role") != "system":
            problems["first turn is not system"] += 1
        if len(messages) < 3:
            problems["fewer than three turns"] += 1
            continue
        if messages[1].get("role") != "user":
            problems["second turn is not user"] += 1
        if messages[-1].get("role") != "assistant":
            problems["does not end on an assistant turn"] += 1
        if not messages[-1].get("content"):
            problems["final assistant turn is empty"] += 1

        for index, message in enumerate(messages):
            role = message.get("role")

            if role == "tool":
                previous = messages[index - 1]
                if previous.get("role") != "assistant" or "tool_calls" not in previous:
                    problems["tool result not preceded by a tool call"] += 1

                # The honesty invariants. Each non-completed status calls for a
                # different reply, and both are checked.
                content = message.get("content", "")
                reply = next(
                    (m.get("content", "") for m in messages[index + 1:]
                     if m.get("role") == "assistant" and m.get("content")),
                    "",
                )
                lowered = reply.lower()

                if '"awaiting_user_confirmation"' in content:
                    if asserts(reply, CLAIMS_COMPLETION):
                        dishonest["claims a send"].append(reply)
                    elif not any(phrase in lowered for phrase in CONVEYS_PENDING):
                        problems["staged result, reply does not say it is pending"] += 1

                # A computed answer must report the number that was computed.
                try:
                    payload = json.loads(content)
                except json.JSONDecodeError:
                    payload = {}
                if payload.get("action") == "run_javascript" and payload.get("ok"):
                    value = str(payload.get("result", "")).removesuffix("n")
                    # Commas are ignored on both sides: "£12,345.60" states 12345.6.
                    if value.replace(",", "") not in reply.replace(",", ""):
                        problems["run_javascript reply does not state the result"] += 1

                if '"handed_off"' in content:
                    if asserts(reply, CLAIMS_HANDOFF_OUTCOME):
                        dishonest["claims a hand-off result"].append(reply)
                    if any(phrase in lowered for phrase in WRONG_FOR_HANDOFF):
                        problems["hand-off reply tells the user to tap send"] += 1

            if role == "assistant" and asserts(message.get("content") or "", ROLE_REFUSALS):
                problems["reply refuses in character instead of helping"] += 1

            if role == "assistant" and "tool_calls" in message:
                request = next((m.get("content", "") for m in reversed(messages[:index])
                                if m.get("role") == "user"), "").lower()
                for call in message["tool_calls"]:
                    if (call.get("function", {}).get("name") == "web_search"
                            and not any(word in request for word in SEARCH_WORDS)):
                        problems["web_search without the user asking to search"] += 1

                following = messages[index + 1] if index + 1 < len(messages) else None
                if not following or following.get("role") != "tool":
                    problems["tool call with no result"] += 1
                for call in message["tool_calls"]:
                    function = call.get("function", {})
                    if not function.get("name"):
                        problems["tool call with no name"] += 1
                    try:
                        json.loads(function.get("arguments", ""))
                    except (json.JSONDecodeError, TypeError):
                        problems["tool arguments are not valid JSON"] += 1

        check_dates(messages, problems)

    return problems, dishonest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="training/data/conduit_sft.jsonl")
    parser.add_argument("--eval-data", default="training/data/conduit_sft_eval.jsonl")
    args = parser.parse_args()

    failed = False
    for label, path in (("train", Path(args.data)), ("eval", Path(args.eval_data))):
        if not path.exists():
            print(f"{label}: {path} not found - run make_dataset.py first")
            failed = True
            continue

        rows = load(path)
        problems, dishonest = validate(rows)

        print(f"\n=== {label}: {len(rows)} rows ({path}) ===")

        explanations = {
            "claims a send": "reply says it was sent when the result says it is waiting for the user",
            "claims a hand-off result": "reply claims an outcome Conduit could not observe",
        }
        any_dishonest = False
        for kind, replies in dishonest.items():
            if not replies:
                continue
            any_dishonest = True
            failed = True
            print(f"  FAIL  {len(replies)} row(s): {explanations[kind]}.")
            for reply in replies[:5]:
                print(f"          ! {reply}")

        if problems:
            failed = True
            print("  FAIL  problems:")
            for problem, count in problems.most_common():
                print(f"          {count:5d}  {problem}")

        if not any_dishonest and not problems:
            def tool_results_with(marker: str) -> int:
                return sum(
                    1 for row in rows for m in row["messages"]
                    if m.get("role") == "tool" and marker in m.get("content", "")
                )
            staged = tool_results_with('"awaiting_user_confirmation"')
            handed = tool_results_with('"handed_off"')
            refusals = sum(
                1 for row in rows
                if not any("tool_calls" in m for m in row["messages"])
            )
            print("  OK    structure valid, dates valid, honesty invariants hold")
            print(f"        {staged} staged results, {handed} hand-offs, "
                  f"{refusals} refusal rows ({refusals / len(rows):.0%})")

    if failed:
        print("\nDo not train on this. Fix the generator first.")
        return 1
    print("\nSafe to train on.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
