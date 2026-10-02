# Packwright — screenshots and slides

Pictures of the studio for the README, a post or a presentation.

- `screenshots/` — the windows at 2x, with transparent corners: the start screen, the editor (ready to publish, blocked by a copied folder, and after publishing), wizard steps 1, 2, 3 and 5, the installed-app picker, the confirmation before publishing, the first-run settings dialog and the help.
- `slides/` — a twelve-slide walkthrough of what Packwright does and how it works, as 3840×2160 JPEGs.

The windows are **rebuilt in HTML from the XAML in `Packwright.ps1`**, not captured from a running studio: the same theme brushes, sizes, margins and control layout, filled with the strings Packwright's own logic writes (the detection summary, the checklist lines, the build and publish log). Open Sans stands in for Segoe UI and Cascadia Mono for Consolas where those are not installed. The package shown is 7-Zip 25.01; the folders, app id and installed-program list are examples.

When the UI changes, change `render/screens.js` to match and run `node render/shoot.mjs` (it needs Playwright: `npm install --no-save playwright` and `npx playwright install chromium`).
