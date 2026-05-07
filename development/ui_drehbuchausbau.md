# UI Drehbuch-Ausbau: Entwicklungsplan

## Ziel
Erweiterung der AI Studio WebUI um einen "Text"-Tab zur Drehbuch-Generierung mit dem lokalen LLM. Ein Film besteht aus mehreren Einzelclips (Szenen), die durch ein von einer Text-LLM erstelltes Drehbuch verbunden werden.

---

## Phase 1: Navigation & UI-Grundgerüst

### 1.1 Navigation erweitern
**Dateien:** `templates/dashboard.html`, `templates/film.html`, `templates/images.html`, `templates/training.html`, `templates/stacks.html`

**Aufgaben:**
- Neuen "Text"-Link in die Navigation aller Templates einfügen
- Reihenfolge: Dashboard | Film | Bilder | **Text** | Training | Stacks
- Aktive Tab-Highlighting entsprechend erweitern

**Checkliste:**
- [ ] dashboard.html: Link in Top-Navigation hinzufügen
- [ ] film.html: Link in Top-Navigation hinzufügen
- [ ] images.html: Link in Top-Navigation hinzufügen
- [ ] training.html: Link in Top-Navigation hinzufügen
- [ ] stacks.html: Link in Top-Navigation hinzufügen

### 1.2 Neues Template text.html erstellen
**Datei:** `templates/text.html`

**Layout:**
- Top Bar mit Navigation (wie in film.html)
- Hauptbereich: 3-Spalten-Layout
  - **Links:** Prompt-Eingabe & Generierung
  - **Mitte:** Drehbuch-Editor (Szenen-Liste)
  - **Rechts:** Vorschau/Export

**UI-Komponenten:**
- Prompt-Textarea mit System-Prompt-Vorlagen
- Generieren-Button (verbindet sich mit lokalem LLM)
- Szenen-Liste (ähnlich film.html Scenes-Tab, aber erweitert)
- Clip-Zuordnung pro Szene (welcher Clip gehört zu welcher Szene)
- Export-Buttons (JSON, an Film-Workflow senden)

---

## Phase 2: Backend Router & API

### 2.1 Text Router erstellen
**Datei:** `ui/routers/text.py`

**Endpoints:**
```python
GET  /api/text/scripts              # Liste aller Drehbücher
POST /api/text/scripts              # Neues Drehbuch erstellen
GET  /api/text/scripts/{id}         # Einzelnes Drehbuch laden
PUT  /api/text/scripts/{id}         # Drehbuch aktualisieren
DELETE /api/text/scripts/{id}       # Drehbuch löschen
POST /api/text/generate             # LLM-Generierung starten
GET  /api/text/status/{job_id}      # Generierungs-Status prüfen
POST /api/text/export-to-film/{id}  # An Film-Workflow exportieren
```

### 2.2 Datenmodell
**Datei:** `ui/routers/text.py` oder `ui/models/script.py`

```python
class ScriptScene(BaseModel):
    id: int
    scene_number: int
    act: int
    title: str
    description: str           # Ausführliche Beschreibung für Video-Gen
    visual_prompt: str         # Prompt für Bild/Video-Generierung
    keywords: str
    duration_seconds: int
    ref: str                   # Referenz zu Clip/Datei
    notes: str                 # Regie-Anweisungen

class Script(BaseModel):
    id: str                    # UUID
    title: str
    created_at: datetime
    updated_at: datetime
    prompt: str                # Der ursprüngliche Prompt
    system_prompt: str         # Verwendetes System-Prompt
    scenes: List[ScriptScene]
    total_duration: int        # Summe aller Szenen-Dauern
    exported_to_film: bool
    film_run_id: Optional[str] # Verknüpfung mit Film-Workflow
```

### 2.3 Speicherung
- Drehbücher als JSON-Dateien im `workspace/scripts/` Verzeichnis
- Schema-Validierung mit Pydantic
- Auto-Save Funktion im Frontend

---

## Phase 3: LLM-Integration

### 3.1 Lokales LLM verwenden
**Integration mit:** `ui/routers/local_ai.py`

**Voraussetzung:** llama.cpp Server läuft auf Port 8080

**Generierungs-Flow:**
1. Frontend sendet Prompt + System-Prompt an `/api/text/generate`
2. Backend baut kompletten Prompt mit Struktur-Vorgabe
3. Anfrage an `http://127.0.0.1:8080/v1/chat/completions`
4. Response-Parsing (JSON-Struktur aus LLM-Ausgabe extrahieren)
5. Validierung gegen Script-Schema
6. Speicherung und Rückgabe an Frontend

### 3.2 Prompt Engineering
**System-Prompts in:** `ui/routers/text_prompts.py`

**Vorlagen:**
- Standard-Drehbuch (3-Akt-Struktur)
- Kurzfilm (1-3 Minuten)
- Werbespot (15-30 Sekunden)
- Musikvideo (rhythmisch)
- Tutorial/Erklärvideo

**Struktur-Vorgabe für LLM:**
```json
{
  "title": "...",
  "scenes": [
    {
      "scene_number": 1,
      "act": 1,
      "title": "...",
      "description": "...",
      "visual_prompt": "...",
      "keywords": "...",
      "duration_seconds": 5,
      "notes": "..."
    }
  ]
}
```

### 3.3 Streaming-Response
- SSE (Server-Sent Events) für Live-Generierung
- Fortschrittsanzeige im Frontend
- Möglichkeit zum Abbrechen

---

## Phase 4: Drehbuch-Editor Features

### 4.1 Szenen-Verwaltung
- Szenen hinzufügen/löschen/verschieben
- Drag & Drop für Reihenfolge
- Szenen gruppieren nach Akt
- Duplizieren von Szenen

### 4.2 Clip-Zuordnung
- Dropdown pro Szene: "Zugewiesener Clip"
- Clips kommen aus dem Film-Workflow (`workflow.py`)
- Vorschau-Thumbnail des Clips anzeigen
- "Clip generieren"-Button (triggert Film-Workflow)

### 4.3 Timeline-Visualisierung
- Horizontale Timeline mit Szenen als Blöcke
- Zeitangaben (kumulativ)
- Farbcodierung nach Akt
- Gesamtdauer-Anzeige

---

## Phase 5: Integration mit Film-Workflow

### 5.1 Export-Funktionen
**Endpoint:** `POST /api/text/export-to-film/{script_id}`

**Optionen:**
1. **Nur Config:** Exportiert nur workflow.conf-Einstellungen
2. **Scenes übernehmen:** Schreibt Szenen in film.csv Format
3. **Vollständig:** Erstellt neuen Film-Run mit allen Szenen

### 5.2 Bidirektionale Verknüpfung
- Film-Workflow zeigt an: "Basierend auf Drehbuch: XYZ"
- Drehbuch zeigt an: "Exportiert zu Film-Run: XYZ"
- Änderungen im Film-Workflow können zurück zum Drehbuch syncen

### 5.3 Clip-Referenzen
- Wenn Clip generiert wird: ref-Feld in Szene aktualisieren
- Wenn Szene in Film-UI bearbeitet: Optionale Sync zu Drehbuch

---

## Phase 6: Frontend-Implementierung (Alpine.js)

### 6.1 State Management
**Datei:** `ui/static/text_app.js`

```javascript
function textApp() {
  return {
    // Data
    scripts: [],
    currentScript: null,
    scenes: [],
    
    // UI State
    activeTab: 'editor',      // 'editor', 'preview', 'settings'
    showGenerateModal: false,
    isGenerating: false,
    generationProgress: 0,
    
    // Prompts
    userPrompt: '',
    selectedTemplate: 'standard',
    systemPrompt: '',
    
    // Methods
    async generateScript() {...},
    async saveScript() {...},
    async exportToFilm() {...},
    addScene() {...},
    moveScene(from, to) {...},
    ...
  }
}
```

### 6.2 UI-Elemente
- **Accordion** für Szenen-Details
- **Modal** für Generierungs-Einstellungen
- **Toast** für Erfolg/Fehler-Meldungen
- **Confirm** für Lösch-Operationen

### 6.3 Styling
- Konsistent mit bestehendem Design (Tailwind)
- Neue Farbe für Text-Tab: `text-accent3` (z.B. Lila)
- Responsive Layout (unter 768px: Einspaltig)

---

## Phase 7: Testing & Polishing

### 7.1 Manuelle Tests
- [ ] Drehbuch-Generierung mit verschiedenen Prompts
- [ ] Szenen-Editor: CRUD-Operationen
- [ ] Clip-Zuordnung funktioniert
- [ ] Export zu Film-Workflow erfolgreich
- [ ] Mobile Ansicht nutzbar

### 7.2 Validierung
- JSON-Schema für Drehbuch-Struktur
- Pflichtfelder prüfen
- LLM-Response parsen mit Fehlerbehandlung
- Fallback wenn LLM kein gültiges JSON liefert

### 7.3 Edge Cases
- Keine Szenen (leeres Drehbuch)
- LLM nicht erreichbar (Server offline)
- Ungültige JSON-Response vom LLM
- Film-Workflow nicht verfügbar
- Sehr lange Drehbücher (100+ Szenen)

---

## Dateien-Übersicht

### Neue Dateien
```
ui/
├── routers/
│   └── text.py              # Haupt-Router für Text/Drehbuch
│   └── text_prompts.py      # System-Prompts für LLM
├── templates/
│   └── text.html            # Haupt-Template
├── static/
│   └── text_app.js          # Alpine.js Logik
├── models/
│   └── script.py            # Pydantic Modelle (optional)
```

### Geänderte Dateien
```
ui/
├── main.py                  # Router registrieren
├── templates/
│   ├── base.html            # (falls globale Änderungen)
│   ├── dashboard.html       # + Text Link
│   ├── film.html            # + Text Link
│   ├── images.html          # + Text Link
│   ├── training.html        # + Text Link
│   └── stacks.html          # + Text Link
```

---

## Implementierungs-Reihenfolge

1. **Schnell-Start:** Phase 1.1 + 1.2 (Navigation + Template-Grundgerüst)
2. **Backend-Grundlage:** Phase 2.1 + 2.2 (Router + Modelle)
3. **LLM-Anbindung:** Phase 3.1 (Basic Generierung)
4. **Editor-Features:** Phase 4.1 (Szenen CRUD)
5. **Film-Integration:** Phase 5.1 (Export)
6. **Polishing:** Phase 3.2 + 3.3 + 6 + 7

---

## Technische Hinweise

### LLM-Anbindung
- Verwendet bestehenden llama.cpp Server (Port 8080)
- OpenAI-kompatibles API-Format
- Timeout: 120s für komplexe Drehbücher
- Retry-Logik bei Fehlern

### Speicherort
```
workspace/
└── scripts/
    ├── script_abc123.json
    ├── script_def456.json
    └── ...
```

### API-Beispiel (LLM Request)
```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local-model",
    "messages": [
      {"role": "system", "content": "Du bist ein Drehbuchautor..."},
      {"role": "user", "content": "Erstelle ein Drehbuch über..."}
    ],
    "temperature": 0.7,
    "max_tokens": 4000
  }'
```

---

## Zukunftsideen (nicht im MVP)

- **Kollaboration:** Mehrere Benutzer an einem Drehbuch
- **Versionierung:** Git-ähnliche History
- **AI-Voiceover:** Text-to-Speech für Narration
- **Musik-Integration:** Soundtrack-Vorschläge pro Szene
- **Storyboard:** Automatische Bildgenerierung für jede Szene
- **Import:** Bestehende Drehbücher importieren (Final Draft, PDF)
