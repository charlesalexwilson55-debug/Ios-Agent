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
import datetime as dt
import json
import math
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


def swift_status_notes() -> dict[str, str]:
    """The note text ToolKit.swift attaches to each non-completed status.

    Reads `payload["status"] = "..."` followed by a `payload["note"] = "..." + "..."`
    concatenation and joins the literals, so the comparison is against exactly
    what the app sends the model.
    """
    source = (SWIFT_TOOL_DIR / "ToolKit.swift").read_text(encoding="utf-8")
    pattern = re.compile(
        r'payload\["status"\]\s*=\s*"([a-z_]+)"\s*'
        r'payload\["note"\]\s*=\s*((?:"[^"\n]*"\s*\+?\s*)+)'
    )
    notes = {}
    for status, literals in pattern.findall(source):
        notes[status] = "".join(re.findall(r'"([^"\n]*)"', literals))
    return notes


def verify_notes_match() -> None:
    swift = swift_status_notes()
    expected = {
        "awaiting_user_confirmation": AWAITING_NOTE,
        "handed_off": HANDOFF_NOTE,
    }
    if not swift:
        print("  ! Could not read status notes from ToolKit.swift; skipping note check")
        return
    for status, note in expected.items():
        if status not in swift:
            raise SystemExit(f"ToolKit.swift no longer emits status {status!r}; "
                             "update the dataset generator to match.")
        if swift[status] != note:
            raise SystemExit(
                f"The {status} note differs between ToolKit.swift and this generator.\n"
                f"  swift:   {swift[status]}\n"
                f"  dataset: {note}\n"
                "Training on different wording from what the app sends means the "
                "model sees an unfamiliar prompt at runtime. Make them identical."
            )
    print(f"  status note check passed ({len(expected)} notes match ToolKit.swift)")


def swift_prompt_blocks() -> list[str]:
    """The literal sections of SystemPrompt.swift, as Swift renders them.

    Each multiline string is dedented and its trailing-backslash continuations
    joined, which is what Swift does at compile time. The friction lists are
    built from the registry at runtime and are not covered here.
    """
    source = (SWIFT_TOOL_DIR / "SystemPrompt.swift").read_text(encoding="utf-8")
    blocks = []
    for raw in re.findall(r'"""\n(.*?)\n[ \t]*"""', source, re.S):
        lines = raw.split("\n")
        indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
        blocks.append("\n".join(l[indent:] for l in lines).replace("\\\n", ""))
    return blocks


def verify_prompt_matches(system_prompt: str) -> None:
    blocks = swift_prompt_blocks()
    if not blocks:
        print("  ! Could not read SystemPrompt.swift; skipping prompt check")
        return
    for block in blocks:
        if block not in system_prompt:
            raise SystemExit(
                "system_prompt.md is out of sync with SystemPrompt.swift. This section "
                f"is missing or reworded:\n\n{block}\n\n"
                "The model must be trained under the same prompt it runs under."
            )
    print(f"  prompt check passed ({len(blocks)} sections match SystemPrompt.swift)")


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

# "Today" varies across examples so the model learns to do the arithmetic from
# get_current_time's answer rather than memorising one fixed set of offsets.
# The spread covers every weekday and crosses a month boundary.
BASE_DATES = [
    dt.date(2026, 9, 14),   # Monday
    dt.date(2026, 9, 16),   # Wednesday
    dt.date(2026, 9, 18),   # Friday
    dt.date(2026, 9, 20),   # Sunday
    dt.date(2026, 9, 24),   # Thursday
    dt.date(2026, 9, 29),   # Tuesday, so "on Friday" lands in October
    dt.date(2026, 10, 3),   # Saturday
]

# Relative phrases paired with a target weekday (0 = Monday), or a fixed
# offset in days for the ones that aren't weekday-based.
#
# "next <weekday>" is left out on purpose. People disagree about whether
# "next Friday" said on a Wednesday means two days away or nine. Training on
# one reading would teach the model to guess confidently, when it should ask.
# "on <weekday>" always means the next time that day comes round.
RELATIVE_PHRASES = [
    ("tomorrow", ("offset", 1)),
    ("the day after tomorrow", ("offset", 2)),
    ("on Monday", ("weekday", 0)),
    ("on Tuesday", ("weekday", 1)),
    ("on Wednesday", ("weekday", 2)),
    ("on Thursday", ("weekday", 3)),
    ("on Friday", ("weekday", 4)),
    ("on Saturday", ("weekday", 5)),
    ("on Sunday", ("weekday", 6)),
]


def resolve_day(today: dt.date, rule: tuple[str, int]) -> dt.date:
    """The date a relative phrase refers to, from the point of view of today.

    A weekday means its next occurrence strictly after today, so "on Friday"
    said on a Friday means a week away, not today.
    """
    kind, value = rule
    if kind == "offset":
        return today + dt.timedelta(days=value)
    ahead = (value - today.weekday()) % 7
    return today + dt.timedelta(days=ahead or 7)


def pick_day(rng: random.Random) -> tuple[dt.date, str, dt.date]:
    """A random (today, phrase, target date) triple.

    A weekday phrase is skipped when it would land on tomorrow: "on Thursday"
    said on a Wednesday is valid but ambiguous next to "tomorrow" in the same
    dataset, and the weekday examples teach more when the gap is larger.
    """
    while True:
        today = rng.choice(BASE_DATES)
        phrase, rule = rng.choice(RELATIVE_PHRASES)
        target = resolve_day(today, rule)
        if rule[0] == "weekday" and (target - today).days == 1:
            continue
        return today, phrase, target

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


def iso(day: dt.date, clock: str) -> str:
    return f"{day.isoformat()}T{clock}:00"


def now_payload(today: dt.date) -> dict:
    """What get_current_time returns, derived from a real calendar date.

    The weekday comes from the date itself. An earlier version computed it
    from the day-of-month and labelled 16 September 2026 a Tuesday when it is
    a Wednesday, which would have trained the model on a wrong calendar.
    """
    return {
        "ok": True,
        "action": "get_current_time",
        "iso": f"{today.isoformat()}T08:12:00+01:00",
        "weekday": today.strftime("%A"),
        "time_zone": "Europe/London",
        "utc_offset_hours": "1",
    }


# The status notes the app attaches to non-completed results. These must match
# ToolOutcome.modelResponseJSON in App/Agent/ToolKit.swift word for word, and
# verify_notes_match() checks that they do. The model is trained on these
# strings and sees them again at runtime, so any drift makes the runtime
# prompt differ from the training prompt.
AWAITING_NOTE = (
    "Staged in a system sheet. The user must tap send. "
    "Do not claim it was sent. Tell them it is drafted and waiting for them."
)
HANDOFF_NOTE = (
    "Another app is now open and Conduit cannot see what happens there. "
    "Tell the user which app you opened and why, for example: I've opened Maps "
    "with directions to the station. Do not claim it succeeded, "
    "and do not tell the user to tap send - there is nothing for them to send."
)


def staged_result(action: str, **detail: str) -> dict:
    """A result for a message or email waiting in a compose sheet."""
    return result({"ok": True, "action": action,
                   "status": "awaiting_user_confirmation", "note": AWAITING_NOTE, **detail})


def handed_off_result(action: str, **detail: str) -> dict:
    """A result for a call, shortcut or app launch Conduit can no longer see."""
    return result({"ok": True, "action": action,
                   "status": "handed_off", "note": HANDOFF_NOTE, **detail})


# --------------------------------------------------------------------------
# Example generators. Each returns a list of messages.
# --------------------------------------------------------------------------

def spoken(day: dt.date) -> str:
    """'Friday 18 September'. Built by hand because %-d is not portable."""
    return f"{day.strftime('%A')} {day.day} {day.strftime('%B')}"


def plus_minutes(day: dt.date, clock: str, minutes: int) -> str:
    hour, minute = map(int, clock.split(":"))
    moment = dt.datetime.combine(day, dt.time(hour, minute)) + dt.timedelta(minutes=minutes)
    return moment.strftime("%Y-%m-%dT%H:%M:00")


def found_one(full_name: str, number: str) -> dict:
    return result({
        "ok": True, "action": "find_contact", "match_count": "1",
        "matches": f"{full_name} | phones: {number}",
        "guidance": "Single match; safe to use.",
    })


def denied(action: str, what: str) -> dict:
    # Mirrors ToolOutcome.denied in ToolKit.swift.
    return result({
        "ok": False, "action": action,
        "error": f"Permission to access {what} was denied. Do not retry this tool. "
                 "Tell the user they can grant access in Settings, under Privacy and Security.",
    })


def example_calendar(rng: random.Random) -> list[dict]:
    phrase, title, clock, duration = rng.choice(EVENTS)
    today, when, target = pick_day(rng)
    start = iso(target, clock)

    user = rng.choice([
        f"put {phrase} in my calendar {when} at {clock}",
        f"add {phrase} {when} {clock}",
        f"schedule {phrase} for {when} at {clock}",
        f"{when} at {clock} I've got {phrase}, put it in",
    ])

    return [
        {"role": "user", "content": user},
        # The clock call is the point of this example: the date in create_event
        # is only knowable from its answer.
        call("get_current_time", {}),
        result(now_payload(today)),
        call("create_event", {"title": title, "start": start, "duration_minutes": duration}),
        result({
            "ok": True, "action": "create_event", "event_id": "EV-1",
            "title": title, "start": start,
            "end": plus_minutes(target, clock, duration), "calendar": "Home",
        }),
        # Naming the resolved date lets the user catch a misread instantly.
        {"role": "assistant", "content": f"Added {title} on {spoken(target)} at {clock}."},
    ]


def example_availability(rng: random.Random) -> list[dict]:
    phrase, title, clock, duration = rng.choice(EVENTS)
    today, when, target = pick_day(rng)
    start = iso(target, clock)
    end = plus_minutes(target, clock, 60)
    busy = rng.random() < 0.45

    messages = [
        {"role": "user", "content": rng.choice([
            f"am I free {when} at {clock}?",
            f"have I got anything {when} around {clock}?",
            f"is {when} at {clock} clear?",
        ])},
        call("get_current_time", {}),
        result(now_payload(today)),
        call("check_availability", {"start": start, "end": end}),
    ]

    if busy:
        messages.append(result({
            "ok": True, "action": "check_availability", "free": "false",
            "conflicts": f"{title} {start} to {plus_minutes(target, clock, duration)}",
        }))
        messages.append({"role": "assistant",
                         "content": f"No, you've got {title} on {spoken(target)} at {clock}."})
    else:
        messages.append(result({"ok": True, "action": "check_availability", "free": "true"}))
        messages.append({"role": "assistant",
                         "content": f"Yes, you're free on {spoken(target)} at {clock}."})
    return messages


def example_reminder(rng: random.Random) -> list[dict]:
    task = rng.choice(TASKS)
    today, when, target = pick_day(rng)
    clock = rng.choice(["09:00", "10:00", "18:00"])
    due = iso(target, clock)

    return [
        {"role": "user", "content": rng.choice([
            f"remind me to {task} {when}",
            f"don't let me forget to {task} {when}",
            f"stick a reminder on to {task} {when}",
        ])},
        call("get_current_time", {}),
        result(now_payload(today)),
        call("create_reminder", {"title": task.capitalize(), "due": due}),
        result({"ok": True, "action": "create_reminder",
                "reminder_id": "RM-1", "title": task.capitalize(), "due": due}),
        {"role": "assistant",
         "content": f"Reminder set for {spoken(target)} at {clock} to {task}."},
    ]


def example_message_drafted(rng: random.Random) -> list[dict]:
    nickname, full_name, number = rng.choice(PEOPLE)
    intent, body = rng.choice(MESSAGE_INTENTS)

    # The user either sends it or dismisses the sheet. Both outcomes must be
    # reported accurately, and the dismissal is the one models get wrong.
    sent = rng.random() < 0.6

    messages = [
        {"role": "user", "content": rng.choice([
            f"text {nickname} saying {intent}",
            f"message {nickname} that {intent}",
            f"let {nickname} know {intent}",
        ])},
        call("find_contact", {"name": nickname}),
        found_one(full_name, number),
        call("send_message", {"to": full_name, "body": body}),
    ]

    if sent:
        # Only this path may say "sent": the result reports the user tapped it.
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
                         "content": "You closed it without sending. Let me know if you want "
                                    "another go."})
    return messages


def example_message_awaiting(rng: random.Random) -> list[dict]:
    """The staged case: composed but not sent. The core honesty lesson."""
    nickname, full_name, number = rng.choice(PEOPLE)
    intent, body = rng.choice(MESSAGE_INTENTS)

    return [
        {"role": "user", "content": rng.choice([
            f"draft a text to {nickname} about {intent}",
            f"get a message ready for {nickname}, {intent}",
            f"write {nickname} a text, {intent}",
        ])},
        call("find_contact", {"name": nickname}),
        found_one(full_name, number),
        call("send_message", {"to": full_name, "body": body}),
        staged_result("send_message", recipient=full_name),
        {"role": "assistant",
         "content": f"Drafted it to {full_name.split()[0]}. Tap send when you're happy with it."},
    ]


def example_email_awaiting(rng: random.Random) -> list[dict]:
    """The same honesty lesson for email, so it is not learned as texts-only."""
    nickname, full_name, _ = rng.choice(PEOPLE)
    subject, body = rng.choice([
        ("Friday", "Are we still on for Friday? Let me know either way."),
        ("Invoice", "Attached is this month's invoice. Shout if anything looks off."),
        ("Quick question", "Have you got ten minutes this week for a quick call?"),
        ("Thank you", "Thanks again for your help last week, it made a real difference."),
    ])
    address = full_name.split()[0].lower() + "@example.com"

    return [
        {"role": "user", "content": f"email {nickname} about {subject.lower()}"},
        call("find_contact", {"name": nickname}),
        result({
            "ok": True, "action": "find_contact", "match_count": "1",
            "matches": f"{full_name} | emails: {address}",
            "guidance": "Single match; safe to use.",
        }),
        call("send_email", {"to": full_name, "subject": subject, "body": body}),
        staged_result("send_email", recipients=full_name),
        {"role": "assistant",
         "content": f"Drafted an email to {full_name.split()[0]}. It's ready for you to tap send."},
    ]


def example_ambiguous_contact(rng: random.Random) -> list[dict]:
    """Two matches, so ask. Never guess a message recipient."""
    first = rng.choice(["Sam", "Alex", "Chris", "Jo", "Charlie", "Robin",
                        "Jamie", "Ash", "Sasha", "Nicky"])
    surname_a, surname_b = rng.sample(
        ["Okafor", "Bailey", "Petrova", "Mensah", "Haddad", "Trent", "Bell"], 2
    )
    a, b = f"{first} {surname_a}", f"{first} {surname_b}"
    intent, _ = rng.choice(MESSAGE_INTENTS)

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
         "content": f"There are two {first}s in your contacts, {a} and {b}. Which one?"},
    ]


def example_impossible(rng: random.Random) -> list[dict]:
    request, reply = rng.choice(IMPOSSIBLE)
    phrasing = rng.choice(IMPOSSIBLE_PHRASINGS)
    return [
        {"role": "user", "content": phrasing.format(r=request)},
        # Deliberately no tool call. Inventing a tool is wrong, and so is
        # pretending the task was done.
        {"role": "assistant", "content": reply},
    ]


def example_shortcut(rng: random.Random) -> list[dict]:
    """A hand-off: say what was asked for, never what happened."""
    name = rng.choice(SHORTCUT_NAMES)
    return [
        {"role": "user", "content": rng.choice(SHORTCUT_PHRASINGS).format(n=name)},
        call("run_shortcut", {"name": name}),
        # Detail fields mirror DeviceTools.runShortcut.
        handed_off_result(
            "run_shortcut",
            shortcut=name,
            outcome="Shortcuts was opened and asked to run this shortcut. Conduit cannot see "
                    "the result. If the name does not match one of the user's shortcuts, "
                    "Shortcuts will show an error. Ask the user whether it worked rather "
                    "than assuming it did.",
        ),
        {"role": "assistant",
         "content": rng.choice([
             f"I've opened Shortcuts to run {name}. I can't see whether it worked from here.",
             f"I've opened Shortcuts to run {name}. If nothing happened, check the name matches.",
         ])},
    ]


def example_call(rng: random.Random) -> list[dict]:
    """Starting a call is a hand-off too: no send button, no visible result."""
    nickname, full_name, number = rng.choice(PEOPLE)
    facetime = rng.random() < 0.3
    arguments = {"to": full_name}
    if facetime:
        arguments["facetime"] = True

    return [
        {"role": "user", "content": rng.choice([
            f"{'facetime' if facetime else 'call'} {nickname}",
            f"ring {nickname}" if not facetime else f"video call {nickname}",
            f"get {nickname} on the phone" if not facetime else f"facetime {nickname} please",
        ])},
        call("find_contact", {"name": nickname}),
        found_one(full_name, number),
        call("place_call", arguments),
        # Detail fields mirror PeopleTools.placeCall.
        handed_off_result(
            "place_call",
            recipient=full_name,
            outcome="handed off to the phone app; iOS asks the user to confirm",
        ),
        {"role": "assistant",
         "content": f"{'Starting FaceTime with' if facetime else 'Calling'} "
                    f"{full_name.split()[0]}. iOS will ask you to confirm."},
    ]


def example_permission_denied(rng: random.Random) -> list[dict]:
    """A denial is terminal. Do not retry; explain."""
    which = rng.choice(["calendar", "reminders", "contacts"])

    if which == "calendar":
        phrase, title, clock, duration = rng.choice(EVENTS)
        today, when, target = pick_day(rng)
        return [
            {"role": "user", "content": rng.choice([
                f"add {phrase} {when} at {clock}",
                f"put {phrase} in for {when} at {clock}",
            ])},
            call("get_current_time", {}),
            result(now_payload(today)),
            call("create_event", {"title": title, "start": iso(target, clock),
                                  "duration_minutes": duration}),
            denied("create_event", "Calendars"),
            {"role": "assistant",
             "content": "I don't have calendar access, so I can't add it. You can turn it on "
                        "in Settings under Privacy & Security, then Calendars."},
        ]

    if which == "reminders":
        task = rng.choice(TASKS)
        today, when, target = pick_day(rng)
        return [
            {"role": "user", "content": f"remind me to {task} {when}"},
            call("get_current_time", {}),
            result(now_payload(today)),
            call("create_reminder", {"title": task.capitalize(),
                                     "due": iso(target, "09:00")}),
            denied("create_reminder", "Reminders"),
            {"role": "assistant",
             "content": "Reminders access is off, so I can't add that. It's in Settings under "
                        "Privacy & Security, then Reminders."},
        ]

    nickname, _, _ = rng.choice(PEOPLE)
    intent, _ = rng.choice(MESSAGE_INTENTS)
    return [
        {"role": "user", "content": f"text {nickname} about {intent}"},
        call("find_contact", {"name": nickname}),
        denied("find_contact", "Contacts"),
        {"role": "assistant",
         "content": f"I can't look up {nickname} without contacts access. Give me the number "
                    "and I'll draft it, or turn access on in Settings under Privacy & Security."},
    ]


def example_multistep(rng: random.Random) -> list[dict]:
    """Check the calendar, then draft a message about it."""
    nickname, full_name, number = rng.choice(PEOPLE)
    today, when, target = pick_day(rng)
    clock, outing = rng.choice([
        ("19:30", "dinner"), ("18:00", "drinks"), ("12:30", "lunch"),
        ("20:00", "the cinema"), ("11:00", "coffee"), ("17:30", "a walk"),
    ])
    start = iso(target, clock)

    return [
        {"role": "user",
         "content": f"am I free {when} at {clock}? if so ask {nickname} about {outing}"},
        call("get_current_time", {}),
        result(now_payload(today)),
        call("check_availability", {"start": start, "end": plus_minutes(target, clock, 120)}),
        result({"ok": True, "action": "check_availability", "free": "true"}),
        call("find_contact", {"name": nickname}),
        found_one(full_name, number),
        call("send_message", {
            "to": full_name,
            "body": f"I'm free {target.strftime('%A')} at {clock}. Fancy {outing}?",
        }),
        staged_result("send_message", recipient=full_name),
        {"role": "assistant",
         "content": f"You're free on {spoken(target)} at {clock}. I've drafted a text to "
                    f"{full_name.split()[0]}, just tap send."},
    ]


# --------------------------------------------------------------------------
# Answering directly: maths, knowledge, code, and when to search
# --------------------------------------------------------------------------
#
# Without these the dataset is all phone tasks and refusals, and a model
# trained on it learns that anything which is not a phone task gets refused.
# That is exactly the "I'm not a mathematician" failure seen on device.

def js_number(x: float) -> str:
    """What JavaScript prints for a number in the ranges used here."""
    if x == int(x) and abs(x) < 1e21:
        return str(int(x))
    return repr(x)


def js_round(x: float) -> float:
    """Math.round: nearest integer, ties toward positive infinity."""
    floor = math.floor(x)
    return float(floor + 1 if x - floor >= 0.5 else floor)


def near_tie(x: float) -> bool:
    """True when rounding x could differ by a hair between two libm builds."""
    return abs((x - math.floor(x)) - 0.5) < 1e-6


def long_date(day: dt.date) -> str:
    return f"{day.day} {day.strftime('%B')} {day.year}"


def maths_problem(rng: random.Random) -> tuple[str, str, str, str] | None:
    """(question, JavaScript, result as JS prints it, answer), or None to retry."""
    kind = rng.choice(["percent", "split", "compound", "multiply", "sqrt",
                       "miles", "fahrenheit", "factorial", "days"])

    if kind == "percent":
        p = rng.choice([5, 8.25, 12.5, 15, 17.5, 20, 22, 35])
        n = rng.randint(120, 9999)
        raw = n * p / 100 * 100
        if near_tie(raw):
            return None
        value = js_number(js_round(raw) / 100)
        return (rng.choice([f"what's {p}% of {n}", f"calculate {p} percent of {n}",
                            f"{p}% of {n}?"]),
                f"Math.round({n} * {p} / 100 * 100) / 100",
                value, f"{p}% of {n} is {value}.")

    if kind == "split":
        total = f"{rng.randint(2000, 25000) / 100:.2f}"
        people = rng.randint(2, 6)
        tip = rng.choice([10, 12.5, 15, 20])
        raw = float(total) * (1 + tip / 100) / people * 100
        if near_tie(raw):
            return None
        each = js_round(raw) / 100
        return (rng.choice([f"split £{total} between {people} people with a {tip}% tip",
                            f"the bill is £{total}, add {tip}% tip and split it {people} ways"]),
                f"Math.round({total} * (1 + {tip} / 100) / {people} * 100) / 100",
                js_number(each), f"With a {tip}% tip that's £{each:.2f} each.")

    if kind == "compound":
        principal = rng.choice([1000, 2500, 5000, 10000, 20000])
        rate = rng.choice([2, 3.5, 4, 4.5, 5, 6.25])
        years = rng.randint(2, 25)
        raw = principal * (1 + rate / 100) ** years * 100
        if near_tie(raw):
            return None
        amount = js_round(raw) / 100
        return (f"if I put £{principal} in savings at {rate}% a year, how much will I have "
                f"after {years} years",
                f"Math.round({principal} * (1 + {rate} / 100) ** {years} * 100) / 100",
                js_number(amount),
                f"After {years} years you'd have £{amount:,.2f}, assuming the interest is "
                f"added once a year and you take nothing out.")

    if kind == "multiply":
        a, b = rng.randint(1000, 99999), rng.randint(100, 9999)
        return (rng.choice([f"what's {a} times {b}", f"{a} x {b}", f"multiply {a} by {b}"]),
                f"{a} * {b}", str(a * b), f"{a:,} × {b:,} = {a * b:,}.")

    if kind == "sqrt":
        root = rng.randint(12, 999)
        return (f"what's the square root of {root * root}",
                f"Math.sqrt({root * root})", str(root),
                f"The square root of {root * root:,} is {root}.")

    if kind == "miles":
        miles = rng.choice([3.1, 5, 6.2, 10, 13.1, 26.2, 42, 60, 100, 250])
        raw = miles * 1.609344 * 100
        if near_tie(raw):
            return None
        km = js_number(js_round(raw) / 100)
        return (f"how many km is {miles} miles",
                f"Math.round({miles} * 1.609344 * 100) / 100",
                km, f"{miles} miles is {km} km.")

    if kind == "fahrenheit":
        f = rng.randint(-20, 110)
        raw = (f - 32) * 5 / 9 * 10
        if near_tie(raw):
            return None
        c = js_number(js_round(raw) / 10)
        return (f"convert {f}°F to celsius",
                f"Math.round(({f} - 32) * 5 / 9 * 10) / 10",
                c, f"{f}°F is {c}°C.")

    if kind == "factorial":
        n = rng.randint(21, 40)
        exact = str(math.factorial(n))
        return (f"what is {n} factorial exactly",
                f"let f = 1n;\nfor (let i = 2n; i <= {n}n; i++) f *= i;\nf",
                exact + "n", f"{n}! = {exact}")

    # days between two dates
    start = dt.date(2026, 1, 1) + dt.timedelta(days=rng.randint(0, 300))
    end = start + dt.timedelta(days=rng.randint(10, 700))
    days = (end - start).days
    return (f"how many days are there between {long_date(start)} and {long_date(end)}",
            f"(Date.UTC({end.year}, {end.month - 1}, {end.day}) - "
            f"Date.UTC({start.year}, {start.month - 1}, {start.day})) / 86400000",
            str(days), f"There are {days} days between those dates.")


def example_maths(rng: random.Random) -> list[dict]:
    problem = None
    while problem is None:
        problem = maths_problem(rng)
    question, code, value, answer = problem
    return [
        {"role": "user", "content": question},
        call("run_javascript", {"code": code}),
        result({"action": "run_javascript", "ok": True, "result": value}),
        {"role": "assistant", "content": answer},
    ]


# Short, checkable answers. Every one of these must be true.
KNOWLEDGE = [
    ("what's the capital of Australia", "Canberra."),
    ("how many bones are in an adult human body", "206."),
    ("who wrote Pride and Prejudice", "Jane Austen. It was published in 1813."),
    ("what does HTTP stand for", "HyperText Transfer Protocol."),
    ("what's the chemical symbol for gold", "Au, from the Latin aurum."),
    ("what's the largest planet in the solar system", "Jupiter."),
    ("what's the boiling point of water in fahrenheit", "212°F at sea level."),
    ("how fast is the speed of light",
     "299,792,458 metres per second in a vacuum, or about 300,000 km per second."),
    ("how far away is the moon",
     "About 384,400 km on average, which is roughly 238,900 miles."),
    ("why is the sky blue",
     "Air molecules scatter sunlight, and they scatter short blue wavelengths far more "
     "than long red ones. That scattered blue light reaches your eyes from every part of "
     "the sky, so the sky looks blue."),
    ("what's the difference between a virus and bacteria",
     "Bacteria are single-celled organisms that can live and reproduce on their own, and "
     "many are harmless or useful. Viruses are much smaller and can only reproduce inside "
     "another organism's cells. Antibiotics work against bacteria but not viruses."),
    ("is a tomato a fruit",
     "Botanically, yes: it grows from the flower and holds the seeds. In cooking it's "
     "treated as a vegetable."),
    ("what is the pythagorean theorem",
     "In a right-angled triangle, the square of the hypotenuse equals the sum of the "
     "squares of the other two sides: a² + b² = c². So a triangle with sides 3 and 4 has "
     "a hypotenuse of 5."),
    ("explain what a derivative is",
     "A derivative measures how fast a function is changing at a point, which is the "
     "slope of its graph there. The derivative of x² is 2x, so at x = 3 the curve is "
     "rising at a rate of 6."),
    ("what's the difference between affect and effect",
     "Affect is usually a verb meaning to influence: the rain affected the match. Effect "
     "is usually a noun meaning a result: the rain had an effect on the match."),
    ("what's a prime number",
     "A whole number greater than 1 whose only divisors are 1 and itself. The first few "
     "are 2, 3, 5, 7, 11 and 13."),
    ("how many continents are there",
     "Seven, in the most common convention: Africa, Antarctica, Asia, Australia, Europe, "
     "North America and South America."),
    ("what's the difference between let and const in javascript",
     "Both are block-scoped. A `const` binding can't be reassigned after it's set, while "
     "a `let` binding can. The contents of a `const` object or array can still change."),
    ("how do I reverse a list in python",
     "Use `items.reverse()` to reverse it in place, or `items[::-1]` to get a new "
     "reversed list and leave the original alone."),
    ("write a python function that checks if a string is a palindrome",
     "```python\n"
     "def is_palindrome(text: str) -> bool:\n"
     "    cleaned = \"\".join(ch.lower() for ch in text if ch.isalnum())\n"
     "    return cleaned == cleaned[::-1]\n"
     "```\n\n"
     "It ignores case, spaces and punctuation, so "
     "`is_palindrome(\"A man, a plan, a canal: Panama\")` returns `True`."),
    ("write a sql query to get the 5 most recent orders",
     "```sql\n"
     "SELECT *\n"
     "FROM orders\n"
     "ORDER BY created_at DESC\n"
     "LIMIT 5;\n"
     "```\n\n"
     "Swap `created_at` for whatever your date column is called."),
    ("write a swift function that returns the average of an array of doubles",
     "```swift\n"
     "func average(_ values: [Double]) -> Double? {\n"
     "    guard !values.isEmpty else { return nil }\n"
     "    return values.reduce(0, +) / Double(values.count)\n"
     "}\n"
     "```\n\n"
     "It returns `nil` for an empty array rather than dividing by zero."),
    # Live information: no search unless asked, but say how to get it.
    ("what's the weather going to be tomorrow",
     "I can't check the weather because I'm offline. Ask me to search for it and I'll "
     "open a web search."),
    ("who won the football last night",
     "I don't have live results because I'm offline. Ask me to look it up and I'll open "
     "a web search for it."),
    ("what's the bitcoin price right now",
     "I can't see live prices because I'm offline. Ask me to search for it and I'll open "
     "a web search."),
]


def example_knowledge(rng: random.Random) -> list[dict]:
    question, answer = rng.choice(KNOWLEDGE)
    if rng.random() < 0.5:
        question = question[0].upper() + question[1:] + "?"
    return [
        {"role": "user", "content": question},
        {"role": "assistant", "content": answer},
    ]


JS_TASKS = [
    ("write a javascript function that returns the largest number in an array",
     "function largest(numbers) {\n"
     "  if (numbers.length === 0) return undefined;\n"
     "  return numbers.reduce((a, b) => (b > a ? b : a));\n"
     "}",
     "largest([3, 17, -4, 9])", "17"),
    ("write a javascript function to count the vowels in a string",
     "function countVowels(text) {\n"
     "  return (text.match(/[aeiou]/gi) || []).length;\n"
     "}",
     "countVowels(\"Hello World\")", "3"),
    ("write a js function that checks whether a number is prime",
     "function isPrime(n) {\n"
     "  if (n < 2) return false;\n"
     "  for (let i = 2; i * i <= n; i++) {\n"
     "    if (n % i === 0) return false;\n"
     "  }\n"
     "  return true;\n"
     "}",
     "[isPrime(1), isPrime(2), isPrime(97), isPrime(91)]", "[false,true,true,false]"),
    ("write a javascript function that reverses the words in a sentence",
     "function reverseWords(sentence) {\n"
     "  return sentence.trim().split(/\\s+/).reverse().join(\" \");\n"
     "}",
     "reverseWords(\"the quick brown fox\")", "fox brown quick the"),
]


def example_javascript(rng: random.Random) -> list[dict]:
    question, function, test, value = rng.choice(JS_TASKS)
    return [
        {"role": "user", "content": question},
        call("run_javascript", {"code": f"{function}\n\n{test}"}),
        result({"action": "run_javascript", "ok": True, "result": value}),
        {"role": "assistant",
         "content": f"```javascript\n{function}\n```\n\n"
                    f"I ran it: `{test}` returns `{value}`."},
    ]


SEARCH_TOPICS = [
    "train times from Leeds to York", "the opening hours of the Science Museum",
    "reviews of the Pixel 10", "the weather in Manchester this weekend",
    "last night's Premier League results", "how to descale a Nespresso machine",
    "cheap flights to Lisbon in October", "the Arsenal fixture list",
]


def example_search_requested(rng: random.Random) -> list[dict]:
    topic = rng.choice(SEARCH_TOPICS)
    request = rng.choice([f"search the web for {topic}", f"look up {topic} online",
                          f"google {topic}", f"can you search {topic}"])
    return [
        {"role": "user", "content": request},
        call("web_search", {"query": topic}),
        handed_off_result(
            "web_search", query=topic,
            outcome="The browser opened with these results. You cannot read them; the user will.",
        ),
        {"role": "assistant", "content": f"I've opened a web search for {topic}."},
    ]


# Invented addresses in real towns. The lesson is to copy the whole address,
# town included, into the right argument, and to ask when the app cannot
# pin the place down rather than let Maps guess.
DIRECTION_STARTS = [
    ("14 Birch Road, Stroud", "14 Birch Rd, Stroud, GL5 1AB, England"),
    ("7 Mill Lane, Ludlow", "7 Mill Ln, Ludlow, SY8 1BB, England"),
    ("52 Queen Street, Bathurst", "52 Queen St, Bathurst NSW 2795, Australia"),
    ("3 Harbour View, Whitby", "3 Harbour View, Whitby, YO21 3PU, England"),
    ("9 Elm Grove, Frankston", "9 Elm Gr, Frankston VIC 3199, Australia"),
    ("21 Chapel Street, Penzance", "21 Chapel St, Penzance, TR18 4AJ, England"),
]

DIRECTION_ENDS = [
    ("Stroud station", "Stroud Station, Station Rd, Stroud, GL5 3AP, England"),
    ("Ludlow Castle", "Ludlow Castle, Castle Sq, Ludlow, SY8 1AY, England"),
    ("Bathurst Hospital", "Bathurst Hospital, Howick St, Bathurst NSW 2795, Australia"),
    ("Whitby Abbey", "Whitby Abbey, Abbey Ln, Whitby, YO22 4JT, England"),
    ("Frankston station", "Frankston Station, Young St, Frankston VIC 3199, Australia"),
    ("the Minack Theatre", "Minack Theatre, Porthcurno, Penzance, TR19 6JU, England"),
]


def example_directions(rng: random.Random) -> list[dict]:
    start_said, start_found = rng.choice(DIRECTION_STARTS)
    end_said, end_found = rng.choice(DIRECTION_ENDS)
    mode = rng.choice(["driving", "driving", "walking", "transit", "cycling"])
    spoken_mode = "" if mode == "driving" else f"{mode} "
    from_here = rng.random() < 0.35

    if from_here:
        request = rng.choice([f"{spoken_mode}directions to {end_said}",
                              f"how do I get to {end_said}",
                              f"take me to {end_said}"])
        arguments = {"destination": end_said}
        start_found = "your current location"
    else:
        request = rng.choice([f"{spoken_mode}directions from {start_said} to {end_said}",
                              f"how do I get from {start_said} to {end_said}",
                              f"get me from {start_said} to {end_said}"])
        arguments = {"origin": start_said, "destination": end_said}
    if mode != "driving":
        arguments["mode"] = mode

    if rng.random() < 0.2:
        # Saved places go through by name; the app knows where they are.
        saved = rng.choice(["home", "work"])
        request = rng.choice([f"{spoken_mode}directions home" if saved == "home" else f"{spoken_mode}directions to work",
                              f"take me {'home' if saved == 'home' else 'to work'}",
                              f"how do I get {'home' if saved == 'home' else 'to work'} from {end_said}"])
        arguments = {"destination": saved}
        from_place = "your current location"
        if request.endswith(end_said):
            arguments = {"origin": end_said, "destination": saved}
            from_place = end_said
        if mode != "driving":
            arguments["mode"] = mode
        return [
            {"role": "user", "content": request},
            call("get_directions", arguments),
            handed_off_result("get_directions", **{"from": from_place if from_place != end_said else end_found,
                                                   "to": saved.capitalize(), "mode": mode}),
            {"role": "assistant",
             "content": f"I've opened Maps with {spoken_mode}directions from {from_place} "
                        f"to {saved}."},
        ]

    if not from_here and rng.random() < 0.2:
        # The town was not enough to single out the place.
        street = start_said.split(", ")[0]
        return [
            {"role": "user", "content": request},
            call("get_directions", arguments),
            result({"ok": False, "action": "get_directions",
                    "error": f"Could not find the starting point \"{start_said}\" exactly. "
                             f"The closest matches were: {street}, Northfield; {street}, "
                             f"Southgate. Ask the user which place they meant, or for the "
                             f"town and postcode. Do not open Maps with a guess."}),
            {"role": "assistant",
             "content": f"I couldn't pin down {start_said}. The nearest matches were in "
                        f"Northfield and Southgate. What's the postcode?"},
        ]

    return [
        {"role": "user", "content": request},
        call("get_directions", arguments),
        handed_off_result("get_directions", **{"from": start_found, "to": end_found,
                                               "mode": mode}),
        {"role": "assistant",
         "content": f"I've opened Maps with {spoken_mode}directions from "
                    f"{'your current location' if from_here else start_said} to {end_said}."},
    ]


# Weighted so the behavioural lessons outnumber the format ones. Plain
# calendar writes are the easiest thing for the model to already do well;
# honesty about friction and refusals are what need reinforcing.
GENERATORS = [
    (example_calendar, 13),
    (example_reminder, 9),
    (example_availability, 8),
    (example_message_drafted, 10),
    (example_message_awaiting, 12),
    (example_email_awaiting, 5),
    (example_ambiguous_contact, 8),
    (example_impossible, 15),
    (example_shortcut, 7),
    (example_call, 6),
    (example_permission_denied, 6),
    (example_multistep, 9),
    # Answering rather than acting. Small template spaces get small weights so
    # each fills its share without a shortfall.
    (example_maths, 14),
    (example_knowledge, 5),
    (example_javascript, 0.4),
    (example_search_requested, 3),
    (example_directions, 5),
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
    verify_notes_match()

    system_prompt = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8").strip()
    verify_prompt_matches(system_prompt)
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
