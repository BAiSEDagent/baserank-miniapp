import { NextRequest, NextResponse } from 'next/server'
import { keccak256, encodePacked, getAddress, formatUnits, decodeAbiParameters } from 'viem'

export const dynamic = 'force-dynamic'

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')
const PREDICTED_TOPIC = '0x1c6b4a5ce930ee93d9456c68f1139238d04936108b1c23e650a12a696e8dc747'

export async function GET(req: NextRequest) {
  const addr = req.nextUrl.searchParams.get('address')
  const epoch = req.nextUrl.searchParams.get('epoch')
  if (!addr || !epoch) return NextResponse.json({ positions: [], total: 0 })

  try {
    const userAddr = getAddress(addr)
    const epochHex = '0x' + BigInt(epoch).toString(16).padStart(64, '0')
    const userTopic = '0x' + userAddr.toLowerCase().replace('0x', '').padStart(64, '0')

    // Use Basescan API to get logs — no block range limit
    const url = `https://api.etherscan.io/v2/api?chainid=8453&module=logs&action=getLogs&address=${V2}&topic0=${PREDICTED_TOPIC}&topic1=${epochHex}&topic3=${userTopic}&apikey=6VMQBBH5WT4G77BVPXDDAZT9P3GBTWB4G1`

    const res = await fetch(url)
    const data = await res.json()
    const logs = data.result ?? []

    // Decode logs
    const map = new Map<string, { candidateId: string; market: string; total: bigint }>()
    for (const log of logs) {
      if (typeof log !== 'object' || !log.data) continue
      const [candidateId, amount] = decodeAbiParameters(
        [{ name: 'candidateId', type: 'bytes32' }, { name: 'amount', type: 'uint256' }],
        log.data,
      )
      const marketType = parseInt(log.topics[2], 16)
      const mt = marketType === 0 ? 'App' : 'Chain'
      const key = `${mt}:${candidateId}`
      const existing = map.get(key)
      if (existing) existing.total += amount
      else map.set(key, { candidateId, market: mt, total: amount })
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
  } catch (e) {
    return NextResponse.json({ positions: [], total: 0, error: String(e) })
  }
}
