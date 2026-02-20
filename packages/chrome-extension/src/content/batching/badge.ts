import type { PendingQueue } from './queue';

/**
 * Updates the extension icon badge to show the pending change count.
 * Sends a message to the service worker which calls chrome.action.setBadgeText.
 */
export class BadgeUpdater {
  constructor(private readonly queue: PendingQueue) {}

  update(): void {
    const count = this.queue.count;
    chrome.runtime.sendMessage({
      type: 'UPDATE_BADGE',
      payload: { count },
    }).catch(() => {
      // Service worker may not be running — non-fatal
    });
  }
}
