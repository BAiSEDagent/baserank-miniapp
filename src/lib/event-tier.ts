import { getAddress, type Address } from 'viem'

export type MarketKind = 'app' | 'chain'
export type TierKey = 'top10' | 'top5' | 'top1'

export enum EventStatus {
  OPEN = 0,
  RESOLVE_SUBMITTED = 1,
  RESOLVED = 2,
  CANCELLED = 3,
}

export enum MarketStatus {
  OPEN = 0,
  LOCKED = 1,
  RESOLVED = 2,
  CANCELLED = 3,
}

export type CandidateMetadata = {
  candidateId: `0x${string}`
  projectName: string
  appUrl?: string
  iconUrl?: string
  market: MarketKind
}

export type EventTiming = {
  lockTime: bigint
  resolveTime: bigint
  resolutionTimeout: bigint
  claimWindow: bigint
  eventResolver: Address
  eventGovernance: Address
}

export type EventMeta = {
  status: EventStatus
  lockTime: bigint
  resolveTime: bigint
  claimWindow: bigint
  submittedAt: bigint
  finalizedAt: bigint
  cancelledAt: bigint
  resolutionHash: `0x${string}`
  snapshotHash: `0x${string}`
  resolvedBy: Address
}

export type TierMarketConfig = {
  address: Address
  kind: MarketKind
  tier: TierKey
  tierThreshold: 10 | 5 | 1
  label: 'Top 10' | 'Top 5' | '#1'
}

export type EventTierConfig = {
  chainId: number
  activeEventId: bigint
  registryAddress: Address
  batchClaimerAddress: Address
  markets: Record<MarketKind, Record<TierKey, TierMarketConfig>>
}

export type EventTierPosition = {
  marketAddress: Address
  eventId: bigint
  market: MarketKind
  tier: TierKey
  candidateId: `0x${string}`
  projectName?: string
  amount: bigint
  claimable: bigint
  resolved: boolean
  cancelled: boolean
  noWinner: boolean
  finalized: boolean
}

function requireAddress(name: string, value: string | undefined): Address {
  const cleaned = (value ?? '').replace(/^["'\s]+|["'\s]+$/g, '')
  if (!cleaned) {
    throw new Error(`Missing required event-tier env: ${name}`)
  }
  return getAddress(cleaned)
}

function requireEventId(name: string, value: string | undefined): bigint {
  const cleaned = (value ?? '').replace(/^["'\s]+|["'\s]+$/g, '')
  if (!cleaned) {
    throw new Error(`Missing required event-tier env: ${name}`)
  }
  try {
    return BigInt(cleaned)
  } catch {
    throw new Error(`Invalid bigint for event-tier env ${name}: ${cleaned}`)
  }
}

function tierConfig(kind: MarketKind, tier: TierKey, label: 'Top 10' | 'Top 5' | '#1', tierThreshold: 10 | 5 | 1, envName: string): TierMarketConfig {
  return {
    address: requireAddress(envName, process.env[envName]),
    kind,
    tier,
    tierThreshold,
    label,
  }
}

export function getEventTierConfig(chainId: number): EventTierConfig {
  return {
    chainId,
    activeEventId: requireEventId('NEXT_PUBLIC_ACTIVE_EVENT_ID', process.env.NEXT_PUBLIC_ACTIVE_EVENT_ID),
    registryAddress: requireAddress('NEXT_PUBLIC_EVENT_REGISTRY_ADDRESS', process.env.NEXT_PUBLIC_EVENT_REGISTRY_ADDRESS),
    batchClaimerAddress: requireAddress('NEXT_PUBLIC_BATCH_CLAIMER_ADDRESS', process.env.NEXT_PUBLIC_BATCH_CLAIMER_ADDRESS),
    markets: {
      app: {
        top10: tierConfig('app', 'top10', 'Top 10', 10, 'NEXT_PUBLIC_APP_TOP10_MARKET_ADDRESS'),
        top5: tierConfig('app', 'top5', 'Top 5', 5, 'NEXT_PUBLIC_APP_TOP5_MARKET_ADDRESS'),
        top1: tierConfig('app', 'top1', '#1', 1, 'NEXT_PUBLIC_APP_TOP1_MARKET_ADDRESS'),
      },
      chain: {
        top10: tierConfig('chain', 'top10', 'Top 10', 10, 'NEXT_PUBLIC_CHAIN_TOP10_MARKET_ADDRESS'),
        top5: tierConfig('chain', 'top5', 'Top 5', 5, 'NEXT_PUBLIC_CHAIN_TOP5_MARKET_ADDRESS'),
        top1: tierConfig('chain', 'top1', '#1', 1, 'NEXT_PUBLIC_CHAIN_TOP1_MARKET_ADDRESS'),
      },
    },
  }
}
