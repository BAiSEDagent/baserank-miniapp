import { NextResponse } from 'next/server'

export const revalidate = 60
export const dynamic = 'force-dynamic'

// V2: All candidates are valid — no pre-registration needed

function nextWeeklyResetIso(now = new Date()) {
  // Base leaderboard UI countdown anchor (Wednesday 20:00 UTC)
  const d = new Date(now)
  const out = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 20, 0, 0, 0))
  const day = out.getUTCDay() // 0=Sun ... 3=Wed
  let addDays = (3 - day + 7) % 7
  if (addDays === 0 && d.getUTCHours() >= 20) addDays = 7
  out.setUTCDate(out.getUTCDate() + addDays)
  return out.toISOString()
}

export async function GET(req: Request) {
  const fallbackNext = nextWeeklyResetIso(new Date())
  const { searchParams } = new URL(req.url)
  const market = searchParams.get('market') === 'chain' ? 'chain' : 'app'
  const leaderboardType = market === 'chain' ? 'LEADERBOARD_TYPE_BASE_CHAIN' : 'LEADERBOARD_TYPE_BASE_APP'

  try {
    const res = await fetch(`https://www.base.dev/v1/leaderboard?leaderboard_type=${leaderboardType}`, {
      headers: {
        'content-type': 'application/json',
        'user-agent': 'BaseRank/1.0 (+https://baserank-miniapp.vercel.app)',
      },
      next: { revalidate: 60 },
    })

    if (!res.ok) throw new Error(`Leaderboard fetch failed: ${res.status}`)

    const raw = (await res.json()) as {
      lastUpdated?: string
      entries?: Array<{
        rank: number
        projectId: string
        projectName: string
        appUrl?: string
        weeklyTransactingUsers?: string
        totalTransactions?: string
        iconUrl?: string
      }>
    }

    // V2: All leaderboard entries are tradeable — any candidateId works
    const entries = (raw.entries ?? []).slice(0, 50).map((e) => ({
      rank: e.rank,
      projectId: e.projectId,
      projectName: e.projectName,
      appUrl: e.appUrl ?? '',
      weeklyTransactingUsers: e.weeklyTransactingUsers ?? '0',
      totalTransactions: e.totalTransactions ?? '0',
      iconUrl: e.iconUrl ?? '',
      tradeable: true,
    }))

    return NextResponse.json({
      source: `base.dev:v1/leaderboard:${leaderboardType}`,
      market,
      fetchedAt: new Date().toISOString(),
      lastUpdated: raw.lastUpdated ?? null,
      nextRefreshAt: fallbackNext,
      entries,
      apps: entries.map((e) => e.projectName),
    })
  } catch {
    return NextResponse.json({
      source: 'fallback-empty',
      market,
      fetchedAt: new Date().toISOString(),
      lastUpdated: null,
      nextRefreshAt: fallbackNext,
      entries: [],
      apps: [],
    })
  }
}
