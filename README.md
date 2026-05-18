# ClassroomGemms

**One teacher. One classroom. One private Gemma for every student.**
Everyone learns at their own pace without overwhelming teachers.

ClassroomGemms is a LAN-paired classroom app that gives each student their own
on-device Gemma tutor, while the teacher runs the lesson from a single Mac at
the front of the room. Lessons, answers, grades, and follow-up practice never
leave the school's network. No cloud accounts. No student data harvesting.
No "free for districts, monetized for everyone else."

Just a teacher on Mac, a roster of student iPhones, and a model on every device.

---

## Why ClassroomGemms

Personalized learning has been promised for a decade and delivered as a
dashboard. ClassroomGemms takes the opposite bet:

- **A model per student, not a model per district.** Every student device runs
  its own Gemma-4 instance. The tutor that helps one student through fractions
  isn't shared, throttled, or rate-limited by the rest of the class.
- **The teacher is the host, not a spectator.** The Mac at the front of the
  room is the lesson host: it pushes prompts to every student, watches answers
  arrive live, grades with AI assistance, and exports results. There is no
  third-party LMS in the loop.
- **Private by construction.** Audio is transcribed on the student's device.
  Answers travel over the local network to the teacher's Mac. Nothing is sent
  to OpenAI, Anthropic, Google, or any analytics endpoint. If the school's
  internet drops, class continues.
- **Personalized that actually means personalized.** When the lesson ends, the
  student's on-device Gemma keeps going — grouped by subject, scoped to the
  lessons that student has actually completed, available even on the bus ride
  home with the iPad in airplane mode.

---

## What the teacher gets (`agent_mac`)

A macOS app that turns one laptop into the classroom's nerve center.

- **Lesson authoring pane.** Build lessons step-by-step with free-response,
  short-answer, and multiple-choice questions. Add teacher notes. Set answer
  keys for AI-assisted grading. Pick a `correctOptionIndex` on multiple choice
  for an instant no-LLM grading fast path.
- **Import from anywhere.** Drag in a PDF and the authoring pane will extract
  text so you can carve it into prompts — useful for handouts, worksheets, or
  last year's quiz you finally want to reuse.
- **Starter lessons.** Ships with a pack of ready-to-run lessons so a new
  teacher can be live with a class in under a minute.
- **Library + saved lessons.** Every lesson is JSON on disk under
  `<app support>/lessons/<id>.json`. Save, edit, duplicate, delete.
- **Live class pane.** Start a lesson and the roster lights up in real time:
  who's connected, who's still typing, who's answered. Advance to the next
  step when you're ready; broadcast a clear-step signal if a question needs to
  be re-asked.
- **Gradebook.** Per-student, per-step view of every answer with grades. AI
  grading is offered for free/short answers when an expected answer is set;
  multiple choice grades itself.
- **CSV export.** Pull the gradebook out when you need to drop scores into the
  school's official system.
- **Teacher chat bar.** A direct line to the Mac's Gemma for authoring help
  ("rewrite this for 5th graders," "give me three more options") or for
  desktop automation when you want to script around the lesson.
- **Roster + pairing.** First time a student device knocks, the teacher
  approves it. After that the pairing persists. No login flow, no QR-code
  ceremony.

### Under the hood

- macOS-tier model: **`gemma-4-e4b-it`** by default, with a tool-capable
  fallback so the planner loop keeps working if the preferred weights aren't
  available.
- Sessions persist as `SessionRecord` JSON, mutated in place with debounced
  writes — pull the laptop's power and the class state is still on disk.
- A vendored `cactus_patched` package adds a `modelPath` bypass so models
  load from a pre-extracted directory, no slug-and-registry detour.

---

## What every student gets (`voice_ios`)

An iOS app with two tabs and zero accounts.

### Active class
The live lesson surface. The teacher pushes a prompt and it lands instantly.

- **Push-to-talk answers, transcribed on-device.** Hold the button, speak,
  release. Gemma-4 transcribes the WAV locally and the cleaned answer is sent
  to the teacher.
- **Type when speaking isn't an option.** Standard text input is always there.
- **Multiple choice with tap targets.** Clean, accessible, no scrolling for
  the right option.
- **Follows the teacher's pace.** Step advances, clear-step events, and
  end-of-lesson signals stream in over the LAN with a monotonically
  increasing sequence so nothing is missed or replayed twice.

### Tutor
Where personalization actually shows up.

- After class ends, the lessons the student completed show up under their
  subject in the Tutor tab.
- Tapping a subject opens a one-to-one chat with the student's own on-device
  Gemma, **scoped to what that student has worked on**. Their tutor doesn't
  know what the kid across the room studied; it knows what *this* student has
  done and what they got wrong.
- Works offline. The Mac doesn't need to be on. The school Wi-Fi doesn't need
  to be up.

### Under the hood

- iOS-tier model: **`gemma-4-e2b-it`**. Pinned, with strict failure if it
  can't be loaded — no silent fall-through to a different model behind the
  student's back.
- Local persistence covers completed lessons per subject so the Tutor tab is
  ready offline.
- Send-only LAN client: the iOS app never hosts an inbound server. Students
  can't accidentally become the teacher.

---

## How they talk to each other

The control plane is intentionally tiny so it stays auditable.

- **Discovery:** UDP multicast on `224.0.0.167:53317`, announcements every
  5 seconds. Students see the teacher, the teacher sees students. No mDNS
  servers, no Bonjour quirks across school subnets that don't allow them.
- **Pairing:** fingerprint-based. First inbound call from a new device pops
  an approval dialog on the Mac. Once approved, the pairing is stored in
  `<app support>/lan_pairings.json` and the device is trusted.
- **Lesson events:** the teacher publishes a `ClassroomEvent` stream with
  monotonic sequence numbers. Each event is either a `LessonPrompt` (next
  question with its options/format) or a `ClassroomControl` (start, advance,
  clear-step, end). Students poll for the events newer than the last sequence
  they saw — survives a momentary Wi-Fi blip without losing the lesson.
- **Student answers:** `StudentResponse` JSON over HTTP, identified by the
  student's fingerprint and alias. The teacher's `AgentCore` slots it into
  the live roster and the session record.

That's the whole protocol. Read the wire types in
`packages/agent_protocol/lib/src/`.

---

## Privacy, in concrete terms

| Concern | ClassroomGemms behavior |
| --- | --- |
| Where does student audio go? | Stays on the student's device. Transcribed by on-device Gemma, written to a temp file, deleted after submission. |
| Where do answers go? | Over the LAN to the teacher's Mac. Never uploaded anywhere. |
| Where do grades live? | JSON on the teacher's Mac under `<app support>/sessions/` and `<app support>/lessons/`. The teacher chooses when to export. |
| Are model calls logged anywhere? | No. Inference is local on both sides. |
| Does it need internet? | Only the first time, to download the Gemma weights. After that, fully offline. |
| Accounts? | None. Device identity is a local fingerprint stored on each device. |

---

## Run the demo

ClassroomGemms ships with a one-command demo flow that preloads Gemma-4 onto your
Mac and your booted iOS Simulator, then launches both apps wired together.

```sh
./run_gemma_demo.command            # boots an iOS Simulator first
./run_gemma_demo.command --force-refresh    # re-pull model weights
```

This single command:

1. Preloads `gemma-4-e2b-it` into `<repo>/.demo-models`
2. Builds and launches `agent_mac` (teacher) with the demo defines
3. Builds `voice_ios` (student) for the booted simulator with matching defines
4. Installs the student app, resolves the simulator container, copies the
   extracted model into the app sandbox, and launches it

Just want to refresh the weights without launching anything?

```sh
./preload_gemma_demo.command
./preload_gemma_demo.command --force-refresh
```

Other helpers:

```sh
./rebuild_mac.command       # rebuild just the teacher app
./rebuild_both.command      # rebuild teacher + student
./kill_agent_mac.command    # cleanly stop the teacher app
```

### Demo paths

- Host preload root: `<repo>/.demo-models`
- Host model path: `<repo>/.demo-models/gemma-4-e2b-it`
- Simulator model path: `Library/Application Support/gemma4_demo/gemma-4-e2b-it`

Demo mode is strict: if the preloaded model is missing or invalid, both apps
halt and point you back at `./preload_gemma_demo.command`. No silent fallback,
no surprise downloads mid-class.

---

## What's in the box

```
apps/
  agent_mac/        macOS teacher host — authoring, live class, gradebook
  voice_ios/        iOS student app — active class + personal tutor
packages/
  agent_protocol/   wire types: Lesson, LessonPrompt, StudentResponse, ClassroomEvent
  agent_llm/        Gemma bootstrap, HF downloader, ReAct loop, mic recorder
  lan_transport/    identity, pairing, multicast discovery, HTTP client/server
  automation_core/  macOS tool surface used by the teacher chat bar
  cactus_patched/   vendored Cactus SDK with modelPath + quantization bypass
  localsend_common/ vendored LocalSend types (reserved, not on the hot path)
docs/
  system-design.md  deeper architectural notes
```

---

## Built for the real classrooms

- **Flutter `3.41.7` / Dart `3.11.5`** across the whole workspace
- `flutter analyze` from the repo root checks every app and package at once
- Unit tests cover lesson authoring drafts, the lesson draft parser, starter
  lessons, PDF text extraction, the student lesson page, gradebook flow,
  intent handling, and runtime model-profile selection
- `apps/agent_mac` includes a debug/operator UI for firing intents and
  rehearsing lessons without a student device on the LAN
- See `AGENTS.md` for cloud-CI guardrails (no `macos`/`ios` builds in Linux
  containers — analysis + package tests only)

---

## Powered by Cactus Flutter + Gemma 4

ClassroomGemms runs entirely on-device using the [Cactus Flutter](https://github.com/cactus-compute/cactus)
framework — a local-first inference SDK that exposes `CactusLM` (text + vision)
and `CactusSTT` (Whisper speech-to-text) as plain Dart APIs over a native
`llama.cpp`-based runtime. Both the teacher Mac and every student iPhone load
their model through the same Cactus pipeline; no remote endpoint, no per-token
API bill, no SaaS dependency for class to start.

The models themselves are Google's **Gemma 4** family:

| Device | Model | Why |
| --- | --- | --- |
| Student iPhone | `gemma-4-e2b-it` | Small enough to run comfortably on iOS with headroom for STT and the UI; pinned with strict failure if it can't load. |
| Teacher Mac | `gemma-4-e4b-it` | Larger context and stronger reasoning for AI-assisted grading, lesson authoring help, and the desktop automation chat bar. Falls back to a tool-capable sibling if the preferred weights aren't on disk. |

Gemma 4 was chosen specifically because the E2B / E4B instruction-tuned
variants are small enough to live on a student device, license-clean for
school deployment, and tool-call-capable on the teacher side — so the same
model family powers both the live tutor and the lesson-authoring planner.

---

## TL;DR

ClassroomGemms is the rare classroom tool where personalization isn't a buzzword
and privacy isn't a marketing claim. Every student gets their own Gemma. The
teacher runs the room from a Mac. Everything happens on the LAN. Class
continues when the internet doesn't.
