# Integrations-Spike: KI-Provider für Transkription und Textausarbeitung (M0)

| Feld | Wert |
|---|---|
| Datum | 2026-10-30 |
| Bezug | Pflichtenheft C9, H2 B, H3, H4, I; ADR-0008; Abnahme A07–A11, A27, A34 |
| Art | Reine Dokumentationsrecherche. **Keine API-Aufrufe mit Schlüssel ausgeführt**, kein Kontingent verbraucht. |
| Quellen | developers.openai.com (platform.openai.com leitet per 301 dorthin um), platform.claude.com (docs.claude.com/docs.anthropic.com leiten dorthin um), ai.google.dev. Gelesen über die Markdown-Varianten der Seiten (`.md` bzw. `.md.txt`). |

**Statuslegende.** **belegt** = in offizieller Doku nachgelesen; **teilweise** = Doku lückenhaft/widersprüchlich; **nicht belegt** = nicht gefunden, muss per Probe-Request oder Spike geprüft werden.

Hinweis: Die Modelllandschaft ändert sich schnell. Modell-IDs dürfen daher **nicht** fest verdrahtet werden, sondern werden per Models-Endpoint geladen (I, H3: „Modelle dynamisch … capabilities validieren“). Fest kodierte IDs nur als Vorschlags-Default mit Prüfung.

---

## 1. OpenAI Speech-to-Text (H2 B)

| Thema | Befund | Status / Quelle |
|---|---|---|
| Empfohlenes Modell | **`gpt-transcribe`** – „recommended for recorded speech in its original language“; Modellseite: „High-accuracy speech-to-text model for file and Realtime input transcription“ | belegt: https://developers.openai.com/api/docs/guides/speech-to-text, https://developers.openai.com/api/docs/models/gpt-transcribe |
| Live-Diktat | `gpt-live-transcribe` für Realtime-Transkription | belegt: speech-to-text |
| Abgekündigt | `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-transcribe-diarize` und `/v1/audio/translations` werden am **26.02.2027** abgeschaltet | belegt: speech-to-text |
| Snapshots | Nur `gpt-transcribe` gelistet | belegt: models/gpt-transcribe |
| Endpoint | `POST https://api.openai.com/v1/audio/transcriptions` (multipart/form-data), Header `Authorization: Bearer <key>`; `gpt-transcribe` ist auch über `v1/realtime/transcription_sessions` nutzbar, **nicht** über Responses/Chat/Batch | belegt: https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create, models/gpt-transcribe |
| Dateigröße | „Files can be up to 25 MB.“ | belegt: speech-to-text |
| Formate | mp3, mp4, mpeg, mpga, **m4a**, wav, webm | belegt: speech-to-text |
| Max. Dauer | nicht angegeben | nicht belegt |
| Hinweise/Vokabular | `prompt` = unstrukturierter Kontext; **`keywords`** = wörtliche erwartete Begriffe („hints, not required output“), eine Zeile je Keyword, ohne `<`, `>`, CR, LF – sonst wird der ganze Request abgelehnt; **`languages`** (Array) ersetzt `language`, nicht beide senden; zu langer Prompt → Ablehnung (Grenzwert nicht genannt) | belegt: speech-to-text; Promptlänge für `gpt-transcribe`: nicht belegt |
| Multipart-Form | `keywords[]=…`, `languages[]=…` | belegt: speech-to-text (curl-Beispiel) |
| Antwort | JSON mit `text`, `languages` (leeres Array = keine sichere Erkennung), optional `logprobs`, `usage` (`type: "tokens"` mit `input_tokens`, `output_tokens`, `total_tokens`, `input_token_details.audio_tokens/text_tokens` **oder** `type: "duration"` mit `seconds`) | belegt: transcriptions/methods/create |
| Streaming (Datei) | `stream=true` mit `gpt-transcribe`; SSE-Events `transcript.text.delta` und `transcript.text.done` (inkl. `languages`); nicht für `whisper-1` | belegt: speech-to-text |
| Streaming (Mikrofon live) | Realtime-Transkription statt Datei-Streaming | belegt: speech-to-text |
| Zeitstempel | `timestamp_granularities[]` nur für `whisper-1` | belegt: speech-to-text |
| Diarisierung | nur `gpt-4o-transcribe-diarize` (abgekündigt), `response_format=diarized_json`, `chunking_strategy` | belegt: speech-to-text |
| Preis | $0.0045 pro Audiominute | belegt: models/gpt-transcribe (Preise können sich ändern; im UI als „geschätzt“ ausweisen) |
| Rate Limits | Tier „Build“ 5.000 RPM / 2.000.000 TPM, „Launch“ 10.000 RPM, „Grow“ 30.000 RPM | belegt: models/gpt-transcribe |

### 1.1 Chunking-Leitlinie

- Offiziell: Über 25 MB komprimiertes Format nutzen oder in Stücke ≤ 25 MB teilen, **nicht mitten im Satz** trennen (belegt: speech-to-text).
- Umsetzungsvorschlag (abgeleitet): Aufnahme als AAC/m4a mono, 16–24 kHz, 32–48 kbit/s (≈ 14–22 MB/h). Erst ab einer Schwelle (z. B. 24 MB) an Sprechpausen schneiden (Metering/Energie-VAD), Segmente sequenziell senden, als `prompt` den Schluss des vorherigen Segment-Transkripts plus Projektkontext mitgeben, als `keywords` die Projektbegriffe (H2: „ohne als gesprochenen Inhalt zu erfinden“ – Keywords sind laut Doku Hinweise, kein Pflicht-Output).
- Für Live-Text während des Sprechens wäre `gpt-live-transcribe` über Realtime nötig – für v1 nicht erforderlich; Datei-Upload mit optionalem `stream=true` genügt.

**Abgleich Pflichtenheft H2 B:** Das Pflichtenheft nennt `gpt-transcribe` als Beispiel und warnt vor `gpt-4o-transcribe` als Default – **bestätigt**: `gpt-transcribe` ist empfohlen, die `gpt-4o-*-transcribe`-Modelle sind abgekündigt (Abschaltung 26.02.2027).

**Default für v1:** `gpt-transcribe` über `/v1/audio/transcriptions`; Modell-ID trotzdem über `GET /v1/models` gegen den Schlüssel prüfen und `shutdown_date` anzeigen (§2.1).

---

## 2. Textausarbeitung: OpenAI, Anthropic, Google Gemini

### 2.1 Übersicht Endpoints und Auth

| | OpenAI | Anthropic | Google Gemini |
|---|---|---|---|
| Base-URL | `https://api.openai.com/v1` | `https://api.anthropic.com` | `https://generativelanguage.googleapis.com/v1beta` |
| Generierung | `POST /v1/responses` (Responses API) | `POST /v1/messages` | `POST /v1beta/models/{model}:generateContent` **oder** `POST /v1beta/interactions` (Interactions API) |
| Auth-Header | `Authorization: Bearer <key>`; optional `OpenAI-Organization`, `OpenAI-Project` | `Authorization: Bearer <key>` **oder** (Legacy, weiterhin unterstützt) `x-api-key: <key>`; Pflicht `anthropic-version` (aktuell `2026-10-21`); `content-type: application/json` | `x-goog-api-key: <key>` (Doku-Beispiele zeigen teils `?key=` – **nicht verwenden**, Schlüssel gehört nicht in URLs/Logs) |
| Modelle listen | `GET /v1/models` | `GET /v1/models` | `GET /v1beta/models` |
| Quelle | https://developers.openai.com/api/reference/overview, https://developers.openai.com/api/reference/resources/responses/methods/create | https://platform.claude.com/docs/en/api/overview, https://platform.claude.com/docs/en/api/versioning, https://platform.claude.com/docs/en/api/messages | https://ai.google.dev/api/models, https://ai.google.dev/api/generate-content, https://ai.google.dev/gemini-api/docs/api-key, https://ai.google.dev/api/interactions |
| Status | belegt | belegt; **teilweise**: die Messages-Referenz führt `anthropic-version` als „optional“, die API-Übersicht als Pflicht → immer senden | belegt |

### 2.2 Modelle dynamisch listen

**OpenAI** – `GET https://api.openai.com/v1/models` → `{ object: "list", data: [ { id, created, object: "model", owned_by, shutdown_date } ] }`. `shutdown_date` ist `null`, wenn keine Abschaltung angekündigt ist. **Keine Capability-Felder** (kein Hinweis auf Structured Outputs, Kontextlänge oder Preis). Quelle: https://developers.openai.com/api/reference/resources/models/methods/list (belegt).
→ Folge: Für OpenAI braucht die App eine lokal gepflegte Capability-Tabelle oder Fehler-basierte Validierung (400 bei nicht unterstütztem `text.format`). Aktuelle Modellübersicht (Stand Doku): „GPT-6 Astra“ als Flaggschiff, „GPT-6.1 Sol“ (Preis/Leistung), „GPT-6 Luna“ (günstig) – https://developers.openai.com/api/docs/models (belegt; nur als Vorschlag, nie fest verdrahten).

**Anthropic** – `GET https://api.anthropic.com/v1/models`, Query `limit` (1–1000, Default 20), `after_id`/`before_id`, `lifecycle` (`active`, `deprecated`, `retired`; ohne Angabe active + deprecated). Neueste Modelle zuerst. `ModelInfo`: `id`, `display_name`, `created_at`, `lifecycle`, `deprecated_at`, `retires_at`, `line` (`haiku`/`sonnet`/`opus`/`fable`/`mythos`), `max_input_tokens`, `max_tokens` und ein **`capabilities`-Objekt** u. a. mit `structured_outputs.supported`, `effort` (`low`/`medium`/`high`/`xhigh`/`max`), `thinking.types`, `image_input`, `pdf_input`, `batch`. Paginierung über `has_more`, `first_id`, `last_id`. Quelle: https://platform.claude.com/docs/en/api/models/list (belegt). Aktuelle IDs laut Modellübersicht: `claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` – https://platform.claude.com/docs/en/models/overview (belegt).

**Google Gemini** – `GET https://generativelanguage.googleapis.com/v1beta/models`, `pageSize` (Default 50, max. 1000), `pageToken` → `nextPageToken`. `Model`: `name`, `baseModelId`, `version`, `displayName`, `description`, `inputTokenLimit`, `outputTokenLimit`, `supportedGenerationMethods[]`, `thinking` (bool), `temperature`, `maxTemperature`, `topP`, `topK`. Quelle: https://ai.google.dev/api/models (belegt). → Für Textausarbeitung auf Modelle mit `generateContent` in `supportedGenerationMethods` filtern (abgeleitet).

### 2.3 Strukturierte Ausgabe (JSON Schema)

| | OpenAI Responses | Anthropic Messages | Gemini |
|---|---|---|---|
| Parameter | `text: { format: { type: "json_schema", name, schema, strict: true } }` | `output_config: { format: { type: "json_schema", schema } }` (GA, kein Beta-Header mehr; Abschnitt „Migrating from the beta“) | generateContent: `generationConfig.responseMimeType = "application/json"` + `responseJsonSchema` (Alternative `responseSchema` = OpenAPI-Subset). Interactions: `response_format: { type: "text", mime_type: "application/json", schema }` |
| Verfügbarkeit | „starting with GPT-4o“; ältere Modelle nur JSON-Mode | „available on every model“; zusätzlich pro Modell `capabilities.structured_outputs` | „subset of the JSON Schema specification“ |
| Schema-Regeln | alle Felder `required` (optional via Union mit `null`); `additionalProperties: false` in jedem Objekt Pflicht; max. 5000 Properties, 10 Ebenen, 1000 Enum-Werte | `additionalProperties` muss `false` sein; keine rekursiven Schemas, keine `minimum`/`maximum`/`minLength`/`maxLength`; `minItems` nur 0/1; Komplexitätsgrenzen: 24 optionale Parameter, 16 Union-Parameter pro Request | `minLength`, `maxLength`, `minProperties`, `maxProperties`, `uniqueItems`, `contains` werden **ignoriert**; `minimum`/`maximum`, `minItems`/`maxItems`, `enum`, `format` unterstützt; zu komplexe Schemas → `400 INVALID_ARGUMENT` |
| Ablehnung / Abbruch | Refusal-Content-Item `type: "refusal"`; unvollständig bei Token-Limit → Status prüfen | `stop_reason: "refusal"` (HTTP 200, abgerechnet), `stop_reason: "max_tokens"` → evtl. unvollständig; Enum-Groß-/Kleinschreibung nicht garantiert → case-insensitiv vergleichen | „always validate values in your application“ |
| Quelle | https://developers.openai.com/api/docs/guides/structured-outputs (Abschnitt „Supported schemas“) | https://platform.claude.com/docs/en/build-with-claude/structured-outputs | https://ai.google.dev/gemini-api/docs/structured-output, https://ai.google.dev/api/generate-content (GenerationConfig) |
| Status | belegt | belegt | belegt |

**Folgerung (abgeleitet):** Ein gemeinsames „Draft“-Schema für H3 (Typ, Titel, Ziel, Kontext, Akzeptanzkriterien, Testfälle, Rückfragen …) muss im **kleinsten gemeinsamen Nenner** formuliert werden: alle Felder `required`, Optionalität über `["string","null"]`, `additionalProperties: false`, keine Längen-/Zahlen-Constraints (die werden lokal validiert), wenige Union-Felder (Anthropic-Limit 16), flache Struktur. Ergebnis immer lokal gegen das Schema validieren, Refusal/Abbruch als eigenen Fehlerzustand anzeigen.

**Sampling-Parameter nicht senden:** Anthropic-Version `2026-10-21` entfernt `temperature`, `top_p`, `top_k` (400-Fehler auf jedem Modell) (belegt: https://platform.claude.com/docs/en/api/versioning); Gemini 4 und 3.6+ ignorieren eigene Werte dafür (belegt: https://ai.google.dev/gemini-api/docs/troubleshooting).

**Gemini – welche API?** Google nennt die Interactions API „recommended standard API for all new projects“; der Guide sagt zugleich „currently in Beta … subject to breaking changes“, die Referenz erwähnt eine stabile v1-Variante (teilweise widersprüchlich: https://ai.google.dev/gemini-api/docs/interactions, https://ai.google.dev/api/interactions). `generateContent` bleibt für bestehende Integrationen dokumentiert. **Vorschlag:** v1 auf `generateContent` (stabile, gut dokumentierte Felder) und Interactions per Spike evaluieren.

### 2.4 Usage-Felder für Kostenanzeige

| Provider | Felder | Quelle |
|---|---|---|
| OpenAI Responses | `usage.input_tokens`, `usage.input_tokens_details.cached_tokens` / `cache_write_tokens`, `usage.output_tokens`, `usage.output_tokens_details.reasoning_tokens`, `usage.total_tokens` | https://developers.openai.com/api/reference/resources/responses/methods/create (belegt) |
| OpenAI Transkription | `usage` als Tokens (inkl. `audio_tokens`) oder `duration.seconds` | §1 (belegt) |
| Anthropic | `usage.input_tokens`, `usage.output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens_details`, `service_tier` (`standard`/`priority`/`batch`) | https://platform.claude.com/docs/en/api/messages (belegt) |
| Gemini generateContent | `usageMetadata.promptTokenCount`, `cachedContentTokenCount`, `candidatesTokenCount`, `toolUsePromptTokenCount`, `thoughtsTokenCount`, `totalTokenCount` | https://ai.google.dev/api/generate-content (belegt) |
| Gemini Interactions | `usage.total_input_tokens`, `total_output_tokens`, `total_thought_tokens`, `total_tokens` | https://ai.google.dev/api/interactions (belegt) |

**Kosten:** Keiner der drei Models-Endpoints und keine der Antworten liefert einen Geldbetrag oder Preis (belegt durch die Feldlisten oben). Kosten können nur als **Schätzung** aus Token/Minuten × lokal gepflegter Preistabelle angezeigt werden (H3 „geschätzte API-Kosten“). Reasoning-/Thinking-Tokens separat ausweisen. Preistabelle mit Stand-Datum versionieren.

### 2.5 Rate Limits, Retry, Fehler

**OpenAI** (belegt: https://developers.openai.com/api/docs/guides/rate-limits, https://developers.openai.com/api/docs/guides/error-codes)
- Header: `Retry-After`, `x-ratelimit-limit-requests`, `x-ratelimit-limit-tokens`, `x-ratelimit-remaining-requests`, `x-ratelimit-remaining-tokens`, `x-ratelimit-reset-requests`, `x-ratelimit-reset-tokens`, bei Projekt-Limits zusätzlich `x-ratelimit-*-project-tokens`.
- `Retry-After` als Mindestwartezeit plus Jitter; fehlt er → exponentielles Backoff mit Jitter; Versuche und Gesamtzeit deckeln; **Quota-/Billing-Fehler nicht wiederholen**.
- 429-Varianten: `slow_down` (`rate_limit_error`), „Rate limit reached“, `credit_balance_exhausted`, `organization_spend_limit_exceeded`, `project_spend_limit_exceeded`; 503 `server_is_overloaded`. → Status **und** `error.code` auswerten.
- 401 bei falschem/ungültigem Schlüssel; `x-request-id` loggen (ohne Schlüssel).

**Anthropic** (belegt: https://platform.claude.com/docs/en/api/rate-limits, https://platform.claude.com/docs/en/api/errors)
- Header: `retry-after`, `anthropic-ratelimit-requests-{limit,remaining,reset}`, `anthropic-ratelimit-tokens-{…}`, `anthropic-ratelimit-input-tokens-{…}`, `anthropic-ratelimit-output-tokens-{…}`; Reset-Zeiten im RFC-3339-Format.
- Achtung: 429 wegen erreichtem **Spend-Cap** hat **keinen** `retry-after` und scheitert bis zur Freigabe weiter → nicht automatisch wiederholen.
- Fehler: 400 `invalid_request_error` (auch selbst gesetztes Spend-Limit), 401 `authentication_error`, 402 `billing_error`, 403 `permission_error`, 404, 413 `request_too_large`, 429 `rate_limit_error`, 500 `api_error`, 504 `timeout_error`, 529 `overloaded_error`.

**Gemini** (belegt: https://ai.google.dev/gemini-api/docs/rate-limits, https://ai.google.dev/gemini-api/docs/troubleshooting)
- Limits RPM/TPM/RPD **pro Projekt, nicht pro Schlüssel**; RPD-Reset um Mitternacht Pacific Time.
- `429 RESOURCE_EXHAUSTED` / `503 UNAVAILABLE` → exponentielles Backoff mit Jitter; nur 429, 408, 5xx wiederholen, nicht 400/402/403.
- Rate-Limit-Response-Header oder ein `Retry-After` sind in den gelesenen Seiten **nicht dokumentiert** (nicht belegt).

### 2.6 Günstige Schlüsselprüfung („Schlüssel prüfen“, I)

| Provider | Aufruf | Bewertung |
|---|---|---|
| OpenAI | `GET /v1/models` mit Bearer-Key → 200 = gültig, 401 = ungültig | erzeugt keine Modell-Tokens (abgeleitet: reiner Listen-Endpoint). Ob ein projektbeschränkter Schlüssel die Modelle listet, aber z. B. `/audio/transcriptions` nicht darf, ist nicht belegt → zusätzlich prüfen, ob `gpt-transcribe` in der Liste steht. |
| Anthropic | `GET /v1/models?limit=1` | wie oben; liefert zugleich Capabilities |
| Gemini | `GET /v1beta/models?pageSize=1` mit `x-goog-api-key` | wie oben |

Alle drei sind Listen-Endpoints ohne Generierung → keine Token-Kosten (abgeleitet; ausdrücklich „kostenlos“ wird es in keiner der gelesenen Seiten genannt).

---

## 3. Belegt vs. unsicher – Zusammenfassung

**Belegt:** `gpt-transcribe` existiert und wird empfohlen; `gpt-4o-transcribe`/`-mini`/`whisper-1` abgekündigt (Abschaltung 26.02.2027); 25 MB; Formate inkl. m4a; `prompt`/`keywords`/`languages`; Datei-Streaming per `stream=true`; Models-Endpoints aller drei Provider mit Feldern; JSON-Schema-Parameter und Einschränkungen; Usage-Felder; Rate-Limit-Header OpenAI/Anthropic; Anthropic `anthropic-version: 2026-10-21` entfernt Sampling-Parameter.

**Unsicher / nicht belegt:**
- maximale Audiodauer und maximale `prompt`-Länge bei `gpt-transcribe`;
- Gemini-Rate-Limit-Header/Retry-Hinweise;
- Status der Gemini Interactions API (Beta vs. „stable v1“);
- ob Listen-Endpoints garantiert kostenlos sind und ob sie Berechtigungen einzelner Endpoints widerspiegeln;
- Pflichtigkeit von `anthropic-version` (Referenz vs. Übersicht widersprüchlich → immer senden);
- OpenAI liefert keine Modell-Capabilities → Capability-Tabelle/Probe nötig.

## 4. Abgleich mit Pflichtenheft/ADRs

- **H2 B:** bestätigt (`gpt-transcribe` als Default).
- **H3 / I „Modelle dynamisch … capabilities validieren“:** Anthropic liefert Capabilities, Gemini teilweise (`supportedGenerationMethods`, `thinking`, Token-Limits), **OpenAI nicht** → für OpenAI ist „dynamisch“ nur für die Existenz eines Modells belastbar; Capabilities via gepflegter Tabelle plus Fehlerauswertung. Im UI so ausweisen (keine stillen Fallbacks, analog ADR-0006).
- **H3 „Kostenanzeige“:** nur Schätzung möglich, da keine Preis-APIs (s. §2.4).
- **ADR-0008:** keine Widersprüche; getrennte Konfiguration Transkription/Ausarbeitung passt zu getrennten Endpoints und Limits.
