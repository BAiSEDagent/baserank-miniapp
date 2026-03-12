import { NextRequest, NextResponse } from 'next/server'
import { createPublicClient, http, getAddress, formatUnits } from 'viem'
import { base } from 'viem/chains'

import { getEventTierConfig, type MarketKind, type TierKey } from '@/lib/event-tier'
import { candidateIdForKey } from '@/lib/candidate-id'
import { TierMarketABI } from '@/lib/contracts/TierMarketABI'

export const dynamic = 'force-dynamic'

const rpcUrl = process.env.PAYMASTER_URL || 'https://mainnet.base.org'
const client = createPublicClient({ chain: base, transport: http(rpcUrl) })

const TIER_LABELS: Record<TierKey, string> = {
  top10: 'top10',
  top5: 'top5',
  top1: 'top1',
}

type LeaderboardEntry = {
  projectId: string
  projectName: string
  iconUrl?: string
  rank?: number
  weeklyTransactingUsers?: string
}

function allMarkets() {
  const cfg = getEventTierConfig(base.id)
  return {
    cfg,
    markets: [
      cfg.markets.app.top10,
      cfg.markets.app.top5,
      cfg.markets.app.top1,
      cfg.markets.chain.top10,
      cfg.markets.chain.top5,
      cfg.markets.chain.top1,
    ],
  }
}

export async function GET(req: NextRequest) {
  const addr = req.nextUrl.searchParams.get('address')
  if (!addr) return NextResponse.json({ positions: [], total: 0 })

  try {
    const user = getAddress(addr)
    const { markets, cfg } = allMarkets()

    const [appRes, chainRes] = await Promise.all([
      fetch(`${req.nextUrl.origin}/api/leaderboard?market=app`, { cache: 'no-store' }),
      fetch(`${req.nextUrl.origin}/api/leaderboard?market=chain`, { cache: 'no-store' }),
    ])
    const appData = await appRes.json()
    const chainData = await chainRes.json()
    const appEntries = (appData.entries ?? []) as LeaderboardEntry[]
    const chainEntries = (chainData.entries ?? []) as LeaderboardEntry[]

    const candidates = [
      ...appEntries.map((e) => ({ ...e, market: 'app' as MarketKind })),
      ...chainEntries.map((e) => ({ ...e, market: 'chain' as MarketKind })),
    ]

    const calls = markets.flatMap((market) => {
      const list = candidates.filter((c) => c.market === market.kind)
      return list.flatMap((entry) => {
        const candidateId = candidateIdForKey({ market: market.kind, candidateKey: entry.projectId })
        return [
          {
            address: market.address,
            abi: TierMarketABI,
            functionName: 'userCandidateStake' as const,
            args: [user, candidateId] as const,
            meta: { market, entry, candidateId, kind: 'stake' as const },
          },
          {
            address: market.address,
            abi: TierMarketABI,
            functionName: 'claimable' as const,
            args: [user] as const,
            meta: { market, entry, candidateId, kind: 'claimable' as const },
          },
          {
            address: market.address,
            abi: TierMarketABI,
            functionName: 'status' as const,
            args: [] as const,
            meta: { market, entry, candidateId, kind: 'status' as const },
          },
          {
            address: market.address,
            abi: TierMarketABI,
            functionName: 'noWinner' as const,
            args: [] as const,
            meta: { market, entry, candidateId, kind: 'noWinner' as const },
          },
          {
            address: market.address,
            abi: TierMarketABI,
            functionName: 'finalized' as const,
            args: [] as const,
            meta: { market, entry, candidateId, kind: 'finalized' as const },
          },
        ]
      })
    })

    const results: Array<{ status: 'success'; result: unknown } | { status: 'failure'; error: unknown }> = []
    for (let i = 0; i < calls.length; i += 100) {
      const chunk = calls.slice(i, i + 100)
      const chunkResults = await client.multicall({
        contracts: chunk.map(({ meta: _meta, ...rest }) => rest),
        allowFailure: true,
      })
      results.push(...chunkResults)
    }

    const positions: Array<{
      app: string
      candidateKey: string
      candidateId: `0x${string}`
      market: string
      tier: string
      amount: string
      claimable: string
      rank: number | null
      iconUrl: string | null
      weeklyUsers: string | null
      betType?: string
      resolved: boolean
      cancelled: boolean
      noWinner: boolean
      finalized: boolean
      marketAddress: `0x${string}`
      eventId: string
    }> = []

    for (let i = 0; i < calls.length; i += 5) {
      const stakeRes = results[i]
      const claimableRes = results[i + 1]
      const statusRes = results[i + 2]
      const noWinnerRes = results[i + 3]
      const finalizedRes = results[i + 4]
      const meta = calls[i].meta

      const stake = stakeRes?.status === 'success' ? (stakeRes.result as bigint) : BigInt(0)
      if (stake <= BigInt(0)) continue

      const claimable = claimableRes?.status === 'success' ? (claimableRes.result as bigint) : BigInt(0)
      const status = statusRes?.status === 'success' ? Number(statusRes.result as bigint | number) : 0
      const noWinner = noWinnerRes?.status === 'success' ? Boolean(noWinnerRes.result) : false
      const finalized = finalizedRes?.status === 'success' ? Boolean(finalizedRes.result) : false

      positions.push({
        app: meta.entry.projectName,
        candidateKey: meta.entry.projectId,
        candidateId: meta.candidateId,
        market: meta.market.kind === 'app' ? 'App' : 'Chain',
        tier: TIER_LABELS[meta.market.tier],
        amount: formatUnits(stake, 6),
        claimable: formatUnits(claimable, 6),
        rank: meta.entry.rank ?? null,
        iconUrl: meta.entry.iconUrl ?? null,
        weeklyUsers: meta.entry.weeklyTransactingUsers ?? null,
        betType: TIER_LABELS[meta.market.tier],
        resolved: status === 2,
        cancelled: status === 3,
        noWinner,
        finalized,
        marketAddress: meta.market.address,
        eventId: cfg.activeEventId.toString(),
      })
    }

    positions.sort((a, b) => Number(b.amount) - Number(a.amount))
    const total = positions.reduce((sum, p) => sum + Number(p.amount), 0)
    return NextResponse.json({ positions, total, queriedAddress: user })
  } catch (e) {
    return NextResponse.json({ positions: [], total: 0, error: String(e) }, { status: 500 })
  }
}
