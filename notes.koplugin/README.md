# Notes for KOReader

Handwritten notebooks in [KOReader](https://koreader.rocks), made for the Kindle Scribe's pen (any
KOReader 2026.07+ device whose pen KOReader supports should work).

- **Notebooks**: Tools > Notes. **+ New notebook** (blank, narrow or wide ruled, grid, dots, checklist,
  tasks with subtasks (a task box on each line; writing that starts indented makes the line a subtask, its box moving in), Cornell notes, week planner or music staves; or From PDF). Tap one to
  write in it; hold one to rename, duplicate or delete it (Undo for a few seconds after); ⋮ > Settings opens the settings. Notebooks are saved
  in `koreader/notes/` as you write. A notebook without a typed name is named by its date and time
  ("Oct 21, 2:47 PM"); **Suggest** in the Rename box asks the AI for a name from its first written
  page, and with **Suggest names (AI)** on, closing a notebook still named by date offers the AI's name.
  **Add the date to names** (Settings > New notebooks: Before the name or After the name) puts the date
  with a name you give: "Oct 21 – Meeting" or "Meeting – Oct 21" (also when one named by date is renamed).
  **When closing: Ask** (Settings > Writing) asks **Save**, **Rename…** or **Don't save** when you close a
  notebook you changed; Don't save puts it back as it was when you opened it (a new one is removed).
- **Toolbar** (left edge, or right in the settings; fold it into a small tab with its bottom button):
  notebooks, pen, highlighter, eraser, lasso, Add (shapes, text, insert), zoom box, undo, redo, Tidy, your
  favorite pens, then page up/down (tap the page number for all pages), all pages, + page and the menu. Tap a tool
  again for its panel. In landscape the buttons sit closer to fit. **Settings > Toolbar > Toolbar buttons…**
  lists everything the toolbar can have: tap one and move it with the arrows, tap its eye to show or hide it
  (hidden tools are at the top of the **⋯** menu; actions are in it anyway); **Reset** puts back the toolbar
  as it was to start with. **All pages button** and **Add
  page button** take those off the bottom (then in **⋯** too). It adds
  actions to the toolbar too (Send to OneNote, Ask AI, Convert page to text, Add page to To Do,
  Bookmark page, Export, Light, Night mode, Refresh screen, Settings; Refresh screen is there to start
  with); **Toolbar order** puts them where you want. **Groups**: Add and Tidy are each one button that
  opens a list (the one in use shows on the button; tap it again in the list for its options).
  **Settings > Toolbar > Groups…** changes what is in them: take something out and it is a button of its
  own again, or put any tool or action in one.
- **Tidy handwriting**: the Tidy group (or ⋯ > Tidy handwriting, or **Tidy** on the lasso's bar for just
  the selection) straightens your writing without changing your letters: **Level lines** (each line's
  tilt and drift taken out, its words on the ruled line), **Upright letters** (the slant taken out),
  **Even size** (words much bigger or smaller than the rest of the line brought closer) and **Even
  spacing** (even gaps between words); **Tidy handwriting** does all four. Highlights, shapes and big
  drawings are left as they are; one Undo puts it back.
- **Pen**: nine tips: Ballpoint, Fineliner (even), Fountain and Brush (width follows pressure, the brush
  strongly), Calligraphy (a slanted nib: thick and thin by direction), Marker, Pencil and Mechanical pencil
  (grey), Shader (wide soft grey, under the ink); five sizes each; ink Black, Dark grey or Light grey (the
  pencils: Normal, Darker or Lighter); a sample stroke; **Add to favorites** puts the pen on the toolbar (up to three; clear
  them in the settings).
- **Text**: tap the page and type a text box with the keyboard (drag across first to set its width); four
  sizes, bold, italic, sans or serif, left, centre or right (in the panel for new boxes, and in the
  edit dialog); tap a text box to edit or delete it. Write over it; move or resize it with the lasso.
- **Insert**: a picture from the Kindle (placed in the middle and selected, to move or resize), or tape:
  drag over something to hide it under grey tape, tap the tape to lift it and again to put it back (for
  studying; lift or put back all tape on a page from the panel).
- **Zoom window**: a strip at the bottom where you write large; it lands small in the dashed box on the page.
  Writing near the strip's end moves the box on along the line; the strip's buttons move it on, start the
  next line, or close it; tap the page to move the box there. Drag the strip's grip (⠿, top of its
  buttons) with the pen or a finger to move the strip up or down the screen; it stays there.
- **Covers**: the notebook list shows each notebook's first page (folders and the trash as tiles; new
  buttons along the top: + New notebook, new folder (an icon), Today's page, OneNote when
  signed in, then Search and Sort as icons; any that don't fit go behind More…). Settings > Notebook list >
  Show notebooks as: List switches back to the plain list. Covers are kept in `koreader/notes/covers/`.
- **Sort**: the **Sort** button at the top of the list (covers or list) sorts notebooks and folders by
  Name, Date created, Date modified or My order (folders by name for My order; a folder's date modified is
  its newest notebook's). Settings > Notebook list > **Default sort** is the sort Notes starts with: Last
  used (whatever you picked last) or one of them.
- **Today's page**: one tap (the list's button, or a KOReader gesture: General > Notes: today's page)
  opens today's page in a Journal notebook, made with the date at the top when it isn't there yet.
- **Your own templates**: ⋯ > Your templates > **+** saves this page (with its writing) or a picture as a
  template; tap one to use it (tap it again to delete it). New notebook > Your template… starts one with
  it. Kept in `koreader/notes/templates/`.
- **Links**: Insert > Link to a page… puts an underlined link to a page (of this notebook or another) on
  the page; tap it to go there. Move it with the lasso. **⋯ > Linked from** (shown when a page has links to
  it) lists the pages that link to this one.
- **Where you left off**: a notebook opens at the page it was left on, and its undo is kept while
  KOReader runs (the last two notebooks closed). Settings > Notebook list > Open the last notebook when
  Notes opens.
- **Ticks and To Do**: a checklist or tasks page added to To Do remembers which task each line became: a
  box ticked on the page ticks the task in To Do, a task ticked in To Do is ticked on the page.
- **Eraser**: it also removes text boxes, pictures and tape it passes over (one undo brings them back).
- **Trash**: deleting a notebook (or a folder's notebooks) moves it to the trash, at the end of the
  notebook list. Tap one there to restore it (back into its folder) or delete it for good; **Empty
  trash** deletes them all. Notebooks are deleted for good after 30 days. Kept in `koreader/notes/trash/`.
- **Folders**: **+ New folder** in the notebook list (folders can hold folders). Tap a folder to open it,
  **‹** to go back up; new notebooks go in the folder shown. Hold a notebook or folder to move it,
  rename it or **Select** several: then tick folders and notebooks and **what to do…** moves,
  duplicates, sends to OneNote or deletes them together. Deleting a folder asks whether its notebooks go
  too or move up a folder. Folders are kept in `koreader/notes/folders.lua`. A folder's cover shows the
  notebooks changed last in it (Automatic; crossword folders show a crossword); hold a folder > **Cover…**
  for a plain folder icon, an icon (house, briefcase, school, travel, …) or one of its notebooks.
- **Two fingers**: tap with two fingers to undo, hold with two to redo (not right after the pen, when
  it's most likely a palm; Settings > Writing turns it off).
- **Undo history**: hold Undo on the toolbar for the last steps (writing, erasing, …, with their page and
  time); tap one to go back to before it. Redo brings them back.
- **Lasso extras**: **Style** changes the selected ink's pen, thickness, shade or line; **To text** can
  **Replace** with the typed text where it was.
- **Date and time** (⋯ menu, or a toolbar button): tap where it goes and a stamp like "Wed, Oct 21 ·
  3:42 PM" is typed there.
- **One page, its own template**: in ⋯ > Page template, tap **All pages** to switch to **This page**.
  Templates now also include ruled with a margin, isometric dots, hexagons and a month calendar (the
  page's month). On the month calendar, tap a day's number to open that day's Journal page (made when it
  isn't there yet, among the others in date order); days with a Journal page have their number in black.
- **Deleted pages** stay 30 days: **Deleted (n)** in the page list restores them (or deletes them for
  good).
- **Page header** (Settings > Display): the page's date and number small at the top right.
- **Pinned and recent notebooks**: hold a notebook > **Pin to top**. The notebooks opened last are in a
  **Recent** folder first in the list (its cover shows them; tap it to see them, **‹ Notes** to go back).
  Settings > Notebook list > **Recent notebooks**: As a folder, At the top (above the other notebooks) or Off.
- **Locked notebooks**: hold a notebook > **Lock…** sets a PIN asked when it's opened (not again for two
  minutes). A locked notebook shows a lock instead of its cover and is left out of search, OneNote's
  automatic sending and the web page. A forgotten PIN can't be recovered.
- **Pictures**: the web page's **Add picture** (in a notebook) and Home Assistant's camera **Send to
  Notes** put a picture on a new page (`Notes:addImagePage`).
- **Reading OneNote**: once signed in to OneNote, **OneNote** in the notebook list (or Settings >
  Integrations > OneNote > Browse OneNote…) shows your OneNote notebooks, sections and pages. **Open**
  shows a page to read in KOReader (typed text, lists, tables, pictures). A page with handwriting (or
  any page) can be **Downloaded to edit**: it becomes pages of the notebook "<OneNote notebook>
  (OneNote)" in Notes, the handwriting as ink, typed text as text boxes, pictures as pictures. OneNote
  isn't changed; sending that notebook to OneNote puts it there as new pages. A page downloaded before
  shows "In Notes" and **Open copy in Notes**. When you want, **⋯ > Replace in OneNote** (on a downloaded
  page) puts your edited version in OneNote in place of the original page, in the same section, as
  pictures of its pages (apps can't give OneNote handwriting; you can write over them in OneNote).
- **Turning pages with a finger**: swipe up for the next page and down for the one before (as the
  toolbar's arrows), or left and right if you pick that in Settings > Writing (or turn it off). Swipes
  are ignored while the pen is near the screen or for a moment after it, so a resting palm doesn't turn
  the page.
- **Pages**: the page number or the grid button shows all pages as thumbnails: tap one to go there, hold
  one to bookmark, copy, move or delete it; **Bookmarked** shows only bookmarked pages. **Select** ticks
  several pages to bookmark, move, copy or move to another notebook, or delete them together (in a puzzle
  book: mark done, hide, clear). **⋯ > Bookmark
  page** marks the page you are on (★ by its number).
- **Highlighter**: five widths of grey, drawn under the ink so writing stays readable.
- **Eraser**: five sizes (pressing harder erases a bigger spot), partial (only the ink under it) or whole
  stroke, **Highlighter only** (the ink, text boxes and pictures stay), and Clear page. The pen's eraser end
  erases whatever tool is picked.
- **Lasso**: circle ink (and text boxes, pictures, tape) to select it; drag inside to move it, the corner
  square to resize it; Cut, Copy, Duplicate, Snap shapes, To text, To To Do, Ask (AI), Delete. With
  something cut or copied, tap the page with the lasso and Paste.
- **PDFs**: **+ New notebook > From a PDF…** picks a PDF on the Kindle; each of its pages becomes a page to
  write on (the PDF is copied in beside the notebook; landscape PDFs make a landscape notebook). Pages
  you add are blank paper. **⋯ > Export PDF with ink** writes a copy of the PDF with your writing as PDF ink
  annotations (other PDF apps show them and can edit or remove them) to `koreader/notes/export/`; pages
  added in Notes go out with Export all pages. The PDF page fills the screen, so the toolbar may cover a
  little of the left margin; fold it to see all of it.
- **Puzzle books** (crosswords and other puzzle PDFs) belong to the **Crosswords** plugin
  (crosswords.koplugin, its own app: getting crosswords, importing PDFs and .puz/.ipuz files, hints,
  checking, its settings and guide). They are Notes notebooks written on with Notes' tools, and Notes leaves
  them out of its own list while Crosswords is installed (without it they show as plain notebooks in the
  **Crosswords** folder). In one, write in the squares with the pen and cross
  off clues. The toolbar: ⌂ Home and the notebooks, then pen (tap again for its tips and sizes), eraser,
  lasso, zoom, undo, redo and **Done** (✓ marks the page done); then the buttons pinned from ⋯ (**Hint** and
  **Check my answers** to start with: anything in a crossword book's ⋯ can be pinned, in Crossword settings >
  **Toolbar buttons**); then page up/down, the puzzle list, ⋯ and fold; and at the bottom ⟳ Refresh, the bell
  and ⚙ Settings, which in a crossword book opens **Crossword settings**: full pages like the other apps'
  (Display, Solving, Getting crosswords, AI).
  - **Ask AI**: lasso a clue (or part of the grid) and tap **Ask**: that part of the page, print and
    writing, goes with your question ("a hint, not the answer"). **⋯ > Ask AI…** asks about the whole
    page. The lasso works on the whole page: picking it turns the zoom off.
  - **Zoom**: the first time, drag a box around the grid with the pen; the zoom then shows that part of
    every page as large as it fits (the box is kept for the book). Write while zoomed and the ink lands
    small in the squares; the page buttons keep the zoom. **Change area** drags a new box; tap Zoom
    again for the whole page.
  - **Puzzle list** (the grid button): every page as a thumbnail, **Started** (written on) or **Done**,
    with All, Not started, Started, Done and Hidden. Hold a page to mark it done, hide it (covers,
    solutions: the page buttons pass hidden pages by) or clear its writing. **⋯ > Hide page** hides the
    page you are on.
  - Works with any PDF: nothing is read from the pages, so scanned books work too.
- **Shapes**: line, arrow, rectangle, ellipse, triangle, diamond, star and table (rows and columns in the
  panel), dragged corner to corner with the pen's tip and size. They are ordinary ink: the eraser and
  lasso work on them. **Fill** (none, light or dark grey) and **Line** (solid, dashed or dotted) in the panel.
- **Snap**: draw a rough line, circle, ellipse, rectangle or triangle and hold the pen still for half a
  second: it becomes a clean one (one Undo brings your own back). The lasso's **Snap shapes** does the same
  for ink already on the page. Lines near level, upright or 45° are made exactly so, and line and arrow
  ends join ink nearby (both can be turned off). **Stroke smoothing** (light or strong) evens out shaky
  strokes. With the pen's side button set to **Ruler**, holding it draws straight lines.
- **Checklists**: on the checklist and tasks templates, tap a printed box (pen or finger) to tick it, again
  to untick it; a mark drawn over an empty box (a tick, a cross) becomes a tick too.
- **Menu (⋯)**: page template, Send to OneNote, Convert page to text, Ask AI, Add page to To Do,
  bookmark, page orientation, pen pressure, Export…, reorder pages, rename, delete page, Light (KOReader's
  brightness and warmth), Night mode, refresh screen, settings. The notebook list's ⋮ has Open on the web
  page, Recent apps, Light, Night mode, Refresh screen and Settings. The list and settings have the apps'
  shared title bar (‹, ⌂, Recent apps; time and battery with ▾ for the drop-down panel; ⟳, the bell, ⋮);
  a swipe in from the left edge goes back.
- **KOReader gestures**: your gestures from KOReader's Gestures settings work in Notes, the ones that
  can't be a resting palm: two-finger taps and swipes, pinch, spread, rotate, edge swipes and multiswipes
  (e.g. an edge swipe for the light, or one that opens a QuickMenu). One-finger taps and swipes on the page
  do nothing. Turn it off in the settings.
- **Export…** (to `koreader/notes/export/`): this page or all pages as pictures (PNG), the notebook as a PDF
  (each page as a picture), a PDF notebook's PDF with the writing added as annotations, this page or the
  whole notebook as text (read by the AI; pages read before are not read again).
- **Settings** (⋮ > Settings in the notebook list, ⚙ at the bottom of the toolbar, or the launcher's
  Settings list): full pages in the apps' shared design, in sections: **Display** (full refresh, page
  header, template lines, KOReader gestures), **Toolbar** (side, order, buttons, groups,
  start with toolbar hidden), **Writing** (pen side button, eraser, stroke smoothing, starting pen, favorite
  pens), **Shapes** (shape recognition, snap lines to 0°, 45°, 90°, snap line ends to ink), **New
  notebooks** (template, pen pressure, names), **Notebook list** (sort, recent, reorder) and
  **Integrations** (AI for everything, dates beside tasks, Read all pages now, OneNote, AI settings). Settings with more than two choices open a
  list to pick from.
- **OneNote** (Notes settings > OneNote…): signed in with the launcher's one Microsoft account
  (Settings > Microsoft, `PS.microsoft`: one App ID and one sign-in for To Do and OneNote; Notes' old
  sign-in moves there once; without the launcher, its own App ID and sign-in as before), pick a OneNote notebook (or make one,
  "Kindle Scribe"), then **⋯ > Send to OneNote** in a notebook, **Send to OneNote now** when holding one
  in the list, or **Send all now**. Each notebook becomes a section, each page a OneNote page holding the
  page as an image (OneNote makes handwriting in images searchable). Changed pages are updated in place,
  deleted pages removed; nothing comes back from OneNote. Sending happens in the background: the Kindle
  can be used meanwhile, and a notice says when it's done. **Send automatically** sends a notebook when you
  close it, and everything when Wi-Fi comes on (it never turns Wi-Fi on); **Notebooks sent: Ones I pick**
  limits that to notebooks you mark (hold one in the list). **Where each goes**: hold a notebook (or a
  folder, for every notebook in it) > **OneNote: …** to pick another OneNote notebook and a section (one
  there, a new one, or one of its own name); a notebook's choice comes before its folder's
  (`onenote_targets`, `OneNote.targetFor`). Pages in a shared section are titled with the notebook's
  name; only pages Notes sent are ever changed or removed there.
- **The AI** is the launcher's (`apps.koplugin/appsai.lua`, through `PS.ai`), shared with Crosswords and
  SSH: Settings > AI (Notes settings > Integrations > AI settings… opens it) has the services (Claude,
  Gemini, OpenRouter, Groq, your local AI on its Internal or External URL, Custom), which one does each job, Try a
  prompt, Test connection, and Advanced: each feature's instructions (a fixed intro, your wording with
  Reset, a fixed answer format), how much is sent and a preview. Notes registers its jobs (`read`, `ask`,
  `draw`: `PS.ai.registerJob`) and features (Read handwriting, Ask, Make PDF, Drawing help:
  `PS.ai.registerFeature`, with Notes' pages as the preview's pictures); Crosswords adds its own with
  `Notes.addAiFeature`. `Notes:claude(job)` is the launcher's client for the job's service;
  `Notes:aiInstructions(key)` and `Notes:aiMorePages` build what is sent. Notes' prompts for reading
  handwriting and to-do items are `notesclaude.lua`. Without the launcher, Notes has no AI. Notes' AI
  settings and keys (`notes_secrets.lua`) moved to the launcher once, on its first start with this.
- **Handwriting to text**: **⋯ > Convert page to text**, or the lasso's **To text** for part of a page. The
  text can be copied or saved as a Markdown file in `koreader/notes/export/`. Pages read are kept, so
  **Search** in the notebook list finds words across notebooks: typed text (text boxes, text downloaded
  from OneNote) and notebook names straight away, handwriting once it has been read (**Read all pages now**,
  in Notes settings > Integrations, reads the rest). With **Typed text in OneNote pages** on, the text goes
  under each page sent to OneNote.
- **Add to To Do** (with the To Do plugin and Claude): **⋯ > Add page to To Do**, or the lasso's **To To Do**.
  Claude reads the to-do items (on the checklist and tasks templates a printed box starts a task, an
  indented box a subtask; ticked boxes are done) and they are shown before going into a To Do list (tap
  the list to change it) as tasks with steps, synced by the To Do plugin. Claude only sees the picture;
  the To Do plugin adds the tasks. Tap a task to tick or untick it or its steps (when a box was read
  wrong). Dates written beside a task are read too: "Fri" or "10/30" is the due
  date, "9am" a reminder on it, "Fri 9am" both, "remind Mon 7pm" only a reminder (turn this off in
  Notes settings > AI…). Tap a task before adding it to see its steps and set or change its due date
  and reminder, clear them, or give every task the same dates.
- **Draw with AI**: the lasso's **Draw** redraws a selection (Replace) or draws next to it (Beside):
  "Redraw this neatly", "Make this a flowchart", "Turn this into a table"…; on an empty area its one
  button is **Draw**. The AI answers with line art (SVG) that becomes ink and text boxes you can erase, move or
  undo. Typed or written requests, as for Ask.
- **Ask AI** (**⋯ > Ask AI…**, or the lasso's **Ask**): type a request (your last five and some
  examples are one tap away) or tap the pen at the end of the box and write it by hand in a strip at the
  bottom of the page. **Answer** shows the AI's answer (Copy, Save, Done); **Make PDF** has the AI rewrite the note as a clean
  document with what you asked (headings, lists, checkboxes, bold and italics kept), made into a PDF with real text in `koreader/notes/export/`, to open or to
  write on as a new notebook.
- The Ask and Draw boxes and the answer are the launcher's shared pop-ups (`PS.popup.request` and
  `PS.popup.read`, icon buttons); without the launcher they're KOReader's InputDialog and TextViewer.
- **Open on the web page** (with the Web server plugin): **⋯ > Open on the web page** in a notebook, or the
  first row of Notes settings from the notebook list, starts the web server if needed and shows a QR code:
  scan it with a phone to open that notebook (or the Notes page) there.
- Fingers only work the toolbar and panels (a resting palm does nothing); the pen works them too.
- **Gesture**: Settings > Taps and gestures > Gesture manager > (a gesture) > General > Notes.

**Writing on a book's pages** (PDFs and other fixed-page books open in KOReader): tap **Write on this
page** in the reader's menu (Tools), or give a gesture **Notes: write on this page**. The Notes pen,
eraser, lasso and zoom work over the page; the arrows turn the book's pages, and the top button (or the
gesture again) goes back to reading. The ink is kept with the book (its settings beside it) in the page's
own units, so it stays in place when you zoom and shows whenever the page does, in page or continuous
view. A stroke belongs to the page it starts on.

**Quick note**: give a gesture **Notes: quick note** (General). A writing pad opens over whatever is on
the screen (a book, a menu, To Do), the screen faded above it: pen, highlighter, eraser, lasso, undo. ✓
(or the gesture again) is Done: what you wrote goes on a new page of the **Inbox** notebook, with the date
and time at the top. Nothing written, nothing kept.

**Landscape**: a notebook is portrait or landscape (new notebooks follow the way the Kindle is turned;
**⋯ > Page orientation** switches one, keeping the ink where it is: Portrait, Landscape, Inverted portrait
or Inverted landscape). Opening it turns the Kindle to match, and turns it back when you close it.

**Two pages side by side**: **⋯ > Two pages side by side** shows a portrait notebook two pages at a time
with the Kindle on its side, like an open notebook (1–2, 3–4, …; the arrows turn two pages). Turning the
Kindle on its side does it too, and back upright shows one page (Settings > Writing > Two pages when turned
on its side). The pen, highlighter and eraser work on either page; for the lasso, text and the rest,
**⋯ > Two pages side by side** turns it off.

## The pen

Notes reads the pen straight from its digitizer (`WacomDigitizer` on the Kindle Scribe), not through
KOReader's touch handling, for two reasons found with a probe on a Scribe:

- **Palm rejection.** With a palm on the screen, KOReader's own pen handling mixes the palm's touches
  with the pen's (pen strokes turn into finger gestures, palm points into pen points). The digitizer
  only ever sees the pen.
- **Pressure** (0-4095 on the Scribe): line width follows it, from about a third of the chosen size for
  a light touch to the full size pressing hard. **⋯ > Pressure** turns it off per notebook; Settings >
  Writing > **Pen pressure** sets how hard to press: Soft (a light touch writes wider), Normal or Firm.

Its X and Y are the screen's axes scaled by the digitizer's ranges (read with EVIOCGABS; Scribe 0-15624
and 0-20832 for a 1860x2480 screen, under a pixel off). The eraser end and the side button erase. If
the digitizer cannot be opened, Notes falls back to KOReader's stylus API (fixed widths).

## How the ink keeps up

The pen reports about 300 points a second. Each segment is drawn straight into the page image and the
screen, and the screen is asked to refresh the changed area at most every 30 ms in the fast `a2`
mode, then once cleanly when the pen lifts. (Refreshing once per point queues up on e-ink and lags.)

## Install

Copy this folder to `koreader/plugins/notes.koplugin` and restart KOReader.

## Development

```bash
luajit tests/run.lua    # geometry, eraser, lasso, saving notebooks, OneNote against a pretend Graph
```

- `notespen.lua`: the digitizer: finding and opening it, its ranges, and a parser of its events.
- `notesink.lua`: tips, stroke stamping (no gaps at any speed, widths per point), boxes, eraser hits, the
  lasso (inside, selection, moving and scaling).
- `notesstore.lua`: one Lua file per notebook, written atomically, read back in an empty environment.
- `noteseditor.lua`: the page, toolbar and panels, pen handling, lasso, undo, pages, export.
- `notesui.lua`: drawing the toolbar and panels (text, icons, boxes) in units of the mockup.
- `notessettings.lua`: the settings and their dialog.
- `notespdf.lua`: PDF pages as backgrounds and the PDF export with ink annotations (KOReader's MuPDF).
- `notesshapes.lua`: shapes, telling what a hand-drawn stroke was meant to be, level lines, joining ends,
  smoothing; plain Lua.
- `notesonenote.lua`: OneNote over Microsoft Graph (sign-in, sections, pages, what to send), plain Lua.
- `notesclaude.lua`: handwriting to text with Claude (the Messages API request and reply), plain Lua.
- `notestextui.lua`: the Claude settings, converting pages and selections, keeping text, search.
- `notespaper.lua`: the page templates.
- `notescrossword.lua`: the crossword page layout the editor, overview and covers draw (upright and on its
  side, clue size and boxes), the sources' parsers, the books' PDFs, puzzle state, stats and checking
  answers; plain Lua. The rest of Crosswords is its own plugin, crosswords.koplugin, which adds its parts to
  Notes when installed (`self.crosswordTap` and the rest; `crosswordsApp` opens this list as its app).
- `notesitems.lua`: text boxes, pictures and tape.
- `notesoverview.lua`: all pages as thumbnails.
- `notesmdpdf.lua`: Markdown into a PDF with text (for Make PDF), and pictures into a PDF; plain Lua.
- `notessvg.lua`: Claude's drawings (SVG) into ink and text boxes, plain Lua.
- `notesonenoteui.lua`: OneNote's settings, sign-in and sending in KOReader.
- `icons/`: [Lucide](https://lucide.dev) icons (ISC licence, `icons/LICENSE`), black and white (`-w`).
- `main.lua`: the notebook list and the menu entry.
