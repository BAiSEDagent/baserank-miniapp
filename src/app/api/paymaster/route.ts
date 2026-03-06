import { NextRequest, NextResponse } from 'next/server'

const ALLOWED_METHODS = new Set([
  'pm_getPaymasterStubData',
  'pm_getPaymasterData',
  'pm_sponsorUserOperation',
  'eth_sendUserOperation',
])

function isAllowedOrigin(req: NextRequest) {
  const origin = req.headers.get('origin')
  const referer = req.headers.get('referer')
  const hostOrigin = req.nextUrl.origin

  const allowed = new Set([
    hostOrigin,
    'http://localhost:3000',
    'http://127.0.0.1:3000',
    'https://base.dev',
    'https://www.base.dev',
  ])

  if (origin && allowed.has(origin)) return true
  if (referer) {
    try {
      const refOrigin = new URL(referer).origin
      if (allowed.has(refOrigin)) return true
    } catch {
      // ignore malformed referer
    }
  }
  return false
}

function methodsAreAllowed(payload: unknown) {
  const arr = Array.isArray(payload) ? payload : [payload]
  for (const item of arr) {
    const method = (item as { method?: unknown })?.method
    if (typeof method !== 'string' || !ALLOWED_METHODS.has(method)) return false
  }
  return true
}

export function OPTIONS() {
  return new NextResponse(null, { status: 204 })
}

export async function POST(req: NextRequest) {
  const upstream = process.env.PAYMASTER_URL
  if (!upstream) {
    return NextResponse.json({ error: 'PAYMASTER_URL not configured' }, { status: 500 })
  }

  if (!isAllowedOrigin(req)) {
    return NextResponse.json({ error: 'Forbidden origin' }, { status: 403 })
  }

  try {
    const payload = await req.json().catch(() => null)
    if (!payload || !methodsAreAllowed(payload)) {
      return NextResponse.json({ error: 'RPC method not allowed' }, { status: 400 })
    }

    const apiKey = process.env.PAYMASTER_API_KEY

    const res = await fetch(upstream, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(apiKey ? { authorization: `Bearer ${apiKey}` } : {}),
      },
      body: JSON.stringify(payload),
    })

    const text = await res.text()
    return new NextResponse(text, {
      status: res.status,
      headers: { 'content-type': 'application/json' },
    })
  } catch {
    return NextResponse.json({ error: 'Paymaster proxy failed' }, { status: 502 })
  }
}
