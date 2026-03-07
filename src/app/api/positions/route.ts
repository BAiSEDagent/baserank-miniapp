import { NextRequest, NextResponse } from 'next/server'
import { createPublicClient, http, parseAbiItem, formatUnits, keccak256, encodePacked, getAddress } from 'viem'
import { base } from 'viem/chains'

export const dynamic = 'force-dynamic'

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')
const client = createPublicClient({ chain: base, transport: http('https://mainnet.base.org') })

const predictedEvent = parseAbiItem(
  'event Predicted(uint64 indexed epochId, uint8 indexed marketType, address indexed user, bytes32 candidateId, uint256 amount)',
)

export async function GET(req: NextRequest) {
  const addr = req.nextUrl.searchParams.get('address')
  const epoch = req.nextUrl.searchParams.get('epoch')
  if (!addr || !epoch) return NextResponse.json({ positions: [], total: 0 })

  try {
    const userAddr = getAddress(addr)
    const epochId = BigInt(epoch)
    const block = await client.getBlockNumber()
    const fromBlock = block - BigInt(100000) // ~5 days on Base

    const logs = await client.getLogs({
      address: V2,
      event: predictedEvent,
      args: { epochId, user: userAddr },
      fromBlock: fromBlock > BigInt(0) ? fromBlock : BigInt(0),
      toBlock: 'latest',
    })

    // Group by candidateId + marketType
    const map = new Map<string, { candidateId: string; market: string; total: bigint }>()
    for (const log of logs) {
      const cid = log.args.candidateId ?? ''
      const mt = log.args.marketType === 0 ? 'App' : 'Chain'
      const key = `${mt}:${cid}`
      const existing = map.get(key)
      const amt = log.args.amount ?? BigInt(0)
      if (existing) existing.total += amt
      else map.set(key, { candidateId: cid, market: mt, total: amt })
    }

    // Reverse-map candidateId to app names
    const [appRes, chainRes] = await Promise.all([
      fetch(`${req.nextUrl.origin}/api/leaderboard?market=app`),
      fetch(`${req.nextUrl.origin}/api/leaderboard?market=chain`),
    ])
    const appData = await appRes.json()
    const chainData = await chainRes.json()
    const nameMap = new Map<string, string>()
    for (const e of [...(appData.entries ?? []), ...(chainData.entries ?? [])]) {
      const appHash = keccak256(encodePacked(['string'], [`app:${e.projectName}`]))
      const chainHash = keccak256(encodePacked(['string'], [`chain:${e.projectName}`]))
      nameMap.set(`App:${appHash}`, e.projectName)
      nameMap.set(`Chain:${chainHash}`, e.projectName)
    }

    const positions = Array.from(map.entries()).map(([key, val]) => ({
      app: nameMap.get(key) ?? `Unknown (${val.candidateId.slice(0, 10)}...)`,
      market: val.market,
      amount: formatUnits(val.total, 6),
    })).sort((a, b) => Number(b.amount) - Number(a.amount))

    const total = positions.reduce((s, p) => s + Number(p.amount), 0)

    return NextResponse.json({ positions, total })
  } catch {
    return NextResponse.json({ positions: [], total: 0 })
  }
}
