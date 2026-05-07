# Aktuelle Umstellungsphase: Web UI - Film Tab (Phase 1)

**Stand**: 2026-04-11

## Ziel

Eine FastAPI-basierte Web-UI, die den `video_script_full_workflow.sh` Workflow komplett
grafisch steuerbar macht — ohne Shell-Befehle.

---

## Dateistruktur

```
ui/
├── main.py                    ✓ erstellt + getestet
├── requirements.txt           ✓ erstellt
├── routers/
│   ├── __init__.py            ✓ erstellt
│   ├── workflow.py            ✓ erstellt + getestet (config/scenes/status/video endpoints)
│   └── streams.py             ✓ erstellt + getestet (SSE subprocess streaming)
├── static/
│   └── app.js                 ✓ erstellt (Alpine.js state management)
├── templates/
│   ├── base.html              ✓ erstellt (Tailwind+HTMX+Alpine dark theme)
│   └── film.html              ✓ erstellt (Config/Scenes/Videos tabs + Log stream + Modals)
└── AKTUELLE_UMSTELLUNGSPHASE.md  # diese Datei
```

---

## Checkliste Phase 1

### Backend

- [x] `ui/main.py` — FastAPI app mit static files + templates + routers
  - `/api/workflow/config` — GET/PUT workflow.conf
  - `/api/workflow/scenes` — GET/PUT scenes.json
  - `/api/workflow/init` — POST init
  - `/api/workflow/validate` — POST validate
  - `/api/workflow/pilot` — POST {start_id, end_id}
  - `/api/workflow/gen` — POST {selector: "all"|id}
  - `/api/workflow/stitch` — POST {output}
  - `/api/workflow/status` — GET workflow state
  - `/api/workflow/video/{run}/{scene}` — GET MP4 stream

- [x] `ui/routers/workflow.py` — Workflow command wrapper
  - `parse_workflow_conf()` — bash config → JSON
  - `update_workflow_conf()` — JSON → bash config
  - `read_scenes_json()` / `write_scenes_json()`
  - `run_workflow_command()` — async subprocess wrapper
  - `get_video_files()` — video_output/*/*.mp4 discovery

- [x] `ui/routers/streams.py` — SSE streaming
  - `stream_logs(command, args)` — subprocess output streamen als SSE

### Frontend

- [x] `ui/templates/base.html` — Grundlayout
  - Tailwind CSS (CDN) mit custom dark theme colors
  - Alpine.js (CDN)
  - Monospace Log-Styles

- [x] `ui/templates/film.html` — Film-Tab
  - Workflow-Status-Infoleiste (top bar)
  - Config-Tab: workflow.conf Editor mit Save
  - Scenes-Tab: Szenen-Tabelle mit Inline-Edit Modal
  - Videos-Tab: generated MP4s mit Video-Player Grid
  - Action-Buttons: Init, Validate, Pilot (von/bis), Gen (id/all), Stitch
  - Log-Stream-Fenster (rechte Spalte, SSE-basiert)

- [x] `ui/static/app.js` — Alpine.js Logik
  - filmApp() component mit data loading + command streaming
  - SSE Log-Stream via fetch ReadableStream
  - Scene-Edit Modal
  - Config/Scenes Roundtrip Save

### Testing

- [x] GET / — 200 OK (HTML Seite)
- [x] GET /api/workflow/config — parsed 22 keys aus workflow.conf
- [x] GET /api/workflow/scenes — scenes.json lesen
- [x] PUT /api/workflow/config — Roundtrip OK
- [x] PUT /api/workflow/scenes — Roundtrip OK
- [x] GET /api/workflow/status — State + Runs
- [x] SSE /api/stream/logs?command=status — Streaming OK

---

## Fortschritt

| Aufgabe | Status |
|---------|--------|
| Dateistruktur ui/ anlegen | ✓ erledigt |
| requirements.txt erstellen | ✓ erledigt |
| main.py (FastAPI app) | ✓ erledigt |
| routers/workflow.py (backend logic) | ✓ erledigt |
| routers/streams.py (SSE) | ✓ erledigt |
| templates/base.html | ✓ erledigt |
| templates/film.html | ✓ erledigt |
| static/app.js (Alpine.js) | ✓ erledigt |
| workflow.conf parsing | ✓ erledigt |
| SSE streaming | ✓ erledigt |
| Testing aller Endpoints | ✓ erledigt |

---

## Server starten

```bash
cd /home/schaf/projects/ai_studio/ui
python3 -m uvicorn main:app --host 127.0.0.1 --port 8000
# Browser: http://127.0.0.1:8000
```

---

## Notizen

- Jinja2: Direktes `jinja2.Environment` statt Starlette's `Jinja2Templates` (Versionskonflikt mit System-Package)
- workflow.conf Parsing: Regex-basiert, erhaelt Kommentare und Reihenfolge beim Schreiben
- SSE: Nutzt fetch ReadableStream API statt HTMX hx-sse (einfacher, keine Dependency)
- Keine HTMX-Dependency mehr noetig (Alpine.js reicht fuer alles)
- Server laeuft auf http://127.0.0.1:8000 (derzeit aktiv)
