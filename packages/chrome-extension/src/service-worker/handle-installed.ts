import { GUIDE_URL } from '../shared/constants';

/** Exported for unit testing. Opens the setup guide on fresh install only. */
export function handleInstalled(details: chrome.runtime.InstalledDetails): void {
  if (details.reason === chrome.runtime.OnInstalledReason.INSTALL) {
    chrome.tabs.create({ url: GUIDE_URL }).catch(() => {});
  }
}
