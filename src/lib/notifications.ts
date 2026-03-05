export type NotificationEnableResult = {
  ok: boolean
  reason?: string
}

export async function requestBaseNotificationPermission(): Promise<NotificationEnableResult> {
  if (typeof window === 'undefined') return { ok: false, reason: 'non-browser' }

  try {
    const client = (window as unknown as { base?: { notifications?: { requestPermission?: () => Promise<unknown> } } }).base
    if (!client?.notifications?.requestPermission) {
      return { ok: false, reason: 'unsupported-client' }
    }

    await client.notifications.requestPermission()
    return { ok: true }
  } catch {
    return { ok: false, reason: 'permission-denied-or-failed' }
  }
}
