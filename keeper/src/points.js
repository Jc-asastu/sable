// Points (DECISIONS D18): a filled order earns filled USD × 10, multiplied by how much money the
// owner kept waiting in open orders over the last 7 days. Pure functions; times are unix seconds.

export const POINTS_PER_USD = 10;
export const WINDOW = 7 * 86_400;
export const MAX_MULTIPLIER = 3;

/** 1 + 0.73·log10(1 + D/1000), capped: $1,000 for 2 days (D = 2,000) gives 1.35x. */
export function multiplier(dollarDays) {
  return Math.min(MAX_MULTIPLIER, 1 + 0.73 * Math.log10(1 + Math.max(0, dollarDays) / 1000));
}

/** USD × days each order was open inside the 7 days before `at` (open orders count up to `at`). */
export function dollarDays(orders, at) {
  const from = at - WINDOW;
  let total = 0;
  for (const o of orders) {
    const start = Math.max(o.openedAt, from);
    const end = Math.min(o.closedAt ?? at, at);
    if (end > start) total += o.usd * (end - start) / 86_400;
  }
  return total;
}

/** Points for a fill of `usd` at `at`, given all the owner's orders (the filled one included). */
export function fillPoints(orders, usd, at) {
  return usd * POINTS_PER_USD * multiplier(dollarDays(orders, at));
}
