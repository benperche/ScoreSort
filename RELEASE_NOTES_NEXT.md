# ScoreSort 1.10.1

A follow-up to 1.10.0 with a few booklet and preset improvements, and one fix worth having.

## 🔗 Combine PDFs

- **Single-sided booklets.** When every part fits on one side of a sheet — a folder of two-page parts, say — the output no longer carries a blank back for each one. A **Single-sided** option in the booklet menu leaves them out, so a PDF you send on to someone else is half the pages and prints without them having to think about two-sided. It's offered only when the whole folder qualifies, since a longer part genuinely needs both sides of its sheet.
- **Bass guitar matches the bass part.** A preset entry for *Bass Guitar* now finds a *String Bass*, *Double Bass* or *Contrabass* file, and the other way round — the player reads whichever one is in the folder.
- **Presets divide copies between split parts.** If your preset says *Trumpet: 7* but the music comes as separate 1st and 2nd trumpet files, applying it used to put 7 on each — twice the paper for the same seven players. It now shares the count out (4 and 3), and tints those rows blue so you can see the app made the call and adjust it.

## 🐞 Fixed

- **The combined PDF's contents list lands on the right part.** Clicking a name in Preview's sidebar jumped to the foot of that part's first page, which looks like landing on the *next* part — and nothing pointed at the very first one. It now jumps to the top of the page, as you'd expect.
