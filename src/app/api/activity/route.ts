import { NextRequest, NextResponse } from 'next/server'
import { createPublicClient, http, getAddress, formatUnits } from 'viem'
import { base } from 'viem/chains'

export const dynamic = 'force-dynamic'

const V2 = getAddress('0x768ae7ACBaf472cC066cc229928311daA531cEBe')
const WEEK_ID = BigInt(20260311)

const MARKET_ABI = [{
  name: 'marketDetails',
  type: 'function',
  stateMutability: 'view',
  inputs: [
    { name: 'epochId', type: 'uint64' },
    { name: 'marketType', type: 'uint8' },
  ],
  outputs: [{
    name: '',
    type: 'tuple',
    components: [
      { name: 'openTime', type: 'uint64' },
      { name: 'lockTime', type: 'uint64' },
      { name: 'resolveTime', type: 'uint64' },
      { name: 'feeBps', type: 'uint16' },
      { name: 'state', type: 'uint8' },
      { name: 'metadataHash', type: 'bytes32' },
      { name: 'snapshotHash', type: 'bytes32' },
      { name: 'totalPool', type: 'uint256' },
      { name: 'totalWinningPool', type: 'uint256' },
    ],
  }],
}] as const

const rpcUrl = process.env.PAYMASTER_URL || 'https://mainnet.base.org'
const client = createPublicClient({ chain: base, transport: http(rpcUrl) })

const STATE_LABELS = ['Inactive', 'Open', 'Locked', 'Resolved']

export async function GET(_req: NextRequest) {
  try {
    const [appMarket, chainMarket] = await client.multicall({
      contracts: [
        { address: V2, abi: MARKET_ABI, functionName: 'marketDetails', args: [WEEK_ID, 0] },
        { address: V2, abi: MARKET_ABI, functionName: 'marketDetails', args: [WEEK_ID, 1] },
      ],
      allowFailure: true,
    })

    type Market = { totalPool: bigint; state: number; openTime: bigint; lockTime: bigint; resolveTime: bigint }
    const appData = appMarket.status === 'success' ? appMarket.result as unknown as Market : null
    const chainData = chainMarket.status === 'success' ? chainMarket.result as unknown as Market : null

    const appPool = appData ? formatUnits(appData.totalPool, 6) : '0'
    const chainPool = chainData ? formatUnits(chainData.totalPool, 6) : '0'

    const summary = {
      epoch: WEEK_ID.toString(),
      appMarket: {
        pool: appPool,
        state: appData?.state ?? 0,
        stateLabel: STATE_LABELS[appData?.state ?? 0] ?? 'Unknown',
      },
      chainMarket: {
        pool: chainPool,
        state: chainData?.state ?? 0,
        stateLabel: STATE_LABELS[chainData?.state ?? 0] ?? 'Unknown',
      },
      totalPool: (Number(appPool) + Number(chainPool)).toFixed(2),
    }

    return NextResponse.json(summary)
  } catch {
    return NextResponse.json({ epoch: WEEK_ID.toString(), appMarket: { pool: '0', state: 0, stateLabel: 'Inactive' }, chainMarket: { pool: '0', state: 0, stateLabel: 'Inactive' }, totalPool: '0' })
  }
}
