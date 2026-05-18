---
name: receipt-to-expense
description: "Photo of a receipt → categorized expense line → CSV or Google Sheet append. Uses macOS Live Text OCR (free) + Gemini classification. Voice-callable: 'log this receipt', 'add to expenses'."
user-invocable: true
---

# Receipt to Expense

Drop a photo into the conversation (or name a file), say "log this receipt", and a categorized line lands in your expense tracker. macOS Live Text does the OCR for free (no Vision API costs); Gemini does the classification.

## Triggers

- "Log this receipt"
- "Add to expenses"
- "Process this receipt"
- "Track this purchase"
- Receipt photo dropped via screenshot / file paste

## Inputs

- `image_path` (string, required): Absolute path to the receipt image. The bridge auto-fills this when the user drops a photo via the desktop.
- `category` (optional): User-asserted category. If omitted, Gemini infers from vendor + items.
- `notes` (optional): Free-text note from the user ("client lunch with sarah").

## Steps

### 1. OCR with macOS Live Text

```bash
osascript <<'EOF'
on run argv
  set imagePath to item 1 of argv
  set theImage to POSIX file imagePath
  tell application "Image Events"
    launch
    set theImg to open theImage
    close theImg
  end tell
  -- Live Text via Shortcuts (macOS 13+) is cleanest:
  do shell script "shortcuts run 'Extract Text from Image' -i " & quoted form of imagePath
end run
EOF
```

If the user doesn't have the "Extract Text from Image" shortcut, fall back to `python3 -c "from Vision import VNRecognizeTextRequest, ..."` via PyObjC. As a third fallback (no PyObjC):
```bash
# Use Gemini Vision via screenshot-explain pattern — extracts text directly
python3 src/inline-tools.ts ... # (re-uses the vision path)
```

### 2. Parse the extracted text

Structure the text. Common receipt patterns:
- Vendor name: usually the first 1-2 lines, ALL CAPS or styled.
- Date: look for patterns `MM/DD/YYYY`, `DD MMM YYYY`, `YYYY-MM-DD`.
- Subtotal / Tax / Total: lines containing `total`, `subtotal`, `tax`, `amount`, `due`.
- Line items: between vendor and totals, each with a price.

Use a small Gemini call (text-only, gemini-3-flash) with JSON-mode to extract:

```json
{
  "vendor": "string",
  "date": "YYYY-MM-DD",
  "amount_cents": 1234,
  "currency": "USD",
  "category": "meals|transport|lodging|supplies|software|client_entertainment|other",
  "items": ["string", ...]
}
```

Pass the user's `category` override and `notes` into the prompt so Gemini can incorporate.

### 3. Append to the expense store

Configurable target via `~/.config/sutando/expense-store.json`:
```json
{
  "type": "csv",
  "path": "~/Documents/expenses-2026.csv"
}
```
Or:
```json
{
  "type": "gsheets",
  "spreadsheet_id": "...",
  "sheet": "Expenses",
  "service_account_path": "..."
}
```

If no config exists, write CSV to `~/Documents/expenses-<year>.csv` by default and tell the user "First-run: wrote to ~/Documents/expenses-2026.csv. Want a different destination?"

CSV format:
```
date,vendor,amount,currency,category,notes,source_image,created_at
```

Append the new row. Don't re-write the file — append-only.

For Google Sheets, use `gspread` via the configured service account:
```python
import gspread
gc = gspread.service_account(filename=SERVICE_PATH)
sheet = gc.open_by_key(SPREADSHEET_ID).worksheet(SHEET_NAME)
sheet.append_row([date, vendor, amount, currency, category, notes, source_image, now])
```

### 4. Confirmation

Speak the result conversationally:
- "Logged $24.50 at Blue Bottle on May 15 under meals. Want to add a note?"
- If the amount looks unusual (>10x recent average for that category), confirm: "That's a $487 lunch — does that look right?"
- If category was inferred (not user-asserted), say so: "I put it under 'meals' — say 'change to client entertainment' if that's wrong."

### 5. Edit the last entry

Triggers: "change that to <category>", "fix the amount", "remove the last receipt".
Read the last line of the CSV (or query the last sheet row), edit in place, speak the confirmation.

## Privacy

- The receipt image stays local. Only the extracted text (no image) goes to Gemini for classification.
- The CSV / Sheet is the user's storage — Sutando never reads it back without an explicit "what did I spend on X" voice request.

## Voice routing

`documented_for_core: true`. Delegated to core.

## Setup

First-run prompts (only when no `~/.config/sutando/expense-store.json` exists):
1. "Where should I store expenses — a CSV file on your Mac, or Google Sheets?"
2. If gsheets: "Paste the spreadsheet URL, and the path to a service-account JSON."
3. If CSV: confirm the default path `~/Documents/expenses-<year>.csv`.

Write `~/.config/sutando/expense-store.json` only after the user confirms — don't silently create defaults.
