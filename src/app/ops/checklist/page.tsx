import Link from 'next/link'

export default function OpsChecklistPage() {
  const items = [
    'Preconditions checked (market open, resolveTime reached)',
    'Winner sets validated (Top10/Top5/Top1, no duplicates, in candidate set)',
    'Snapshot payload built and keccak256 hash computed',
    'Top10 resolved and event verified',
    'Top5 resolved and event verified',
    'Top1 resolved and event verified',
    'Claimability spot-check (winner > 0, loser = 0)',
    'Fees collected to Base Safe (once per tier)',
    'Transparency post published with snapshot hash and source URL',
  ]

  return (
    <main className="min-h-screen bg-white pb-24 text-zinc-950 dark:bg-zinc-950 dark:text-white">
      <header className="sticky top-0 z-40 border-b border-zinc-200 bg-white px-4 py-3 dark:border-zinc-800 dark:bg-zinc-950">
        <Link href="/" className="text-lg font-bold tracking-tight text-[#0052FF]">
          ← Back to Markets
        </Link>
      </header>

      <div className="mx-auto max-w-md px-4 py-5">
        <h1 className="text-4xl font-extrabold tracking-tighter">Ops Checklist</h1>
        <p className="mt-2 text-sm text-zinc-500">Weekly settlement checklist for trusted resolver operations.</p>

        <section className="mt-5 border border-zinc-200 dark:border-zinc-800">
          {items.map((item, idx) => (
            <div key={item} className="flex items-start justify-between gap-3 border-b border-zinc-100 px-4 py-4 last:border-b-0 dark:border-zinc-900">
              <div>
                <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Step {idx + 1}</p>
                <p className="mt-1 text-sm font-medium leading-relaxed">{item}</p>
              </div>
              <span className="mt-1 rounded-full bg-[#0052FF] px-2 py-1 text-[10px] font-bold text-white">Check</span>
            </div>
          ))}
        </section>

        <p className="mt-4 text-xs text-zinc-500">Reference: RUNBOOK_RESOLUTION.md</p>
      </div>

      <nav className="fixed bottom-0 left-0 right-0 z-50 border-t border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950">
        <div className="mx-auto grid h-16 max-w-md grid-cols-4">
          {[
            { href: '/', label: 'Markets', icon: '◫' },
            { href: '/', label: 'Positions', icon: '◎' },
            { href: '/ops/checklist', label: 'Resolve', icon: '◉' },
            { href: '/', label: 'Profile', icon: '◌' },
          ].map((item) => (
            <Link
              key={item.label}
              href={item.href}
              className={`grid min-h-11 min-w-11 place-items-center px-2 text-xs ${item.label === 'Resolve' ? 'font-semibold text-[#0052FF]' : 'text-zinc-400'}`}
            >
              <div className="flex flex-col items-center gap-1">
                <span className="text-sm">{item.icon}</span>
                <span>{item.label}</span>
              </div>
            </Link>
          ))}
        </div>
      </nav>
    </main>
  )
}
