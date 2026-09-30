// Only a successfully validated local release creates this manifest.
(async () => {
  try {
    const response = await fetch('release.json', { cache: 'no-store' });
    if (!response.ok) return;
    const release = await response.json();
    if (release.file !== 'Retriever.dmg' || !/^\d+(\.\d+){0,2}$/.test(release.version) ||
        !/^\d+$/.test(release.build) || !/^[a-f0-9]{64}$/.test(release.sha256)) return;
    const expected = document.documentElement.dataset;
    if (release.version !== expected.releaseVersion || Number(release.build) < Number(expected.releaseBuild)) return;
    const download = await fetch(release.file, { method: 'HEAD', cache: 'no-store' });
    if (!download.ok) return;
    document.querySelectorAll('[data-download]').forEach(link => {
      link.href = release.file;
      link.hidden = false;
    });
    document.querySelectorAll('[data-pending]').forEach(element => { element.hidden = true; });
    document.querySelectorAll('[data-checksum]').forEach(element => { element.hidden = false; });
    document.querySelectorAll('[data-latest-release-label]').forEach(element => { element.textContent = 'Available now'; });
    document.querySelectorAll('[data-release-status]').forEach(element => {
      element.textContent = `Version ${release.version} (${release.build}) · Signed and notarized for macOS.`;
    });
  } catch {
    // Keep the honest unavailable state when served offline or before release.
  }
})();
