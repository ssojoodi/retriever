# Website and release output

## Summary
Match Capture's local DMG handoff and complete the provided static website template for Retriever.

## Product behavior target
make release signs and notarizes the app and DMG, validates them, requires the installed-copy check, then places Retriever.dmg in web-page. Previous downloads are retained under docs/dmg-backups. The website describes actual SFTP behavior and enables downloads only after release output exists.

## Architecture changes
Extract testable local publication helper; publish checksum and release.json alongside the DMG. Keep the existing static HTML/CSS architecture, replacing Markdown Preview copy/assets with Retriever branding. No website upload or new hosting service is part of this repository workflow.

## UX acceptance criteria
Responsive landing page, accurate release notes, approved logo, install steps, working internal links, and an honest unavailable state before the first signed release. No claims of FTP, uploads or recursive downloads.

## Automated test plan
Exercise first publication, replacement/backups, checksums/metadata and copy failure preservation in an isolated directory. Check JS syntax and both availability branches with stubbed responses. Validate local HTML links/assets and serve both routes locally.

## Manual verification plan
Preserve the supplied page's responsive CSS and use the approved artwork. Browser visual testing was not requested. Full signing/notarization still needs credentials and is not inferred from publication-helper checks.

## Assumptions and non-goals
The requested deliverable is the local web-page folder for publishing, as in Capture. No public hosting, analytics, invented domain, or external transfer occurs. Backups remain outside the website.

## Results
Publication checks passed for first release, replacement, backup content, checksum/manifest, and failed-copy preservation. Both JavaScript availability states passed, as did JavaScript syntax and HTML local-link/asset validation. Both pages returned HTTP 200 from the local preview at http://127.0.0.1:8105/. Full signing/notarization was not run.
