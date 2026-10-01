// Download links work without JavaScript. Metadata adds the artifact version and checksum.
(async () => {
  try {
    const response = await fetch('release.json', { cache: 'no-store' });
    if (!response.ok) return;
    const release = await response.json();
    if (release.file !== 'Retriever.dmg' || !/^\d+(\.\d+){0,2}$/.test(release.version) ||
        !/^[a-f0-9]{64}$/.test(release.sha256)) return;
    document.querySelectorAll('[data-checksum]').forEach(element => { element.hidden = false; });
    document.querySelectorAll('[data-release-status]').forEach(element => {
      element.textContent = `Download: version ${release.version} · Signed and notarized for macOS.`;
    });
  } catch {
    // Optional metadata must never block the published download.
  }
})();
