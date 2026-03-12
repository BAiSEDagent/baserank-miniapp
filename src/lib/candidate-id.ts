import { encodePacked, keccak256 } from 'viem'
import type { MarketKind } from './event-tier'

export function candidateKey(input: { market: MarketKind; projectName: string }) {
  const normalized = input.projectName.trim()
  if (!normalized) throw new Error('projectName is required for candidate ID derivation')
  return `${input.market}:${normalized}`
}

/**
 * Canonical candidate ID helper for BaseRank event-tier UI.
 *
 * IMPORTANT:
 * This must stay byte-for-byte aligned with resolver/tooling/docs.
 * Current convention: keccak256(abi.encodePacked("<market>:<projectName>"))
 * Example: "app:Clash of Coins" or "chain:Base App"
 */
export function candidateIdForProject(input: { market: MarketKind; projectName: string }): `0x${string}` {
  return keccak256(encodePacked(['string'], [candidateKey(input)]))
}
