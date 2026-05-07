# UI-Entwurf: AI Studio Web Interface

**Ziel**: Eine lokale Web-UI, die den gesamten Film-Produktionsprozess abdeckt —
von der Generierung von Trainingsbildern über das LoRA-Training bis hin zur
Szenen-Erstellung und Video-Stitching.

---

## 1. Gesamtpipeline

```
[1] Bilder generieren          [2] Modell trainieren         [3] Film produzieren
 SDXL img2img / FLUX t2i   →   LoRA auf generierten Bildern  →   I2V Workflow (75 Szenen)
 local_pics.py / FLUX UI        (Wan2.1 / SDXL LoRA)              video_script_full_workflow.sh
 Stack: image / image_prompt     Stack: remote training             Stack: video / video_lora
```

Die UI fasst diese drei Phasen in **einem Interface** zusammen, ohne dass der
Nutzer Shell-Befehle kennen muss.

---

## 2. UI-Struktur: Vier Hauptbereiche (Tabs)

```
┌────────────────────────────────────────────────────────────┐
│  AI STUDIO                                    [Stack: ●●○] │
├──────────┬───────────────┬──────────────────┬──────────────┤
│  BILDER  │    TRAINING   │     FILM         │   STACKS     │
└──────────┴───────────────┴──────────────────┴──────────────┘
```

---

## 3. Tab 1 — BILDER

**Zweck**: Trainingsbilder und Referenzbilder für den Film erzeugen.

### 3.1 Modus A — Referenzbild-Dataset (local_pics.py)

Für die Generierung konsistenter Personen-Bilder, die später als `master_images/`
im Video-Workflow dienen.

```
┌─ Referenzbild-Dataset ──────────────────────────────────────────┐
│ Stack: image (SDXL img2img auf Port 7860)                        │
│                                                                  │
│ Init-Bild:     [Datei hochladen]  test.jpg                       │
│ Basis-Prompt:  [Photorealistic portrait of ...]                  │
│ Trigger-Wort:  [sundancer_style]                                 │
│ Anzahl Bilder: [20 ▼]  (20–50 empfohlen)                        │
│ Strength:      [0.55]   Guidance: [1.5]   Steps: [4]            │
│                                                                  │
│ LoRAs:                                                           │
│   [✓] SDXL Lightning (Speed)     Stärke: [1.0]                  │
│   [✓] Add More Details           Stärke: [0.5]                  │
│   [✓] Real Dark Contrast         Stärke: [0.6]                  │
│   [✓] BetterFaces               Stärke: [0.7]                   │
│   [✓] Cinematic Photo            Stärke: [0.5]                  │
│                                                                  │
│ Prompt-Variationen:  ● Auto (Moonshot/Kimi API)  ○ Fallback     │
│ MOONSHOT_API_KEY:    [●●●●●●●●●●●●●●●●●●]                       │
│                                                                  │
│ Ausgabe:  video_training_dataset/images/   (PNG + Caption-TXT)  │
│           [✓] Konsistenz-Video erstellen (consistency_check.mp4)│
│                                                                  │
│                        [▶ Dataset generieren]                    │
│                                                                  │
│ Fortschritt: ████████░░░░  12/20   train_012.png ✓              │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Modus B — FLUX.2 Text-to-Image

Für freie Bild-Generierung, z.B. Environment-Shots oder Einzelbilder.

```
┌─ FLUX.2 Text-to-Image ──────────────────────────────────────────┐
│ Stack: image_prompt (FLUX.2-dev auf Port 7863)                   │
│                                                                  │
│ Prompt:  [Elena in rain-soaked boutique entrance...]             │
│ Width:   [1024]   Height: [1024]   Steps: [28]                  │
│ Guidance:[3.5]    Seed:   [42  ]   [☐ Fix Seed]                 │
│                                                                  │
│ LoRAs (optional):                                                │
│   Slot 1: [FLUX.2 Turbo ▼]  Stärke: [1.0]                      │
│   Slot 2: [Multi-Angles ▼]  Stärke: [0.8]                      │
│                                                                  │
│                        [▶ Bild generieren]                       │
│                                                                  │
│ [ Generiertes Bild ]   [Als Master-Bild speichern ▼]            │
│                         elena_front.png                          │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 Master-Bilder-Verwaltung

Zeigt den aktuellen Zustand von `master_images/` — die 4 Referenzbilder,
die der Video-Workflow benötigt:

```
master_images/
  elena_front.png   [Bild-Preview] [Ersetzen] [Aus Dataset wählen]
  elena_side.png    [Bild-Preview] [Ersetzen] [Aus Dataset wählen]
  markus_front.png  [Bild-Preview] [Ersetzen] [Aus Dataset wählen]
  markus_env.png    [Bild-Preview] [Ersetzen] [Aus Dataset wählen]

  [+ Neues Referenzbild anlegen]   (beliebiger key-Name für neue Charaktere)
```

---

## 4. Tab 2 — TRAINING

**Zweck**: LoRA-Training auf den generierten Bildern, damit der Video-Workflow
konsistente, charaktergetreue Clips erzeugt.

```
┌─ LoRA Training ─────────────────────────────────────────────────┐
│                                                                  │
│ Trainings-Typ:  ● Wan2.1 Video-LoRA  ○ SDXL Image-LoRA         │
│                                                                  │
│ Dataset:        [video_training_dataset/images/]  [Durchsuchen] │
│ Basis-Modell:   [Wan-AI/Wan2.1-T2V-14B-Diffusers ▼]            │
│ LoRA-Name:      [elena_lora_v1]                                  │
│ Trigger-Wort:   [sundancer_style]                                │
│                                                                  │
│ Trainings-Parameter:                                             │
│   Epochen:      [10]    Batch-Size: [1]    LR: [1e-4]           │
│   Rank:         [16]    Alpha:      [32]                         │
│   Resolution:   [512x512 ▼]                                      │
│                                                                  │
│ Stack: video_lora  (H100/H200, min 80GB VRAM, 220GB Disk)       │
│ Status: ○ Stack bereit   ● Stack nicht aktiv                     │
│                          [Stack starten →]                       │
│                                                                  │
│                    [▶ Training starten]                          │
│                                                                  │
│ Training-Log:                                                    │
│   Step 100/1000  loss: 0.042  lr: 9.8e-5                        │
│   Step 200/1000  loss: 0.038  ...                                │
│                                                                  │
│ Fertige LoRAs:                                                   │
│   elena_lora_v1.safetensors  [In Video-Workflow einsetzen]      │
│   markus_lora_v1.safetensors [In Video-Workflow einsetzen]      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. Tab 3 — FILM

**Zweck**: Das Herzstück. Entspricht vollständig `video_script_full_workflow.sh`,
aber mit grafischer Oberfläche.

### 5.1 Workflow-Übersicht (oben)

```
Status-Leiste:
  [1. Init ✓]  →  [2. Validate ✓]  →  [3. Pilot ○]  →  [4. Generieren ○]  →  [5. Stitch ○]
  
  Szenen: 75 definiert    Master-Bilder: 4/4 ✓    Remote: video (H100) ●
```

### 5.2 Workflow-Konfiguration (workflow.conf)

```
┌─ Workflow-Konfiguration ────────────────────────────────────────┐
│ Szenen-Datei:  [scenes.json]    [Neu erstellen aus Blueprint]   │
│ Output-Dir:    [video_output/]                                   │
│                                                                  │
│ Render-Parameter:                                                │
│   FPS:        [24]   Clip-Dauer: [8s]    Steps:    [30]        │
│   Guidance:   [5.0]  Width:      [832]   Height:   [480]        │
│   Seed-Base:  [42]                                               │
│                                                                  │
│ Prompting:                                                       │
│   Color Look:   [Warm gold tones, soft blue neon accents...]    │
│   Camera Style: [cinematic composition, soft focus...]          │
│   Negative:     [blurry, low quality, artifacts, watermark...]  │
│                                                                  │
│ I2V-Modell:   [Wan-AI/Wan2.1-I2V-14B-720P-Diffusers ▼]         │
│                                                                  │
│                     [Konfiguration speichern]                    │
└─────────────────────────────────────────────────────────────────┘
```

### 5.3 Blueprint-Editor (→ scenes.json)

Textfeld mit dem `prnszene.txt`-Format. "Aus Blueprint generieren" ruft
`create_scenes_from_blueprint()` auf:

```
┌─ Blueprint-Editor ──────────────────────────────────────────────┐
│ Datei: prnszene.txt                              [Laden] [Neu]  │
│                                                                  │
│  01                                                              │
│  Elena enters the boutique through rain-soaked glass doors...   │
│  arrival, rain, boutique interior, neon reflections, Elena       │
│                                                                  │
│  02                                                              │
│  Markus stands near the back wall of the atelier...             │
│  Markus, interior portrait, reflective mirrors, quiet tension   │
│                                                                  │
│  [+ Szene hinzufügen]                                           │
│                                                                  │
│              [▶ Szenen-JSON generieren]  (75 Szenen erkannt)    │
└─────────────────────────────────────────────────────────────────┘
```

### 5.4 Szenen-Tabelle (scenes.json Editor)

```
┌─ Szenen ───────────────────────────────────────────────────────────────────────┐
│ [Filter: Alle ▼]  [Akt: Alle ▼]  [Suche: ___________]                         │
│                                                                                 │
│  ID │ Akt │ Status   │ Subject          │ Ref          │ Keywords              │
│  ───┼─────┼──────────┼──────────────────┼──────────────┼──────────────────────│
│   1 │  1  │ ✓ fertig │ Elena            │ elena_front  │ arrival, rain...      │
│   2 │  1  │ ✓ fertig │ Markus           │ markus_front │ interior portrait...  │
│   3 │  1  │ ○ offen  │ Elena            │ elena_side   │ close detail, fabric  │
│   4 │  1  │ ○ offen  │ Elena and Markus │ markus_env   │ two-shot, confrontat  │
│  …  │  …  │   …      │   …              │   …          │   …                   │
│  75 │  5  │ ○ offen  │ Elena and Markus │ markus_env   │ closing, final shot   │
│                                                                                 │
│  [Szene bearbeiten]  [Vorschau-Prompt anzeigen]  [Referenzbild anzeigen]       │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 5.5 Generierungs-Steuerung

```
┌─ Generierung ───────────────────────────────────────────────────┐
│                                                                  │
│  PILOT (Test-Lauf)                                              │
│  Szenen:  [1] bis [10]    [▶ Pilot starten]                     │
│                                                                  │
│  VOLLSTÄNDIG                                                     │
│  Szene:   [all ▼]         [▶ Generierung starten]               │
│           (oder einzelne Szene-ID)                               │
│                                                                  │
│  Aktueller Lauf: 20250410_143022                                 │
│  Fortschritt:    ████████░░░░░░░░  8 / 75 Szenen               │
│  Laufzeit:       ~4h verbleibend (∅ 3.2 min/Szene)             │
│                                                                  │
│  Scene 008 läuft...  [SSH-Log anzeigen]  [Abbrechen]            │
│                                                                  │
│  Generierte Clips:                                               │
│   scene_001.mp4 [▶]   scene_002.mp4 [▶]   scene_003.mp4 [▶]   │
│   scene_004.mp4 [▶]   scene_005.mp4 [▶]   scene_006.mp4 [▶]   │
│   scene_007.mp4 [▶]   scene_008.mp4 [▶ läuft...]               │
└─────────────────────────────────────────────────────────────────┘
```

### 5.6 Stitch (Finaler Film)

```
┌─ Film zusammensetzen ───────────────────────────────────────────┐
│ Lauf:         [20250410_143022 ▼]  (oder neuester)             │
│ Output-Name:  [final_cut_v1.mp4]                                │
│                                                                  │
│ Remote FFmpeg:  ● concat → copy  ○ re-encode (libx264 crf 18)  │
│                                                                  │
│                        [▶ Stitch starten]                        │
│                                                                  │
│ Ergebnis:  video_output/final_cut_v1.mp4  (2.3 GB)             │
│            [▶ Im Browser abspielen]  [Download]                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Tab 4 — STACKS

**Zweck**: Vastai-Instanzen steuern (gekürzte Version des `studio.sh`-Dashboards).

```
┌─ Stack-Übersicht ───────────────────────────────────────────────┐
│  Stack          │ Status    │ GPU      │ $/h  │ Aktionen        │
│  ───────────────┼───────────┼──────────┼──────┼─────────────────│
│  image          │ ● läuft   │ RTX4090  │ 0.89 │ [Tunnel] [Stop] │
│  image_prompt   │ ○ aus      │ —        │  —   │ [Starten]       │
│  video          │ ● läuft   │ H100     │ 3.20 │ [Tunnel] [Stop] │
│  video_lora     │ ○ aus      │ —        │  —   │ [Starten]       │
│  text           │ ○ aus      │ —        │  —   │ [Starten]       │
│                                                                  │
│  [Alle stoppen]   [Kosten-Check]   [Doctor-Modus]               │
└─────────────────────────────────────────────────────────────────┘
```

Stack-Detail-View (aufklappbar):

```
▼ video (H100 · vast-id: 14823 · 3.2$/h)
  IP: 45.23.11.99  Port: 22  Tunnel: localhost:7861
  Disk: 187/220 GB  VRAM: 72/80 GB
  Health: ● HTTP 200  ● SSH OK  ● /onstart.sh vorhanden
  [Logs anzeigen]  [SSH öffnen]  [Repair]
```

---

## 7. Technische Umsetzung

### Stack

| Schicht       | Technologie                    | Warum                              |
|---------------|--------------------------------|------------------------------------|
| Backend       | **FastAPI** (Python)           | Subprocess-Wrapper für bash-Scripts; SSE für Log-Streaming |
| Frontend      | **HTMX + Alpine.js**           | Minimal, kein Build-Step, passt zu bash-first Ansatz |
| Styling       | **Tailwind CSS** (CDN)         | Dark-Theme UI ohne Overhead        |
| Video-Preview | `<video>` HTML5 Tag            | Direkte MP4-Auslieferung           |
| Bild-Preview  | `<img>` mit lazy loading       | —                                  |
| State         | Dateisystem + JSON             | Wie bisher (`.vast_instance_*`, `workflow.conf`, `scenes.json`) |

Alternative (falls mehr Interaktivität gewünscht): **Gradio** (bereits bekannt,
sofort lauffähig) — aber begrenzte Kontrolle über Multi-Step-Workflows.

### API-Endpunkte (FastAPI)

```
GET  /api/stacks                    → Status aller Stacks
POST /api/stacks/{name}/start       → manage_v7_fixed.sh ensure-ready
POST /api/stacks/{name}/tunnel      → SSH-Tunnel öffnen
POST /api/stacks/{name}/stop        → Instance stoppen

GET  /api/workflow/config           → workflow.conf lesen
PUT  /api/workflow/config           → workflow.conf schreiben
GET  /api/workflow/scenes           → scenes.json lesen
PUT  /api/workflow/scenes           → scenes.json schreiben
POST /api/workflow/init             → video_script_full_workflow.sh init
POST /api/workflow/validate         → video_script_full_workflow.sh validate
POST /api/workflow/pilot            → video_script_full_workflow.sh pilot {from} {to}
POST /api/workflow/gen              → video_script_full_workflow.sh gen {id|all}
POST /api/workflow/stitch           → video_script_full_workflow.sh stitch --output ...
GET  /api/workflow/status           → workflow state + remote clip count

GET  /api/images/master             → master_images/ auflisten
POST /api/images/master/{key}       → Referenzbild hochladen/ersetzen
POST /api/images/dataset/generate   → local_pics.py starten (SSE-Stream)

GET  /api/video/{run}/{scene}       → scene_XXX.mp4 ausliefern
```

### Datei-Struktur (neu)

```
ai_studio/
├── ui/
│   ├── main.py              ← FastAPI app
│   ├── routers/
│   │   ├── stacks.py
│   │   ├── workflow.py
│   │   └── images.py
│   ├── static/
│   │   └── app.js           ← Alpine.js komponentente
│   └── templates/
│       ├── base.html
│       ├── bilder.html
│       ├── training.html
│       ├── film.html
│       └── stacks.html
└── docs/
    └── UI_VIDEO_IMAGE_ENTWURF.md  ← dieses Dokument
```

### Log-Streaming

Alle langen Operationen (Dataset-Generierung, Video-Generierung) laufen als
Subprocess und streamen ihren Output per **Server-Sent Events (SSE)** ans Frontend:

```python
@app.get("/api/workflow/gen/stream")
async def gen_stream(scene_id: str):
    async def event_generator():
        proc = await asyncio.create_subprocess_exec(
            "./video_script_full_workflow.sh", "gen", scene_id,
            stdout=PIPE, stderr=STDOUT
        )
        async for line in proc.stdout:
            yield f"data: {line.decode()}\n\n"
    return EventSourceResponse(event_generator())
```

---

## 8. Implementierungs-Phasen

### Phase 1 — Kern (MVP)
- [ ] FastAPI-Backend mit Film-Tab
- [ ] `workflow.conf` Editor
- [ ] Szenen-Tabelle (lesen + bearbeiten)
- [ ] Generierungs-Steuerung mit Log-Streaming
- [ ] Clip-Preview nach Generierung

### Phase 2 — Bilder
- [ ] Master-Bilder-Verwaltung
- [ ] local_pics.py Dataset-Generator mit Progress-Stream
- [ ] FLUX.2 Bild-Generator (Proxy zum Gradio-Backend auf 7863)

### Phase 3 — Stacks
- [ ] Stack-Status-Dashboard
- [ ] Start/Stop/Tunnel-Buttons
- [ ] Health-Indikatoren

### Phase 4 — Training
- [ ] LoRA-Training-Interface
- [ ] Fertige LoRAs in Video-Workflow einbinden
- [ ] SDXL LoRA Upload zu `image`-Stack

---

## 9. Abhängigkeiten zwischen Phasen

```
[BILDER generieren]
   ↓  master_images/ befüllt
[VIDEO validate] → grünes Licht
   ↓
[VIDEO pilot 1–10] → Qualitäts-Check
   ↓
[VIDEO gen all] → 75 Szenen-Clips
   ↓
[VIDEO stitch] → finales MP4

Parallel (optional):
[TRAINING] → eigenes LoRA
   ↓ .safetensors
[VIDEO mit LoRA] → Stack: video_lora
```

---

## 10. Offene Entscheidungen

| Frage | Optionen |
|-------|----------|
| Frontend-Framework | HTMX (minimal) vs. Gradio (schnell) vs. React (komplex) |
| Training-Backend | Eigenes remote script vs. LoRA-Trainer auf video_lora-Stack |
| Charakter-Erweiterung | Mehr als 4 Referenzbilder? Dynamische ref-Keys in scenes.json? |
| Multi-Projekt | Ein `workflow.conf` pro Film? Projekt-Switcher in der UI? |
| Auth | Kein Auth (lokal) oder Basic Auth für Remote-Zugriff? |
