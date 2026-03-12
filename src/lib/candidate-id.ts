import { encodePacked, keccak256 } from 'viem'
import type { MarketKind } from './event-tier'

export function canonicalCandidateKey(input: { market: MarketKind; candidateKey: string }) {
  const normalized = input.candidateKey.trim()
  if (!normalized) throw new Error('candidateKey is required for candidate ID derivation')
  return `${input.market}:${normalized}`
}

/**
 * Canonical candidate ID helper for BaseRank event-tier UI.
 *
 * IMPORTANT:
 * This must stay byte-for-byte aligned with resolver/tooling/docs.
 * Candidate keys should come from a stable canonical identifier (projectId/slug),
 * not mutable display copy.
 */
export function candidateIdForKey(input: { market: MarketKind; candidateKey: string }): `0x${string}` {
  return keccak256(encodePacked(['string'], [canonicalCandidateKey(input)]))
}
