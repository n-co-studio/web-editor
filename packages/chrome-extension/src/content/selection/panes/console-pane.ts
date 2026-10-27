import { createElement, createText, createButton } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';

const MAX_LOG_ENTRIES = 50;

/**
 * Console pane — right column of the DevTools panel.
 * Displays timestamped log entries and mirrors to the browser console.
 */
export class ConsolePane {
  private logContainer: HTMLDivElement | null = null;
  private logEntries: Array<{ level: 'info' | 'warn' | 'error'; text: string; time: number }> = [];

  mount(container: HTMLDivElement): void {
    const logBox = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      padding: '4px 8px',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.logContainer = logBox;
    this.refreshLogDisplay();
    container.appendChild(logBox);

    const clearBar = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'flex-end',
      padding: '2px 8px',
      borderTop: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
    });
    const clearBtn = createButton('Clear', 'ghost', () => this.clearLog());
    clearBtn.style.fontSize = '10px';
    clearBtn.style.padding = '2px 6px';
    clearBar.appendChild(clearBtn);
    container.appendChild(clearBar);
  }

  dispose(): void {
    this.logContainer = null;
  }

  log(text: string, level: 'info' | 'warn' | 'error' = 'info'): void {
    const prefix = '[nco-web-editor]';
    if (level === 'error') console.error(prefix, text);
    else if (level === 'warn') console.warn(prefix, text);
    else console.log(prefix, text);
    this.logEntries.push({ level, text, time: Date.now() });
    if (this.logEntries.length > MAX_LOG_ENTRIES) this.logEntries.shift();
    this.refreshLogDisplay();
  }

  clearLog(): void {
    this.logEntries = [];
    this.refreshLogDisplay();
  }

  private refreshLogDisplay(): void {
    if (!this.logContainer) return;
    this.logContainer.innerHTML = '';
    if (this.logEntries.length === 0) {
      const empty = createText('div', 'No log entries', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '4px 0';
      this.logContainer.appendChild(empty);
      return;
    }
    for (const entry of this.logEntries) {
      const line = createElement('div', {}, {
        padding: '1px 0',
        borderBottom: `1px solid ${OVERLAY.border}`,
        wordBreak: 'break-word',
      });
      const colorMap: Record<'info' | 'warn' | 'error', string> = {
        info: OVERLAY.text,
        warn: OVERLAY.warning,
        error: OVERLAY.destructive,
      };
      line.style.color = colorMap[entry.level];
      const time = new Date(entry.time);
      const ts = `${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}:${String(time.getSeconds()).padStart(2, '0')}`;
      const timeSpan = createText('span', ts, 'mono');
      timeSpan.style.color = OVERLAY.textMuted;
      timeSpan.style.marginRight = '6px';
      timeSpan.style.fontSize = '10px';
      line.appendChild(timeSpan);
      const textSpan = document.createTextNode(entry.text);
      line.appendChild(textSpan);
      this.logContainer.appendChild(line);
    }
    this.logContainer.scrollTop = this.logContainer.scrollHeight;
  }
}
