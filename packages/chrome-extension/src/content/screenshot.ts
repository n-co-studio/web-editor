/**
 * Full-page screenshot via scroll-and-stitch.
 * Hides the extension overlay, scrolls through the page capturing each viewport
 * via the service worker's captureVisibleTab, stitches on a canvas, and downloads.
 */

const MAX_CANVAS_DIM = 32767;
const CAPTURE_DELAY_MS = 150;

function waitForPaint(): Promise<void> {
  return new Promise((resolve) => {
    requestAnimationFrame(() => setTimeout(resolve, CAPTURE_DELAY_MS));
  });
}

function loadImage(dataUrl: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = dataUrl;
  });
}

async function captureViewport(): Promise<string> {
  const resp = await chrome.runtime.sendMessage({ type: 'CAPTURE_VIEWPORT' });
  if (resp?.error) throw new Error(resp.error);
  return resp.dataUrl;
}

export async function captureFullPage(host: HTMLDivElement): Promise<void> {
  const savedScrollX = window.scrollX;
  const savedScrollY = window.scrollY;

  // Hide overlay during capture. The host has no inline display set (layout is
  // position:fixed from shadow-host.ts), so clearing the override restores it.
  host.style.display = 'none';
  await waitForPaint();

  try {
    const dpr = window.devicePixelRatio || 1;
    const viewportW = window.innerWidth;
    const viewportH = window.innerHeight;
    let pageWidth = document.documentElement.scrollWidth;
    let pageHeight = document.documentElement.scrollHeight;

    // Clamp to canvas limits
    if (pageWidth * dpr > MAX_CANVAS_DIM) pageWidth = Math.floor(MAX_CANVAS_DIM / dpr);
    if (pageHeight * dpr > MAX_CANVAS_DIM) pageHeight = Math.floor(MAX_CANVAS_DIM / dpr);

    const cols = Math.ceil(pageWidth / viewportW);
    const rows = Math.ceil(pageHeight / viewportH);

    const tiles: { dataUrl: string; x: number; y: number }[] = [];

    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        const targetX = Math.min(col * viewportW, pageWidth - viewportW);
        const targetY = Math.min(row * viewportH, pageHeight - viewportH);

        window.scrollTo(targetX, targetY);
        await waitForPaint();

        const dataUrl = await captureViewport();
        tiles.push({ dataUrl, x: window.scrollX, y: window.scrollY });
      }
    }

    // Stitch on canvas
    const canvas = document.createElement('canvas');
    canvas.width = pageWidth * dpr;
    canvas.height = pageHeight * dpr;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('Canvas 2D context unavailable');

    for (const tile of tiles) {
      const img = await loadImage(tile.dataUrl);
      ctx.drawImage(img, tile.x * dpr, tile.y * dpr);
    }

    // Download
    const blob = await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('toBlob failed'))), 'image/png');
    });

    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `screenshot-${location.hostname}-${Date.now()}.png`;
    a.click();
    URL.revokeObjectURL(url);
  } finally {
    window.scrollTo(savedScrollX, savedScrollY);
    host.style.display = '';
  }
}
