# Release-note screenshots

Capture production AppKit views using disposable local SFTP sample files and isolated saved-host preferences. Save window-only screenshots under `web-page/screenshots/0.2.0/`. Include saved hosts, expanded folders, the context menu, and Quick Look beside the relevant release notes. No personal server details or desktop content should appear.

Validate each captured image, relative image URLs, image loading, and desktop/mobile page layouts. Do not alter release artifacts.

## Results
Captured and inspected all four native UI images. The context-menu image uses window capture so transparent rounded corners do not include desktop content. Added images with descriptive alt text, captions, lazy loading, dimensions, and full-size links beside the corresponding 0.2.0 release notes. The browser audit verifies all four image paths and decoded dimensions; desktop/mobile layouts, links, release gating, and the existing DMG checksum passed. Inspected both release-note page screenshots. All public screenshot assets reside under `web-page/screenshots/0.2.0/`.
