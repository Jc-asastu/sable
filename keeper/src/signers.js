// One key per role, so a leak of one can't do the other's job (audit H-4):
//   relayer: pays gas for agent-signed calls and sponsored openings; holds gas only.
//   filler:  the registered keeper (`isKeeper`); fills and returns orders; holds gas only.
// Each role signs through Turnkey when TURNKEY_ORGANIZATION_ID is set: the key never leaves Turnkey and
// its policy limits what it may sign. Otherwise from <ROLE>_PRIVATE_KEY, then the old shared
// KEEPER_PRIVATE_KEY. Secrets come only from the environment (Railway variables).
import { getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const ROLES = ['relayer', 'filler'];

/** The viem account `role` signs with, or null when it has no key (watch-only). */
export async function signerFor(role, env = process.env) {
  const R = role.toUpperCase();
  if (env.TURNKEY_ORGANIZATION_ID) {
    const address = env[`TURNKEY_${R}_ADDRESS`];
    if (!address) return null;
    const [{ createAccountWithAddress }, { TurnkeyClient }, { ApiKeyStamper }] = await Promise.all([
      import('@turnkey/viem'), import('@turnkey/http'), import('@turnkey/api-key-stamper')]);
    const client = new TurnkeyClient({ baseUrl: env.TURNKEY_BASE_URL || 'https://api.turnkey.com' },
      new ApiKeyStamper({ apiPublicKey: need(env, 'TURNKEY_API_PUBLIC_KEY'), apiPrivateKey: need(env, 'TURNKEY_API_PRIVATE_KEY') }));
    const a = getAddress(address);
    return createAccountWithAddress({ client, organizationId: env.TURNKEY_ORGANIZATION_ID, signWith: a, ethereumAddress: a });
  }
  // MetaMask exports keys without 0x; accept both.
  const raw = (env[`${R}_PRIVATE_KEY`] || env.KEEPER_PRIVATE_KEY)?.trim();
  return raw ? privateKeyToAccount(raw.startsWith('0x') ? raw : `0x${raw}`) : null;
}

function need(env, name) {
  if (!env[name]) throw new Error(`${name} is required with TURNKEY_ORGANIZATION_ID`);
  return env[name];
}
