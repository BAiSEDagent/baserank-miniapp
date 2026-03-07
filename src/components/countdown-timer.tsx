'use client'

import { useEffect, useState } from 'react'

function formatCountdown(targetMs: number, label = 'Refreshes in') {
  const remain = Math.max(0, Math.floor((targetMs - Date.now()) / 1000))
  const h = Math.floor(remain / 3600)
  const m = Math.floor((remain % 3600) / 60)
  const s = remain % 60
  return `${label}: ${String(h).padStart(2, '0')}h ${String(m).padStart(2, '0')}m ${String(s).padStart(2, '0')}s`
}

export function CountdownTimer({ nextRefreshMs, label }: { nextRefreshMs: number | null; label?: string }) {
  const [, setTick] = useState(0)

  useEffect(() => {
    if (!nextRefreshMs) return
    const t = setInterval(() => setTick((v) => v + 1), 1000)
    return () => clearInterval(t)
  }, [nextRefreshMs])

  if (!nextRefreshMs) return <span>{label ?? 'Locks in'}: --:--</span>
  return <span>{formatCountdown(nextRefreshMs, label ?? 'Locks in')}</span>
}
