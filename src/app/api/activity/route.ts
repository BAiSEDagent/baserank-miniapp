import { NextRequest, NextResponse } from 'next/server'
import { createPublicClient, http, formatUnits } from 'viem'
import { base } from 'viem/chains'

import { getEventTierConfig, type MarketKind, type TierKey } from '@/lib/event-tier'
import { TierMarketABI } from '@/lib/contracts/TierMarketABI'
import { EventRegistryABI } from '@/lib/contracts/EventRegistryABI'

export const dynamic = 'force-dynamic'

const rpcUrl = process.env.PAYMASTER_URL || 'https://mainnet.base.org'
const client = createPublicClient({ chain: base, transport: http(rpcUrl) })

const MARKET_LABELS: Record<MarketKind, string> = {
  app: 'App Market',
  chain: 'Chain Market',
}

const TIER_LABELS: Record<TierKey, string> = {
  top10: 'Top 10',
  top5: 'Top 5',
  top1: '#1',
}

const STATE_LABELS = ['Open', 'Locked', 'Resolved', 'Cancelled'] as const

type MarketSummary = {
  kind: MarketKind
  tier: TierKey
  label: string
  address: `0x${string}`
  pool: string
  state: number
  stateLabel: string
  noWinner: boolean
  finalized: boolean
}

export async function GET(_req: NextRequest) {
  try {
    const cfg = getEventTierConfig(base.id)

    const markets = [
      cfg.markets.app.top10,
      cfg.markets.app.top5,
      cfg.markets.app.top1,
      cfg.markets.chain.top10,
      cfg.markets.chain.top5,
      cfg.markets.chain.top1,
    ]

    const contracts = markets.flatMap((m) => [
      { address: m.address, abi: TierMarketABI, functionName: 'totalStaked' as const },
      { address: m.address, abi: TierMarketABI, functionName: 'status' as const },
      { address: m.address, abi: TierMarketABI, functionName: 'noWinner' as const },
      { address: m.address, abi: TierMarketABI, functionName: 'finalized' as const },
    ])

    const results = await client.multicall({ contracts, allowFailure: true })

    const marketSummaries: MarketSummary[] = markets.map((m, i) => {
      const r = results.slice(i * 4, i * 4 + 4)
      const totalStaked = r[0]?.status === 'success' ? (r[0].result as bigint) : BigInt(0)
      const state = r[1]?.status === 'success' ? Number(r[1].result as bigint | number) : 0
      const noWinner = r[2]?.status === 'success' ? Boolean(r[2].result) : false
      const finalized = r[3]?.status === 'success' ? Boolean(r[3].result) : false
      return {
        kind: m.kind,
        tier: m.tier,
        label: `${MARKET_LABELS[m.kind]} · ${TIER_LABELS[m.tier]}`,
        address: m.address,
        pool: formatUnits(totalStaked, 6),
        state,
        stateLabel: STATE_LABELS[state] ?? 'Unknown',
        noWinner,
        finalized,
      }
    })

    const timing = await client.readContract({
      address: cfg.registryAddress,
      abi: EventRegistryABI,
      functionName: 'getEventTiming',
      args: [cfg.activeEventId],
    }) as readonly [bigint, bigint, bigint, bigint, `0x${string}`, `0x${string}`]

    const claimsOpenAt = await client.readContract({
      address: cfg.registryAddress,
      abi: EventRegistryABI,
      functionName: 'claimsOpenAt',
      args: [cfg.activeEventId],
    }) as bigint

    const claimDeadline = await client.readContract({
      address: cfg.registryAddress,
      abi: EventRegistryABI,
      functionName: 'claimDeadline',
      args: [cfg.activeEventId],
    }) as bigint

    const totalPoolRaw = markets.reduce((sum, _m, i) => {
      const res = results[i * 4]
      const totalStaked = res?.status === 'success' ? (res.result as bigint) : BigInt(0)
      return sum + totalStaked
    }, BigInt(0))

    const totalPool = formatUnits(totalPoolRaw, 6)

    return NextResponse.json({
      eventId: cfg.activeEventId.toString(),
      timing: {
        lockTime: timing[0].toString(),
        resolveTime: timing[1].toString(),
        resolutionTimeout: timing[2].toString(),
        claimWindow: timing[3].toString(),
        claimsOpenAt: claimsOpenAt.toString(),
        claimDeadline: claimDeadline.toString(),
      },
      markets: marketSummaries,
      totalPool,
    })
  } catch (error) {
    return NextResponse.json({ error: String(error), markets: [], totalPool: '0' }, { status: 500 })
  }
}
