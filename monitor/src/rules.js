// What the monitor does about what it sees. Pure functions: events in, alerts and guardian actions out.
// The keeper is watched by something it doesn't control (audit section 3, item 4).

/** Registry events worth a human's eyes every time they happen. */
const REGISTRY_EVENTS = new Set([
  'OwnershipTransferStarted', 'OwnershipTransferred', 'KeeperSet', 'VaultSet', 'AcrossSpokePoolSet',
  'GuardianSet', 'Listed', 'Delisted', 'FeeSet', 'Paused', 'OrderBoundsSet',
]);

export const LIMITS = {
  /** A local fill this far below a fresh quote is suspicious (the keeper may be keeping the surplus). */
  shortfallBps: 200,
  /** This many suspicious fills from one keeper within the window revoke it. */
  strikes: 3,
  windowSec: 3_600,
  /** More fills than this in one minute pauses cross-chain fills until a human looks. */
  fillsPerMinute: 30,
};

/** A registry change: always an alert. Grants (a new keeper, a new vault) are the dangerous ones. */
export function onRegistryEvent(e) {
  if (!REGISTRY_EVENTS.has(e.eventName)) return [];
  const grant = (e.eventName === 'KeeperSet' || e.eventName === 'VaultSet') && e.args.allowed;
  const risky = grant || ['OwnershipTransferStarted', 'OwnershipTransferred', 'AcrossSpokePoolSet', 'GuardianSet'].includes(e.eventName);
  return [{ kind: 'alert', level: risky ? 'critical' : 'info', text: `registry ${e.eventName} ${JSON.stringify(e.args, (_, v) => (typeof v === 'bigint' ? String(v) : v))} (tx ${e.transactionHash})` }];
}

/**
 * A local fill, judged against a fresh quote for the same swap. `strikes` is the monitor's memory:
 * keeper → timestamps of its suspicious fills. Returns the actions to take; it mutates `strikes`.
 */
export function onLocalFill({ keeper, amountOut, quoteOut, at, tx }, strikes, limits = LIMITS) {
  if (!(quoteOut > 0n) || amountOut * 10_000n >= quoteOut * BigInt(10_000 - limits.shortfallBps)) return [];
  const recent = (strikes.get(keeper) ?? []).filter((t) => at - t < limits.windowSec);
  recent.push(at);
  strikes.set(keeper, recent);
  const short = Number((quoteOut - amountOut) * 10_000n / quoteOut) / 100;
  const actions = [{ kind: 'alert', level: 'warning', text: `fill ${tx} by ${keeper} delivered ${short}% below a fresh quote (${recent.length}/${limits.strikes})` }];
  if (recent.length >= limits.strikes) {
    actions.push({ kind: 'revokeKeeper', keeper });
    actions.push({ kind: 'alert', level: 'critical', text: `revoked keeper ${keeper}: ${recent.length} fills well below the market within an hour` });
  }
  return actions;
}

/** Too many fills in a minute: someone may be draining orders. Pause cross-chain fills and call a human. */
export function onFillRate(fillsLastMinute, alreadyPaused, limits = LIMITS) {
  if (fillsLastMinute <= limits.fillsPerMinute || alreadyPaused) return [];
  return [
    { kind: 'pauseCross' },
    { kind: 'alert', level: 'critical', text: `${fillsLastMinute} fills in the last minute (limit ${limits.fillsPerMinute}): cross-chain fills paused` },
  ];
}

/** A role wallet running out of gas stops the product: warn early. */
export function onBalance({ role, address, balance, floor, symbol }) {
  return balance >= floor ? [] : [{ kind: 'alert', level: 'warning', text: `${role} ${address} has ${balance} wei ${symbol}, under ${floor}: top it up` }];
}
