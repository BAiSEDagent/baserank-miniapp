'use client'

import { useEffect, useState } from 'react'

function formatRefreshCountdown(nextRefreshMs: number) {
  const nowMs = Date.now()
  const remain = Math.max(0, Math.floor((nextRefreshMs - nowMs) / 1000))
  const h = Math.floor(remain / 3600)
  const m = Math.floor((remain % 3600) / 60)
  const s = remain % 60
  return `Refreshes in: ${String(h).padStart(2, '0')}h ${String(m).padStart(2, '0')}m ${String(s).padStart(2, '0')}s`
}

export function CountdownTimer({ nextRefreshMs }: { nextRefreshMs: number | null }) {
  const [, setTick] = useState(0)

  useEffect(() => {
    if (!nextRefreshMs) return
    const t = setInterval(() => setTick((v) => v + 1), 1000)
    return () => clearInterval(t)
  }, [nextRefreshMs])

  if (!nextRefreshMs) return <span>Refreshes in: --:--</span>
  return <span>{formatRefreshCountdown(nextRefreshMs)}</span>
}
