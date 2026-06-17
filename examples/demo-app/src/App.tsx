import TaskBoard from './components/TaskBoard';

export default function App() {
  return (
    <div
      style={{
        minHeight: '100vh',
        background: 'var(--color-bg)',
        display: 'flex',
        flexDirection: 'column',
      }}
    >
      <header
        style={{
          borderBottom: '1px solid var(--color-border)',
          padding: 'var(--space-4) var(--space-6)',
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-3)',
          background: 'var(--color-bg)',
          boxShadow: 'var(--shadow-sm)',
        }}
      >
        <div
          style={{
            width: 32,
            height: 32,
            borderRadius: 'var(--radius-md)',
            background: 'var(--color-primary)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
            <rect x="2" y="2" width="6" height="6" rx="1.5" fill="white" />
            <rect x="10" y="2" width="6" height="6" rx="1.5" fill="white" opacity="0.6" />
            <rect x="2" y="10" width="6" height="6" rx="1.5" fill="white" opacity="0.6" />
            <rect x="10" y="10" width="6" height="6" rx="1.5" fill="white" opacity="0.8" />
          </svg>
        </div>
        <span
          style={{
            fontWeight: 700,
            fontSize: 'var(--text-h3)',
            color: 'var(--color-text)',
            letterSpacing: '-0.01em',
          }}
        >
          Project Tasks
        </span>
        <span
          style={{
            marginLeft: 'auto',
            fontSize: 'var(--text-caption)',
            color: 'var(--color-text-muted)',
            fontFamily: 'var(--font-mono)',
            background: 'var(--color-surface)',
            padding: 'var(--space-1) var(--space-2)',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-border)',
          }}
        >
          NCO Studio Demo
        </span>
      </header>

      <main
        style={{
          flex: 1,
          padding: 'var(--space-6)',
          maxWidth: 1280,
          margin: '0 auto',
          width: '100%',
        }}
      >
        <TaskBoard />
      </main>
    </div>
  );
}
