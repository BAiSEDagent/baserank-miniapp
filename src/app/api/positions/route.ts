import { NextRequest, NextResponse } from 'next/server'
import { createPublicClient, http, getAddress, keccak256, encodePacked, formatUnits } from 'viem'
import { base } from 'viem/chains'

export const dynamic = 'force-dynamic'

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')

// userStakeByCandidate(uint64 epochId, uint8 marketType, address user, bytes32 candidateId) returns (uint256)
const USER_STAKE_ABI = [{
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
}] as const

export async function GET(req: NextRequest) {
  const addr = req.nextUrl.searchParams.get('address')
  const epoch = req.nextUrl.searchParams.get('epoch')
  if (!addr || !epoch) return NextResponse.json({ positions: [], total: 0 })

  try {
    const userAddr = getAddress(addr)
    const epochId = BigInt(epoch)
    // Use CDP RPC — public mainnet.base.org rate-limits multicall
    const rpcUrl = process.env.PAYMASTER_URL || 'https://mainnet.base.org'
    const client = createPublicClient({ chain: base, transport: http(rpcUrl) })

    // Fetch leaderboard to get all app names
    const [appRes, chainRes] = await Promise.all([
      fetch(`${req.nextUrl.origin}/api/leaderboard?market=app`),
      fetch(`${req.nextUrl.origin}/api/leaderboard?market=chain`),
    ])
    const appData = await appRes.json()
    const chainData = await chainRes.json()
    const appNames: string[] = (appData.entries ?? []).map((e: { projectName: string }) => e.projectName)
    const chainNames: string[] = (chainData.entries ?? []).map((e: { projectName: string }) => e.projectName)

    // Build multicall contracts — one per (marketType × app)
    const calls = [
      ...appNames.map((name: string) => ({
        address: V2,
        abi: USER_STAKE_ABI,
        functionName: 'userStakeByCandidate' as const,
        args: [epochId, 0 as const, userAddr, keccak256(encodePacked(['string'], [`app:${name}`]))] as const,
        _meta: { market: 'App', name },
      })),
      ...chainNames.map((name: string) => ({
        address: V2,
        abi: USER_STAKE_ABI,
        functionName: 'userStakeByCandidate' as const,
        args: [epochId, 1 as const, userAddr, keccak256(encodePacked(['string'], [`chain:${name}`]))] as const,
        _meta: { market: 'Chain', name },
      })),
    ]

    // Batch multicall into chunks of 25 to avoid rate limits
    const chunkSize = 25
    const allResults: Array<{ status: 'success'; result: unknown } | { status: 'failure'; error: Error }> = []
    for (let i = 0; i < calls.length; i += chunkSize) {
      const chunk = calls.slice(i, i + chunkSize)
      const chunkResults = await client.multicall({
        contracts: chunk.map(({ _meta: _unused, ...c }) => c),
        allowFailure: true,
      })
      allResults.push(...chunkResults)
    }
    const results = allResults

    const positions = []
    for (let i = 0; i < results.length; i++) {
      const r = results[i]
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

    return NextResponse.json({ positions, total })
  } catch (e) {
    return NextResponse.json({ positions: [], total: 0, error: String(e) })
  }
}
