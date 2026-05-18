# How this repo makes the model registry find `gemma-4-e2b-it`

Companion to [`cactus-model-registry-findings.md`](./cactus-model-registry-findings.md). That doc explains *why* the stock `cactus-react-native@1.13.1` SDK cannot see `Cactus-Compute/gemma-4-E2B-it`. This doc explains *how* this repo patches around that so `useCactusLM({ model: 'gemma-4-e2b-it' })` actually resolves, downloads, and loads the weights.

---

## 1. The obstacle, in one paragraph

`getRegistry()` in the upstream SDK hard-requires **both** `weights/<name>-int4.zip` **and** `weights/<name>-int8.zip` in the Hub repo. The `Cactus-Compute/gemma-4-E2B-it` repo only ships int4 weights, so the stock filter drops it before it ever reaches the registry map. Even if it didn't, the `CactusModel` type makes both quantizations required, and `CactusLM` defaults to `int8` — an int4-only model would still fail download.

---

## 2. The fix: a `patch-package` diff against `cactus-react-native@1.13.1`

The single mechanism that allows discovery is [`patches/cactus-react-native+1.13.1.patch`](../patches/cactus-react-native+1.13.1.patch), applied automatically on install via the `postinstall` hook in [`package.json:11`](../package.json):

```json
"postinstall": "patch-package"
```

`patch-package` rewrites files inside `node_modules/cactus-react-native/…` after `npm install`, so every developer and CI build gets the fix deterministically without forking the SDK.

The patch touches four files (both the compiled `lib/module/*.js` and the unshipped `src/*.ts` sources, plus the typings in `lib/typescript/`). Conceptually it makes four coordinated changes.

### 2.1 Relax the registry filter (`modelRegistry.ts`)

Upstream rejected repos missing *either* quantization:

```ts
if (!weights.some(f => f.endsWith('-int4.zip')) ||
    !weights.some(f => f.endsWith('-int8.zip'))) return;
```

Patched to reject only when *both* are missing ([`patches/…+1.13.1.patch:27-29`](../patches/cactus-react-native+1.13.1.patch) / mirror in [`ref/cactus-react-native/src/modelRegistry.ts:67-69`](../ref/cactus-react-native/src/modelRegistry.ts)):

```ts
const hasInt4 = weights.some(f => f.endsWith('-int4.zip'));
const hasInt8 = weights.some(f => f.endsWith('-int8.zip'));
if (!hasInt4 && !hasInt8) return;
```

### 2.2 Derive the slug from whichever zip exists

The registry key is the zip basename with `weights/` and the quant suffix stripped. Upstream only looked at the int4 zip, so an int8-only repo would NPE; an int4-only repo happened to work here but the code wasn't written for it. Patched code picks whichever variant is present and uses a regex suffix strip ([`ref/…/modelRegistry.ts:74-79`](../ref/cactus-react-native/src/modelRegistry.ts)):

```ts
const primary = (hasInt4
  ? weights.find(f => f.endsWith('-int4.zip'))
  : weights.find(f => f.endsWith('-int8.zip')))!;
const key = primary.replace('weights/', '').replace(/-int[48]\.zip$/, '');
```

For `Cactus-Compute/gemma-4-E2B-it`, whose Hub repo contains `weights/gemma-4-e2b-it-int4.zip`, this yields the slug **`gemma-4-e2b-it`**.

### 2.3 Build a partial `quantization` object

Instead of always emitting both `int4` and `int8`, each key is populated only when the matching zip exists ([`ref/…/modelRegistry.ts:97-121`](../ref/cactus-react-native/src/modelRegistry.ts)):

```ts
const quantization: CactusModel['quantization'] = {};
if (hasInt4) { quantization.int4 = { sizeMb: …, url: `${base}-int4.zip`, … }; }
if (hasInt8) { quantization.int8 = { sizeMb: …, url: `${base}-int8.zip`, … }; }
registry[key] = { slug: key, capabilities: …, quantization };
```

### 2.4 Loosen the `CactusModel` type

`types/common.ts` previously required both fields. The patch marks them optional so TypeScript users don't have to assert their way around int4-only entries:

```ts
quantization: {
  int4?: { sizeMb: number; url: string; pro?: { apple: string } };
  int8?: { sizeMb: number; url: string; pro?: { apple: string } };
}
```

### 2.5 Set the right default quantization for `gemma-4-e2b-it`

`CactusLM`'s `defaultOptions.quantization` is `'int8'`. That alone would still break: discovery now works, but `download()` would read `registry['gemma-4-e2b-it'].quantization.int8` → `undefined` → "Model … with specified options not found". The patch adds entries to `quantizationExceptions` so the constructor picks `int4` when the caller doesn't specify ([`ref/cactus-react-native/src/classes/CactusLM.ts:43-49`](../ref/cactus-react-native/src/classes/CactusLM.ts) and patched copy in `node_modules/cactus-react-native/lib/module/classes/CactusLM.js`):

```ts
private static readonly quantizationExceptions: { [m: string]: 'int4' | 'int8' } = {
  'gemma-3-270m-it': 'int8',
  'functiongemma-270m-it': 'int8',
  'gemma-4-e2b-it': 'int4',   // added by patch
  'gemma-4-e4b-it': 'int4',   // added by patch
  'gemma-3n-e2b-it': 'int4',  // added by patch
  'youtu-llm-2b': 'int4',     // added by patch
};
```

The constructor resolves quantization as `options?.quantization ?? quantizationExceptions[model] ?? defaultOptions.quantization` ([`CactusLM.ts:60-63`](../ref/cactus-react-native/src/classes/CactusLM.ts)), so `new CactusLM({ model: 'gemma-4-e2b-it' })` transparently lands on int4.

---

## 3. End-to-end flow when the app starts

Given [`App.tsx:18`](../App.tsx) (`const MODEL = 'gemma-4-e2b-it'`) and [`App.tsx:80`](../App.tsx) (`useCactusLM({ model: MODEL })`):

1. **Hub catalog fetch.** `getRegistry()` hits `https://huggingface.co/api/models?author=Cactus-Compute&full=true` once and memoizes the `Promise` ([`modelRegistry.ts:7-9, 44-50`](../ref/cactus-react-native/src/modelRegistry.ts)).
2. **Partial-quant filter (patched).** For each repo it keeps those with at least one of `weights/*-int4.zip` / `weights/*-int8.zip`. `Cactus-Compute/gemma-4-E2B-it` passes because of `weights/gemma-4-e2b-it-int4.zip`.
3. **Version pin.** `resolveWeightVersion(id)` fetches `…/refs`, parses semver-like tags, drops tags newer than `RUNTIME_VERSION = '1.13.1'` ([`modelRegistry.ts:3, 24-42`](../ref/cactus-react-native/src/modelRegistry.ts)), and picks the newest ≤ runtime.
4. **Slug + URL.** Slug `gemma-4-e2b-it`; download URL `https://huggingface.co/Cactus-Compute/gemma-4-E2B-it/resolve/<version>/weights/gemma-4-e2b-it-int4.zip`.
5. **Size.** A second Hub call to `…/tree/<version>/weights` reads `size` for the zip and converts to MB.
6. **Registry entry.** `registry['gemma-4-e2b-it'] = { slug, capabilities, quantization: { int4: { url, sizeMb, … } } }` — no `int8` key.
7. **Default quantization.** Constructor picks `int4` via `quantizationExceptions` ([`CactusLM.ts:48`](../ref/cactus-react-native/src/classes/CactusLM.ts)).
8. **Download.** `CactusLM.download()` looks up `registry[model].quantization.int4.url`, then calls `CactusFileSystem.downloadModel(getModelName(), url, onProgress)` ([`CactusLM.ts:88-101`](../ref/cactus-react-native/src/classes/CactusLM.ts)). `getModelName()` returns `"gemma-4-e2b-it-int4"` ([`CactusLM.ts:302-304`](../ref/cactus-react-native/src/classes/CactusLM.ts)); the native side stores it at `Documents/cactus/models/gemma-4-e2b-it-int4/` (iOS) or `filesDir/cactus/models/gemma-4-e2b-it-int4/` (Android) and unzips in place.
9. **Init & infer.** `init()` resolves the on-disk path and hands it to the native `cactus.init(...)` bridge; `complete({ messages, audio, onToken })` streams tokens from the locally loaded Gemma-4 E2B weights.

---

## 4. Which files actually matter

| Role | Path |
| --- | --- |
| The patch that enables discovery | [`patches/cactus-react-native+1.13.1.patch`](../patches/cactus-react-native+1.13.1.patch) |
| Install-time applier | `postinstall: patch-package` in [`package.json:11`](../package.json) |
| Registry source of truth (reference copy) | [`ref/cactus-react-native/src/modelRegistry.ts`](../ref/cactus-react-native/src/modelRegistry.ts) |
| Default-quant table (reference copy) | [`ref/cactus-react-native/src/classes/CactusLM.ts:43-49`](../ref/cactus-react-native/src/classes/CactusLM.ts) |
| Typed model shape | [`ref/cactus-react-native/src/types/common.ts`](../ref/cactus-react-native/src/types/common.ts) |
| Consumer | [`App.tsx:18,80`](../App.tsx) |
| Integration guard | [`ref/cactus-react-native/src/__tests__/huggingface-gemma.integration.test.ts`](../ref/cactus-react-native/src/__tests__/huggingface-gemma.integration.test.ts) |

The runtime code is the compiled JS under `node_modules/cactus-react-native/lib/module/`; the `ref/` tree is a pristine reference mirror of the SDK source so diffs are readable — the patch modifies both so the compiled output and the `.ts`/`.d.ts` sources stay in sync.

---

## 5. Invariants worth remembering

- **Slug ≠ Hub id.** `useCactusLM({ model: … })` takes the registry slug `gemma-4-e2b-it`, not `Cactus-Compute/gemma-4-E2B-it`.
- **The patch is load-bearing.** Blow away `node_modules` without running `postinstall`, or bump `cactus-react-native` past `1.13.1` without refreshing the patch, and `gemma-4-e2b-it` disappears from the registry again — same failure mode the findings doc described.
- **int4-only is tolerated, not preferred.** If upstream later publishes int8 weights for this repo, the patched registry will simply expose both; the `quantizationExceptions` default still pins int4 unless a caller passes `options.quantization` explicitly.
- **Local file paths bypass all of this.** `CactusLM.isModelPath` ([`CactusLM.ts:298-300`](../ref/cactus-react-native/src/classes/CactusLM.ts)) short-circuits for `file://` or `/…` model strings, so absolute paths work even without a registry entry.
