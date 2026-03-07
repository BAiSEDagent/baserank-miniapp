import { NextResponse } from 'next/server'
import { createPublicClient, http, parseAbiItem, formatUnits, getAddress } from 'viem'
import { base } from 'viem/chains'

export const dynamic = 'force-dynamic'
export const revalidate = 15

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')

const client = createPublicClient({ chain: base, transport: http('https://mainnet.base.org') })

const predictedEvent = parseAbiItem(
  'event Predicted(uint64 indexed epochId, uint8 indexed marketType, address indexed user, bytes32 candidateId, uint256 amount)',
)

export async function GET() {
  try {
    const block = await client.getBlockNumber()
    // ~2s blocks on Base, look back ~24 hours (~43200 blocks)
    const fromBlock = block - BigInt(43200)

    const logs = await client.getLogs({
      address: V2,
      event: predictedEvent,
      fromBlock: fromBlock > BigInt(0) ? fromBlock : BigInt(0),
      toBlock: 'latest',
    })

    const activity = logs
      .slice(-20) // last 20 events
      .reverse()
      .map((log) => ({
        user: log.args.user ? `${log.args.user.slice(0, 6)}...${log.args.user.slice(-4)}` : '?',
        amount: log.args.amount ? formatUnits(log.args.amount, 6) : '0',
        marketType: log.args.marketType === 0 ? 'App' : 'Chain',
        blockNumber: log.blockNumber?.toString() ?? '',
        txHash: log.transactionHash ?? '',
      }))

    return NextResponse.json({ activity, count: activity.length })
  } catch {
    return NextResponse.json({ activity: [], count: 0 })
  }
}
