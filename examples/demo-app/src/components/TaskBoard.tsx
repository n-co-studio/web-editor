type Task = {
  id: string;
  title: string;
  assignee: string;
  priority: 'high' | 'medium' | 'low';
  tag: string;
};

type Column = {
  id: string;
  label: string;
  tasks: Task[];
};

const PRIORITY_COLORS: Record<Task['priority'], string> = {
  high: 'var(--color-accent)',
  medium: 'var(--color-warning)',
  low: 'var(--color-success)',
};

const COLUMNS: Column[] = [
  {
    id: 'todo',
    label: 'To Do',
    tasks: [
      { id: 't1', title: 'Audit color token usage', assignee: 'AK', priority: 'high', tag: 'design' },
      { id: 't2', title: 'Update spacing tokens in nav', assignee: 'BL', priority: 'medium', tag: 'ui' },
      { id: 't3', title: 'Write migration guide', assignee: 'CJ', priority: 'low', tag: 'docs' },
    ],
  },
  {
    id: 'in-progress',
    label: 'In Progress',
    tasks: [
      { id: 't4', title: 'Rework card component padding', assignee: 'AK', priority: 'high', tag: 'ui' },
      { id: 't5', title: 'Fix button focus state', assignee: 'DM', priority: 'medium', tag: 'a11y' },
    ],
  },
  {
    id: 'done',
    label: 'Done',
    tasks: [
      { id: 't6', title: 'Set brand primary color', assignee: 'BL', priority: 'high', tag: 'design' },
      { id: 't7', title: 'Baseline typography scale', assignee: 'CJ', priority: 'medium', tag: 'design' },
    ],
  },
];

function Avatar({ initials }: { initials: string }) {
  return (
    <span
      aria-label={`Assignee: ${initials}`}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: 28,
        height: 28,
        borderRadius: 'var(--radius-full)',
        background: 'var(--color-primary)',
        color: '#fff',
        fontSize: 'var(--text-caption)',
        fontWeight: 600,
        fontFamily: 'var(--font-sans)',
        flexShrink: 0,
      }}
    >
      {initials}
    </span>
  );
}

function PriorityDot({ priority }: { priority: Task['priority'] }) {
  return (
    <span
      aria-label={`Priority: ${priority}`}
      style={{
        display: 'inline-block',
        width: 8,
        height: 8,
        borderRadius: 'var(--radius-full)',
        background: PRIORITY_COLORS[priority],
        flexShrink: 0,
      }}
    />
  );
}

function Tag({ label }: { label: string }) {
  return (
    <span
      style={{
        fontSize: 'var(--text-caption)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--color-primary)',
        background: 'color-mix(in srgb, var(--color-primary) 10%, transparent)',
        padding: '2px var(--space-2)',
        borderRadius: 'var(--radius-sm)',
        border: '1px solid color-mix(in srgb, var(--color-primary) 25%, transparent)',
        lineHeight: 1.4,
      }}
    >
      {label}
    </span>
  );
}

function TaskCard({ task }: { task: Task }) {
  return (
    <div
      style={{
        background: 'var(--color-bg)',
        border: '1px solid var(--color-border)',
        borderRadius: 'var(--radius-md)',
        padding: 'var(--space-4)',
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-3)',
        boxShadow: 'var(--shadow-sm)',
        transition: 'box-shadow 0.15s ease',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 'var(--space-2)' }}>
        <PriorityDot priority={task.priority} />
        <p
          style={{
            fontSize: 'var(--text-body-sm)',
            fontWeight: 500,
            color: 'var(--color-text)',
            lineHeight: 1.4,
            flex: 1,
          }}
        >
          {task.title}
        </p>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <Tag label={task.tag} />
        <Avatar initials={task.assignee} />
      </div>
    </div>
  );
}

function BoardColumn({ column }: { column: Column }) {
  return (
    <div
      style={{
        flex: '1 1 280px',
        minWidth: 240,
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-4)',
      }}
    >
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-2)',
        }}
      >
        <h2
          style={{
            fontSize: 'var(--text-body-sm)',
            fontWeight: 600,
            color: 'var(--color-text)',
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
          }}
        >
          {column.label}
        </h2>
        <span
          style={{
            fontSize: 'var(--text-caption)',
            fontWeight: 500,
            color: 'var(--color-text-muted)',
            background: 'var(--color-surface)',
            border: '1px solid var(--color-border)',
            borderRadius: 'var(--radius-full)',
            padding: '1px var(--space-2)',
            lineHeight: 1.5,
          }}
        >
          {column.tasks.length}
        </span>
      </div>

      <div
        style={{
          background: 'var(--color-surface)',
          borderRadius: 'var(--radius-lg)',
          padding: 'var(--space-4)',
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--space-3)',
          minHeight: 120,
        }}
      >
        {column.tasks.map((task) => (
          <TaskCard key={task.id} task={task} />
        ))}
      </div>
    </div>
  );
}

export default function TaskBoard() {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-6)',
      }}
    >
      <div>
        <h1
          style={{
            fontSize: 'var(--text-h1)',
            fontWeight: 700,
            color: 'var(--color-text)',
            letterSpacing: '-0.02em',
            lineHeight: 1.25,
          }}
        >
          Design System Sprint
        </h1>
        <p
          style={{
            marginTop: 'var(--space-2)',
            fontSize: 'var(--text-body-sm)',
            color: 'var(--color-text-muted)',
          }}
        >
          Token-driven UI — try editing a color, spacing value, or type size with NCO Studio Web Editor.
        </p>
      </div>

      <div
        style={{
          display: 'flex',
          gap: 'var(--space-6)',
          alignItems: 'flex-start',
          flexWrap: 'wrap',
        }}
      >
        {COLUMNS.map((col) => (
          <BoardColumn key={col.id} column={col} />
        ))}
      </div>

      <footer
        style={{
          borderTop: '1px solid var(--color-border)',
          paddingTop: 'var(--space-4)',
          display: 'flex',
          gap: 'var(--space-6)',
        }}
      >
        {(['high', 'medium', 'low'] as const).map((p) => (
          <div key={p} style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-2)' }}>
            <PriorityDot priority={p} />
            <span
              style={{
                fontSize: 'var(--text-caption)',
                color: 'var(--color-text-muted)',
                textTransform: 'capitalize',
              }}
            >
              {p} priority
            </span>
          </div>
        ))}
      </footer>
    </div>
  );
}
