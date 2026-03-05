import { NextRequest, NextResponse } from 'next/server'

export async function POST(req: NextRequest) {
  const startedAt = Date.now()

  // Parse quickly and acknowledge immediately to keep webhook latency low.
  const payload = await req.json().catch(() => null)

  const response = NextResponse.json({ ok: true, accepted: true }, { status: 200 })

  // Defer heavier work (DB, queue, analytics) off the critical response path.
  queueMicrotask(() => {
    try {
      const token = payload?.notificationDetails?.token ?? payload?.token
      const fid = payload?.fid ?? payload?.user?.fid
      const event = payload?.event ?? payload?.type ?? 'notifications_enabled'

      // TODO: replace with persistent storage (DB or queue worker)
      console.log('[notifications:webhook]', {
        event,
        fid,
        tokenPresent: Boolean(token),
        latencyMs: Date.now() - startedAt,
      })
    } catch {
      // no-op
    }
  })

  return response
}
