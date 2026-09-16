"""Generate a tool-calling SFT dataset for Conduit.

Runs anywhere Python runs, including the Windows box this project is authored
on — no GPU needed to *build* the data, only to train on it.

What this teaches, and why each part is here:

1. **Format adherence.** Emit a well-formed tool call with correct argument
   names. Qwen3 is already decent at this, so it is the least valuable part.

2. **Procedure.** Call `get_current_time` before reasoning about "tomorrow";
   call `find_contact` before messaging a name. These are the failures that
   actually bite: a model that skips the clock schedules things in 2024.

3. **Honesty about friction.** Say "drafted, tap send" rather than "sent".
   This is behavioural, not format, and it is the single most valuable thing
   in the dataset. A model that reports a send it did not perform is worse
   than one that fails loudly.

4. **Graceful refusal.** When asked for something iOS forbids, explain and
   offer the Shortcuts route instead of hallucinating a `set_alarm` tool.

5. **Asking rather than guessing.** Two contacts match, so ask which. Guessing
   here texts the wrong person.

Usage:
    python training/make_dataset.py --out training/data/conduit_sft.jsonl
    python training/make_dataset.py --out ... --count 3000 --seed 7
"""
from __future__ import annotations

import argparse
import json
import random
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SWIFT_TOOL_DIR = REPO / "App" / "Agent"
SYSTEM_PROMPT_PATH = HERE / "system_prompt.md"
TOOLS_PATH = HERE / "tools.json"


# --------------------------------------------------------------------------
# Drift guard
# --------------------------------------------------------------------------

def swift_tool_names() -> set[str]:
    """Tool names declared in the Swift sources.

    The dataset and the app must agree on the tool surface. If they drift, the
    model is trained to call a tool that does not exist, and every such call
    fails at runtime with "there is no tool called X" — a bug that looks like
    a bad model rather than a stale dataset. Cheap to check, so it is checked.
    """
    names: set[str] = set()
    pattern = re.compile(r'ToolDescriptor\(\s*name:\s*"([a-z_]+)"')
    for path in SWIFT_TOOL_DIR.glob("*Tools.swift"):
        names |= set(pattern.findall(path.read_text(encoding="utf-8")))
    return names


def verify_tools_match(tools: list[dict]) -> None:
    declared = {t["function"]["name"] for t in tools}
    swift = swift_tool_names()
    if not swift:
        print("  ! Could not read tool names from Swift sources; skipping drift check")
        return
    missing = swift - declared
    extra = declared - swift
    if missing:
        raise SystemExit(
            f"tools.json is missing tools that exist in the app: {sorted(missing)}\n"
            "Add them to tools.json or the model will never learn to call them."
        )
    if extra:
        raise SystemExit(
            f"tools.json declares tools the app does not implement: {sorted(extra)}\n"
            "Remove them or the model will be trained to call tools that fail."
        )
    print(f"  tool drift check passed ({len(declared)} tools match the Swift sources)")


# --------------------------------------------------------------------------
# Sample vocabulary
# --------------------------------------------------------------------------

PEOPLE = [
    ("Mum", "Jane Wilson", "+447700900112"),
    ("Dad", "Peter Wilson", "+447700900113"),
    ("Sam", "Sam Okafor", "+447700900221"),
    ("Priya", "Priya Raman", "+447700900334"),
    ("Tom", "Tom Bailey", "+447700900447"),
    ("Aisha", "Aisha Khan", "+447700900558"),
    ("my sister", "Ellie Wilson", "+447700900669"),
    ("the landlord", "Derek Mortimer", "+447700900771"),
    ("Marcus", "Marcus Bell", "+447700900882"),
    ("Nina", "Nina Petrova", "+447700900993"),
    ("my boss", "Rachel Adeyemi", "+447700901104"),
    ("Kofi", "Kofi Mensah", "+447700901215"),
    ("Leila", "Leila Haddad", "+447700901326"),
    ("Josh", "Josh Trent", "+447700901437"),
    ("Grandma", "Margaret Wilson", "+447700901548"),
    ("Danny", "Danny Kovac", "+447700901659"),
]

EVENTS = [
    ("dentist", "Dentist", "10:30", 45),
    ("dinner with Sam", "Dinner with Sam", "19:30", 120),
    ("standup", "Team standup", "09:15", 15),
    ("gym", "Gym", "07:00", 60),
    ("physio", "Physio", "16:00", 30),
    ("Ellie's birthday drinks", "Ellie's birthday drinks", "20:00", 180),
    ("the car MOT", "Car MOT", "08:30", 60),
    ("call with the accountant", "Call with accountant", "14:00", 30),
]

TASKS = [
    "renew the car insurance",
    "book a haircut",
    "pay the council tax",
    "send the meter reading",
    "order more coffee",
    "return the parcel",
    "back up the laptop",
    "chase the deposit refund",
]

RELATIVE_DAYS = [
    ("tomorrow", 1), ("on Friday", 3), ("next Tuesday", 6),
    ("on Thursday", 2), ("next Monday", 5), ("on Saturday", 4),
]

MESSAGE_INTENTS = [
    ("I'll be late", "Running late, sorry — be there as soon as I can."),
    ("I'm on my way", "On my way now, see you shortly."),
    ("happy birthday", "Happy birthday! Hope you have a brilliant day."),
    ("I can't make it tonight", "Really sorry, I can't make tonight after all."),
    ("asking if they're free Saturday", "Are you free Saturday? Thought we could do something."),
    ("thanks for yesterday", "Thanks so much for yesterday, it was lovely."),
    ("I've landed", "Just landed, all good. Will call when I'm through."),
    ("asking them to call me back", "Give me a ring when you get a sec?"),
    ("I'll bring dessert", "I'll bring dessert, don't worry about it."),
    ("congratulations", "Congratulations! Really pleased for you."),
    ("I'm outside", "I'm outside whenever you're ready."),
    ("asking what time to arrive", "What time do you want me there?"),
    ("apologising for missing the call", "Sorry I missed your call — was in a meeting."),
    ("checking they got home safe", "Did you get home okay?"),
    ("I've booked it", "All booked. Sending details over shortly."),
    ("asking to reschedule", "Any chance we could move it? This week's got away from me."),
]

# Requests iOS simply cannot satisfy, paired with the honest answer.
#
# This list is deliberately long. Refusals need to be a meaningful share of the
# dataset, and because duplicate rows are dropped, the only way to get that
# share without training the same sentence twenty times is genuine variety.
IMPOSSIBLE = [
    ("set an alarm for 6am",
     "I can't set alarms — iOS doesn't let apps touch the Clock. If you make a shortcut "
     "called \"Morning alarm\" that sets one, I can run it for you from then on."),
    ("turn on do not disturb",
     "I can't change Focus modes directly. Make a shortcut that turns on Do Not Disturb and "
     "I'll run it by name whenever you ask."),
    ("read me my latest texts",
     "I can't read your messages — iOS doesn't give apps access to them. I can draft a reply "
     "if you tell me what you want to say."),
    ("check my email for the invoice",
     "I can't read your inbox; iOS blocks that for apps. I can draft an email if that helps."),
    ("turn the wifi off",
     "I can't toggle Wi-Fi. A shortcut can, though — make one and I'll run it."),
    ("answer the call",
     "I can't answer calls. I can only start one for you."),
    ("make me a shortcut that texts Mum every morning",
     "I can't create shortcuts, only run ones you've already made. If you build that one in "
     "the Shortcuts app, I'll run it on request."),
    ("hang up",
     "I can't end calls — iOS keeps call control away from apps. You'll need to tap it."),
    ("set a timer for 20 minutes",
     "I can't start timers directly. Make a shortcut that sets one and I'll run it by name."),
    ("turn the brightness down",
     "I can't change display settings. A shortcut can do it, and I can run that."),
    ("what did Sam say in his last message?",
     "I can't see your messages at all — iOS doesn't expose them to apps. If you tell me what "
     "he said, I can help you reply."),
    ("turn on bluetooth",
     "I can't toggle Bluetooth. Build a shortcut for it and I'll trigger it whenever you ask."),
    ("delete that email",
     "I have no access to your mail, so I can't delete anything. Only Mail itself can."),
    ("take a screenshot",
     "I can't take screenshots — that's not something iOS lets apps do. Side button and volume "
     "up does it."),
    ("silence my notifications for an hour",
     "I can't change notification settings. A Focus shortcut can, and I'll run it for you."),
    ("check my bank balance",
     "I can't open or read other apps' data. I can open your banking app if you like."),
    ("record a voice memo",
     "I can't record audio into another app. I can open Voice Memos for you."),
    ("what's on my screen right now?",
     "I can't see your screen. Tell me what you need and I'll work from that."),
    ("send it without asking me",
     "I can't — iOS requires you to tap send on every message an app composes. There's no way "
     "around that, whether I run locally or not."),
    ("install an app for me",
     "I can't install apps. I can open the App Store to a search if that helps."),
]

# Wrappers that vary how a request is phrased without changing its meaning, so
# the refusal behaviour generalises past one sentence shape.
IMPOSSIBLE_PHRASINGS = [
    "{r}",
    "can you {r}",
    "please {r}",
    "hey, {r}",
    "I need you to {r}",
    "could you {r} for me",
]

SHORTCUT_NAMES = [
    "Morning alarm", "Focus on", "Lights out", "Commute mode", "Log water",
    "Heating on", "Arrive home", "Night mode", "Work timer", "Feed the cat",
    "Bin day", "Start workout", "Park mode", "Guest wifi", "Podcast time",
    "Wind down", "School run", "Gym playlist", "Water plants", "Log weight",
]

SHORTCUT_PHRASINGS = [
    "run my {n} shortcut",
    "trigger {n}",
    "do the {n} shortcut",
    "fire off {n}",
    "can you run {n}",
    "{n} please",
    "start {n}",
    "kick off my {n} shortcut",
    "run the shortcut called {n}",
]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def call(name: str, arguments: dict) -> dict:
    """An assistant turn containing one tool call."""
    return {
        "role": "assistant",
        "content": "",
        "tool_calls": [{
            "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments, ensure_ascii=False)},
        }],
    }


def result(payload: dict) -> dict:
    return {"role": "tool", "content": json.dumps(payload, ensure_ascii=False, sort_keys=True)}


def iso(day_offset: int, clock: str, base_day: int = 16) -> str:
    hour, minute = clock.split(":")
    day = base_day + day_offset
    return f"2026-09-{day:02d}T{hour}:{minute}:00"


def now_payload(base_day: int = 16) -> dict:
    weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday",
                "Friday", "Saturday", "Sunday"]
    return {
        "ok": True,
        "action": "get_current_time",
        "iso": f"2026-09-{base_day:02d}T08:12:00",
        "weekday": weekdays[(base_day - 1) % 7],
        "time_zone": "Europe/London",
        "utc_offset_hours": "1",
    }


# --------------------------------------------------------------------------
# Example generators. Each returns a list of messages.
# --------------------------------------------------------------------------

def example_calendar(rng: random.Random) -> list[dict]:
    phrase, title, clock, duration = rng.choice(EVENTS)
    when, offset = rng.choice(RELATIVE_DAYS)
    start = iso(offset, clock)

    user = rng.choice([
        f"put {phrase} in my calendar {when} at {clock}",
        f"add {phrase} {when} {clock}",
        f"schedule {phrase} for {when} at {clock}",
        f"{when} at {clock} I've got {phrase}, put it in",
    ])

    return [
        {"role": "user", "content": user},
        # The clock call is the point of this example.
        call("get_current_time", {}),
        result(now_payload()),
        call("create_event", {"title": title, "start": start, "duration_minutes": duration}),
        result({
            "ok": True, "action": "create_event", "event_id": "EV-1",
            "title": title, "start": start, "calendar": "Home",
        }),
        {"role": "assistant",
         "content": f"Added {title} {when} at {clock}."},
    ]


def example_availability(rng: random.Random) -> list[dict]:
    phrase, title, clock, duration = rng.choice(EVENTS)
    when, offset = rng.choice(RELATIVE_DAYS)
    start = iso(offset, clock)
    busy = rng.random() < 0.45

    messages = [
        {"role": "user", "content": rng.choice([
            f"am I free {when} at {clock}?",
            f"have I got anything {when} around {clock}?",
            f"is {when} at {clock} clear?",
        ])},
        call("get_current_time", {}),
        result(now_payload()),
        call("check_availability", {"start": start, "end": iso(offset, clock)}),
    ]

    if busy:
        messages.append(result({
            "ok": True, "action": "check_availability", "free": "false",
            "conflicts": f"{title} {start} to {start}",
        }))
        messages.append({"role": "assistant",
                         "content": f"No — you've got {title} then."})
    else:
        messages.append(result({"ok": True, "action": "check_availability", "free": "true"}))
        messages.append({"role": "assistant", "content": "Yes, you're free then."})
    return messages


def example_reminder(rng: random.Random) -> list[dict]:
    task = rng.choice(TASKS)
    when, offset = rng.choice(RELATIVE_DAYS)
    due = iso(offset, rng.choice(["09:00", "10:00", "18:00"]))

    return [
        {"role": "user", "content": rng.choice([
            f"remind me to {task} {when}",
            f"don't let me forget to {task} {when}",
            f"stick a reminder on to {task} {when}",
        ])},
        call("get_current_time", {}),
        result(now_payload()),
        call("create_reminder", {"title": task.capitalize(), "due": due}),
        result({"ok": True, "action": "create_reminder",
                "reminder_id": "RM-1", "title": task.capitalize(), "due": due}),
        {"role": "assistant", "content": f"Reminder set for {when} to {task}."},
    ]


def example_message_drafted(rng: random.Random) -> list[dict]:
    nickname, full_name, number = rng.choice(PEOPLE)
    intent, body = rng.choice(MESSAGE_INTENTS)

    # Half the time the user sends it, half the time they dismiss the sheet.
    # Both outcomes must be reported accurately, and the dismissal case is the
    # one models get wrong.
    sent = rng.random() < 0.6

    messages = [
        {"role": "user", "content": rng.choice([
            f"text {nickname} saying {intent}",
            f"message {nickname} that {intent}",
            f"let {nickname} know {intent}",
        ])},
        call("find_contact", {"name": nickname}),
        result({
            "ok": True, "action": "find_contact", "match_count": "1",
            "matches": f"{full_name} | phones: {number}",
            "guidance": "Single match; safe to use.",
        }),
        call("send_message", {"to": full_name, "body": body}),
    ]

    if sent:
        messages.append(result({
            "ok": True, "action": "send_message",
            "recipient": full_name, "outcome": "sent",
        }))
        messages.append({"role": "assistant",
                         "content": f"Sent to {full_name.split()[0]}."})
    else:
        messages.append(result({
            "ok": False, "action": "send_message",
            "error": "The user dismissed the message without sending it. "
                     "Do not retry unless they ask; acknowledge and stop.",
        }))
        messages.append({"role": "assistant",
                         "content": "You closed it without sending — let me know if you want "
                                    "another go."})
    return messages


def example_message_awaiting(rng: random.Random) -> list[dict]:
    """The staged case: composed but not sent. The core honesty lesson."""
    nickname, full_name, number = rng.choice(PEOPLE)
    intent, body = rng.choice(MESSAGE_INTENTS)

    return [
        {"role": "user", "content": f"draft a text to {nickname} about {intent}"},
        call("find_contact", {"name": nickname}),
        result({
            "ok": True, "action": "find_contact", "match_count": "1",
            "matches": f"{full_name} | phones: {number}",
            "guidance": "Single match; safe to use.",
        }),
        call("send_message", {"to": full_name, "body": body}),
        result({
            "ok": True, "action": "send_message", "recipient": full_name,
            "status": "awaiting_user_confirmation",
            "note": "Staged for the user to confirm. Do not claim it was sent or completed.",
        }),
        {"role": "assistant",
         "content": f"Drafted it to {full_name.split()[0]} — tap send when you're happy with it."},
    ]


def example_ambiguous_contact(rng: random.Random) -> list[dict]:
    """Two matches, so ask. Never guess a message recipient."""
    first = rng.choice(["Sam", "Alex", "Chris", "Jo", "Charlie", "Robin",
                        "Jamie", "Ash", "Sasha", "Nicky"])
    surname_a, surname_b = rng.sample(
        ["Okafor", "Bailey", "Petrova", "Mensah", "Haddad", "Trent", "Bell"], 2
    )
    a, b = f"{first} {surname_a}", f"{first} {surname_b}"
    intent, body = rng.choice(MESSAGE_INTENTS)

    return [
        {"role": "user", "content": f"text {first} saying {intent}"},
        call("find_contact", {"name": first}),
        result({
            "ok": True, "action": "find_contact", "match_count": "2",
            "matches": f"{a} | phones: +447700900221\n{b} | phones: +447700900447",
            "guidance": "More than one match. Ask the user which person they meant "
                        "rather than guessing.",
        }),
        {"role": "assistant",
         "content": f"Two {first}s in your contacts — {a} or {b}?"},
    ]


def example_impossible(rng: random.Random) -> list[dict]:
    request, reply = rng.choice(IMPOSSIBLE)
    phrasing = rng.choice(IMPOSSIBLE_PHRASINGS)
    return [
        {"role": "user", "content": phrasing.format(r=request)},
        # Deliberately no tool call. The lesson is that inventing a tool is
        # wrong, and so is pretending the task was done.
        {"role": "assistant", "content": reply},
    ]


def example_shortcut(rng: random.Random) -> list[dict]:
    name = rng.choice(SHORTCUT_NAMES)
    return [
        {"role": "user", "content": rng.choice(SHORTCUT_PHRASINGS).format(n=name)},
        call("run_shortcut", {"name": name}),
        result({
            "ok": True, "action": "run_shortcut", "shortcut": name,
            "status": "awaiting_user_confirmation",
            "outcome": "Shortcuts was opened and asked to run this shortcut. Conduit cannot "
                       "see the result.",
        }),
        {"role": "assistant",
         "content": f"Asked Shortcuts to run {name} — it should be going now."},
    ]


def example_permission_denied(rng: random.Random) -> list[dict]:
    """A denial is terminal. Do not retry; explain."""
    which = rng.choice(["calendar", "reminders", "contacts"])

    if which == "calendar":
        phrase, title, clock, duration = rng.choice(EVENTS)
        when, offset = rng.choice(RELATIVE_DAYS)
        return [
            {"role": "user", "content": rng.choice([
                f"add {phrase} {when} at {clock}",
                f"put {phrase} in for {when} at {clock}",
            ])},
            call("get_current_time", {}),
            result(now_payload()),
            call("create_event", {"title": title, "start": iso(offset, clock),
                                  "duration_minutes": duration}),
            result({
                "ok": False, "action": "create_event",
                "error": "Permission to access Calendars was denied. Do not retry this tool. "
                         "Tell the user they can grant access in Settings, under Privacy and "
                         "Security.",
            }),
            {"role": "assistant",
             "content": "I don't have calendar access, so I can't add it. You can turn it on "
                        "in Settings under Privacy & Security, then Calendars."},
        ]

    if which == "reminders":
        task = rng.choice(TASKS)
        when, offset = rng.choice(RELATIVE_DAYS)
        return [
            {"role": "user", "content": f"remind me to {task} {when}"},
            call("get_current_time", {}),
            result(now_payload()),
            call("create_reminder", {"title": task.capitalize(),
                                     "due": iso(offset, "09:00")}),
            result({
                "ok": False, "action": "create_reminder",
                "error": "Permission to access Reminders was denied. Do not retry this tool. "
                         "Tell the user they can grant access in Settings, under Privacy and "
                         "Security.",
            }),
            {"role": "assistant",
             "content": "Reminders access is off, so I can't add that. Settings, then "
                        "Privacy & Security, then Reminders."},
        ]

    nickname, full_name, _ = rng.choice(PEOPLE)
    intent, _ = rng.choice(MESSAGE_INTENTS)
    return [
        {"role": "user", "content": f"text {nickname} about {intent}"},
        call("find_contact", {"name": nickname}),
        result({
            "ok": False, "action": "find_contact",
            "error": "Permission to access Contacts was denied. Do not retry this tool. "
                     "Tell the user they can grant access in Settings, under Privacy and "
                     "Security.",
        }),
        {"role": "assistant",
         "content": f"I can't look up {nickname} without contacts access. Give me the number "
                    "and I'll draft it, or turn it on in Settings under Privacy & Security."},
    ]


def example_multistep(rng: random.Random) -> list[dict]:
    """Check the calendar, then message someone about it."""
    nickname, full_name, number = rng.choice(PEOPLE)
    when, offset = rng.choice(RELATIVE_DAYS)
    clock, outing = rng.choice([
        ("19:30", "dinner"), ("18:00", "drinks"), ("12:30", "lunch"),
        ("20:00", "the cinema"), ("11:00", "coffee"), ("17:30", "a walk"),
    ])
    start = iso(offset, clock)

    return [
        {"role": "user",
         "content": f"am I free {when} at {clock}? if so ask {nickname} about {outing}"},
        call("get_current_time", {}),
        result(now_payload()),
        call("check_availability", {"start": start, "end": iso(offset, "22:00")}),
        result({"ok": True, "action": "check_availability", "free": "true"}),
        call("find_contact", {"name": nickname}),
        result({
            "ok": True, "action": "find_contact", "match_count": "1",
            "matches": f"{full_name} | phones: {number}",
            "guidance": "Single match; safe to use.",
        }),
        call("send_message", {
            "to": full_name,
            "body": f"Free {when.replace('on ', '')} — fancy {outing}?",
        }),
        result({
            "ok": True, "action": "send_message", "recipient": full_name,
            "status": "awaiting_user_confirmation",
            "note": "Staged for the user to confirm. Do not claim it was sent or completed.",
        }),
        {"role": "assistant",
         "content": f"You're free {when}. Drafted a text to {full_name.split()[0]} — tap send."},
    ]


# Weighted so the behavioural lessons outnumber the format ones. Plain
# calendar writes are the easiest thing for the model to already do well;
# honesty about friction and refusals are what need reinforcing.
GENERATORS = [
    (example_calendar, 14),
    (example_reminder, 10),
    (example_availability, 8),
    (example_message_drafted, 12),
    (example_message_awaiting, 14),
    (example_ambiguous_contact, 8),
    (example_impossible, 16),
    (example_shortcut, 7),
    (example_permission_denied, 6),
    (example_multistep, 9),
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="training/data/conduit_sft.jsonl")
    parser.add_argument("--count", type=int, default=1200)
    parser.add_argument("--seed", type=int, default=20260916)
    parser.add_argument("--eval-fraction", type=float, default=0.05)
    args = parser.parse_args()

    tools = json.loads(TOOLS_PATH.read_text(encoding="utf-8"))
    verify_tools_match(tools)

    system_prompt = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8").strip()
    rng = random.Random(args.seed)

    # Each scenario is filled to its own share of the target rather than
    # sampled from a shared pool.
    #
    # The shared-pool approach looks simpler but silently corrupts the mix:
    # scenarios built from small template vocabularies exhaust their unique
    # combinations early, the loop keeps drawing until it hits the requested
    # total, and the scenarios with large vocabularies quietly absorb the
    # shortfall. The result is a dataset whose actual balance is nothing like
    # the declared weights — and the weights are the entire point, since the
    # behavioural lessons are the ones that need reinforcing.
    #
    # Filling per scenario means a scenario that cannot reach its share is
    # reported as a shortfall instead of being papered over.
    total_weight = sum(weight for _, weight in GENERATORS)

    rows: list[dict] = []
    yields: dict[str, int] = {}
    shortfalls: dict[str, tuple[int, int]] = {}

    for generator, weight in GENERATORS:
        name = generator.__name__.replace("example_", "")
        target = max(1, round(args.count * weight / total_weight))
        seen: set[str] = set()
        produced = 0
        # Generous but bounded: enough attempts to exhaust a small template
        # space, not enough to spin.
        budget = target * 60

        for _ in range(budget):
            if produced >= target:
                break
            messages = generator(rng)
            fingerprint = json.dumps(messages, sort_keys=True)
            if fingerprint in seen:
                continue
            seen.add(fingerprint)
            rows.append({
                "messages": [{"role": "system", "content": system_prompt}] + messages,
                "tools": tools,
            })
            produced += 1

        yields[name] = produced
        if produced < target:
            shortfalls[name] = (produced, target)

    rng.shuffle(rows)
    split = max(1, int(len(rows) * args.eval_fraction))
    evaluation, training = rows[:split], rows[split:]

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    eval_path = out_path.with_name(out_path.stem + "_eval.jsonl")

    for path, subset in ((out_path, training), (eval_path, evaluation)):
        with path.open("w", encoding="utf-8") as handle:
            for row in subset:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"wrote {len(training)} training rows -> {out_path}")
    print(f"wrote {len(evaluation)} eval rows     -> {eval_path}")

    if shortfalls:
        print(f"\n  ! {len(shortfalls)} scenario(s) could not fill their share from the "
              f"current templates.")
        print("    The mix below is therefore skewed away from these. Either lower --count, "
              "or add")
        print("    vocabulary to the lists at the top of this file (that is the real fix).")
        for name, (produced, target) in shortfalls.items():
            print(f"      {name}: {produced} of {target}")

    # Per-generator yield, because the interesting failure is a category whose
    # template vocabulary is too small to fill its weight. That shows up here
    # as a scenario sitting far below its requested share, and it silently
    # skews what the model learns if nobody looks.
    requested = {g.__name__.replace("example_", ""): w for g, w in GENERATORS}
    total_weight = sum(requested.values())
    print("\nscenario mix (actual vs requested):")
    for name, weight in sorted(requested.items(), key=lambda kv: -kv[1]):
        got = yields.get(name, 0)
        actual = got / len(rows)
        target = weight / total_weight
        flag = "  <-- STARVED" if actual < target * 0.6 else ""
        print(f"  {got:5d}  {actual:5.1%} (want {target:5.1%})  {name}{flag}")

    counts: dict[str, int] = {}
    for row in rows:
        for message in row["messages"]:
            for tool_call in message.get("tool_calls", []):
                name = tool_call["function"]["name"]
                counts[name] = counts.get(name, 0) + 1
    print("\ntool call distribution:")
    for name, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {count:5d}  {name}")

    no_tool = sum(1 for row in rows
                  if not any("tool_calls" in m for m in row["messages"]))
    print(f"\n{no_tool} rows ({no_tool / len(rows):.0%}) contain no tool call at all - "
          "these teach refusal and should be a meaningful slice, not a rounding error.")


if __name__ == "__main__":
    main()
