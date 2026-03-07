import { NextRequest, NextResponse } from 'next/server'
import { createPublicClient, http, getAddress, keccak256, encodePacked, formatUnits } from 'viem'
import { base } from 'viem/chains'

export const dynamic = 'force-dynamic'

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')

const MARKET_ABI = [
  {
    name: 'userStakeByCandidate',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'epochId', type: 'uint64' },
      { name: 'marketType', type: 'uint8' },
      { name: 'user', type: 'address' },
      { name: 'candidateId', type: 'bytes32' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'userTotalStake',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'epochId', type: 'uint64' },
      { name: 'marketType', type: 'uint8' },
      { name: 'user', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

// Use CDP RPC — public mainnet.base.org rate-limits multicall
const rpcUrl = process.env.PAYMASTER_URL || 'https://mainnet.base.org'
const client = createPublicClient({ chain: base, transport: http(rpcUrl) })

/** Check if an address has any stake at all (cheap — 2 calls) */
async function hasTotalStake(epochId: bigint, user: `0x${string}`): Promise<boolean> {
  const [appStake, chainStake] = await client.multicall({
    contracts: [
      { address: V2, abi: MARKET_ABI, functionName: 'userTotalStake', args: [epochId, 0, user] },
      { address: V2, abi: MARKET_ABI, functionName: 'userTotalStake', args: [epochId, 1, user] },
    ],
    allowFailure: true,
  })
  const a = appStake.status === 'success' ? (appStake.result as bigint) : BigInt(0)
  const c = chainStake.status === 'success' ? (chainStake.result as bigint) : BigInt(0)
  return a + c > BigInt(0)
}

/** Full position breakdown via multicall across all leaderboard candidates */
async function getPositions(epochId: bigint, user: `0x${string}`, origin: string) {
  const [appRes, chainRes] = await Promise.all([
    fetch(`${origin}/api/leaderboard?market=app`),
    fetch(`${origin}/api/leaderboard?market=chain`),
  ])
  const appData = await appRes.json()
  const chainData = await chainRes.json()
  const appNames: string[] = (appData.entries ?? []).map((e: { projectName: string }) => e.projectName)
  const chainNames: string[] = (chainData.entries ?? []).map((e: { projectName: string }) => e.projectName)

  const calls = [
    ...appNames.map((name: string) => ({
      address: V2 as `0x${string}`,
      abi: MARKET_ABI,
      functionName: 'userStakeByCandidate' as const,
      args: [epochId, 0 as const, user, keccak256(encodePacked(['string'], [`app:${name}`]))] as const,
      _meta: { market: 'App', name },
    })),
    ...chainNames.map((name: string) => ({
      address: V2 as `0x${string}`,
      abi: MARKET_ABI,
      functionName: 'userStakeByCandidate' as const,
      args: [epochId, 1 as const, user, keccak256(encodePacked(['string'], [`chain:${name}`]))] as const,
      _meta: { market: 'Chain', name },
    })),
  ]

  // Batch in chunks of 25
  const allResults: Array<{ status: 'success'; result: unknown } | { status: 'failure'; error: Error }> = []
  for (let i = 0; i < calls.length; i += 25) {
    const chunk = calls.slice(i, i + 25)
    const chunkResults = await client.multicall({
      contracts: chunk.map(({ _meta: _unused, ...c }) => c),
      allowFailure: true,
    })
    allResults.push(...chunkResults)
  }

  const positions = []
  for (let i = 0; i < allResults.length; i++) {
    const r = allResults[i]
    if (r.status === 'success') {
      const amt = r.result as bigint
      if (amt > BigInt(0)) {
        positions.push({
          app: calls[i]._meta.name,
          market: calls[i]._meta.market,
          amount: formatUnits(amt, 6),
        })
      }
    }
  }
  positions.sort((a, b) => Number(b.amount) - Number(a.amount))
  const total = positions.reduce((s, p) => s + Number(p.amount), 0)
  return { positions, total, queriedAddress: user }
}

export async function GET(req: NextRequest) {
  const addr = req.nextUrl.searchParams.get('address')
  const epoch = req.nextUrl.searchParams.get('epoch')
  if (!addr || !epoch) return NextResponse.json({ positions: [], total: 0 })

  try {
    const userAddr = getAddress(addr)
    const epochId = BigInt(epoch)

    // Step 1: Quick check if this address has any stake (2 calls)
    const hasStake = await hasTotalStake(epochId, userAddr)

    if (hasStake) {
      // Address has stake — get full breakdown
      return NextResponse.json(await getPositions(epochId, userAddr, req.nextUrl.origin))
    }

    // Step 2: No stake for this address — it might be an EOA whose Smart Wallet placed bets.
    // Check the Coinbase Smart Wallet factory to resolve the Smart Wallet address.
    // CoinbaseSmartWalletFactory at 0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a
    // getAddress(owners, nonce) returns the counterfactual Smart Wallet address
    try {
      const factoryResult = await client.readContract({
        address: '0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a',
        abi: [{
          name: 'getAddress',
          type: 'function',
          stateMutability: 'view',
          inputs: [
            { name: 'owners', type: 'bytes[]' },
            { name: 'nonce', type: 'uint256' },
          ],
          outputs: [{ name: '', type: 'address' }],
        }],
        functionName: 'getAddress',
        // Owner is the raw bytes of the EOA address (abi.encode(address))
        args: [[userAddr as `0x${string}`], BigInt(0)],
      }) as `0x${string}`

      const smartWalletAddr = getAddress(factoryResult)
      if (smartWalletAddr.toLowerCase() !== userAddr.toLowerCase()) {
        const swHasStake = await hasTotalStake(epochId, smartWalletAddr)
        if (swHasStake) {
          return NextResponse.json(await getPositions(epochId, smartWalletAddr, req.nextUrl.origin))
        }
      }
    } catch {
      // Factory call failed — try brute force with known Smart Wallet if available
    }

    // No positions found for either address
    return NextResponse.json({ positions: [], total: 0, queriedAddress: userAddr })
  } catch (e) {
    return NextResponse.json({ positions: [], total: 0, error: String(e) })
  }
}
