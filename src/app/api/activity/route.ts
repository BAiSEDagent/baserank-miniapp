import { NextResponse } from 'next/server'
import { getAddress, formatUnits, decodeAbiParameters } from 'viem'

export const dynamic = 'force-dynamic'
export const revalidate = 15

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')
const PREDICTED_TOPIC = '0x1c6b4a5ce930ee93d9456c68f1139238d04936108b1c23e650a12a696e8dc747'

export async function GET() {
  try {
    // Use Basescan API — no block range limits
    const url = `https://api.etherscan.io/v2/api?chainid=8453&module=logs&action=getLogs&address=${V2}&topic0=${PREDICTED_TOPIC}&apikey=6VMQBBH5WT4G77BVPXDDAZT9P3GBTWB4G1&page=1&offset=20`

    const res = await fetch(url)
    const data = await res.json()
    const logs = data.result ?? []

    const activity = logs
      .filter((log: { data?: string }) => typeof log === 'object' && log.data)
      .map((log: { data: string; topics: string[]; blockNumber: string; transactionHash: string }) => {
        const [, amount] = decodeAbiParameters(
          [{ name: 'candidateId', type: 'bytes32' }, { name: 'amount', type: 'uint256' }],
          log.data as `0x${string}`,
        )
        const user = '0x' + log.topics[3].slice(26)
        const marketType = parseInt(log.topics[2], 16)
        return {
          user: `${user.slice(0, 6)}...${user.slice(-4)}`,
          amount: formatUnits(amount, 6),
          marketType: marketType === 0 ? 'App' : 'Chain',
          blockNumber: parseInt(log.blockNumber, 16).toString(),
          txHash: log.transactionHash,
        }
      })
      .reverse()
      .slice(0, 20)

    return NextResponse.json({ activity, count: activity.length })
  } catch {
    return NextResponse.json({ activity: [], count: 0 })
  }
}
