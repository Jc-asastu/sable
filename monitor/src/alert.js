export async function sendAlert({ level, text }, { webhook, log, fetchImpl = fetch }) {
  log(`${level.toUpperCase()} ${text}`);
  if (!webhook) return;
  try {
    const response = await fetchImpl(webhook, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text: `[sable ${level}] ${text}` }),
    });
    if (!response.ok) log(`alert webhook failed: HTTP ${response.status}`);
  } catch (e) {
    log(`alert webhook failed: ${e.message}`);
  }
}
