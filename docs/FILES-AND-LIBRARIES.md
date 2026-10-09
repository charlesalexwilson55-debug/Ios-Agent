# Files, libraries and USB export

Generated websites and code projects appear as file cards. Tap a card to view its contents, copy individual files, or share the complete ZIP. Plain fenced code is converted after generation completes; `filename=relative/path` preserves meaningful filenames. The `create_files` tool saves complete projects directly. HTML preview runs in a disposable WebKit view with access limited to the project folder. It supports static HTML, CSS and browser JavaScript; a server, npm packages and external network requests are not available in that preview.

Imported documents retain their originals. Photos selected through Files and Photos use the same storage and OCR pipeline. Covers are separate from collection content. Older photo imports are repaired into the local index before retrieval. Scanned PDF pages receive local OCR. The `search_libraries` tool returns document passages, photo identifiers and counts from indexed photo text/labels. The `read_library_photo` tool routes a selected photo to the installed vision model, with explicit Apple Vision OCR/label fallback. A label/OCR search is not a complete visual understanding of every photo; unreadable images and unavailable iCloud assets are reported.

All text models are offered the same relevant tools through the app's task router. Web Searching must be enabled and the iPhone must be online. Public search, configured Exa/Tavily providers, page reading with character-offset pagination, and public GitHub repository search are available. Logins, paywalls, search-engine blocks and API rate limits can still prevent retrieval. GitHub references supply context; they do not retrain a model or install repository code.

## Send to PC

The app cannot write directly to a PC's filesystem over ordinary USB. It queues exports in `Documents/PC Outbox`; a receiver on a paired, trusted PC copies and verifies them before acknowledging receipt. The app displays **Queued for PC** until that acknowledgement, then **Sent to PC**. Battery charging alone is not treated as proof that a PC receiver is connected.

Run on the PC with Python and `pymobiledevice3` installed:

```powershell
python scripts/receive-from-iphone.py
```

Keep the phone connected and unlocked. Exports go to `Downloads/Conduit Exports` by default. Use `--output` to choose another directory, `--bundle` if the app's re-signed bundle ID differs, or `--udid` with more than one connected device. Existing PC files are never overwritten. Queue entries are removed only after a verified PC copy and acknowledgement. Generated files, images and saved research offer this action; normal iOS sharing remains available independently.

Model installation is import-only. The model page accepts complete MLX folders or ZIPs. The wheel uses bundled official Qwen, MiniCPM and Edge0 branding; unknown models use initials. Task routes and LoRA selection are available through the information button. No model-download controls remain in the app.
