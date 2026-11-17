# Morpheus D1 — Donated yield hijacks the cross-pool MOR split

Proof of concept for the Morpheus bug bounty report
`[BOUNTY] DistributorV2 — Donated yield hijacks cross-pool MOR split`.

## Run it (one command)

```bash
forge test
```

Requirements: Foundry 1.9.0. No API keys, no manual setup beyond the
RPC URL (already set in `foundry.toml` to a public archive-capable
endpoint, `https://eth.drpc.org`).

## What it proves

Forks Ethereum mainnet at block 26432489 and runs 14 days of
`DistributorV2.distributeRewards` twice from identical starting state:

- **Attack:** stake 7.4 wBTC in the wBTC pool (90.00% virtual share),
  donate 0.01556 aWBTC/day directly to the Distributor, call
  `distributeRewards(0)` daily, then `claim` after the 14-day lock.
- **Control:** same stakes, same timing, no donations.

Expected result — 4/4 PASS:

| Test | Result |
|---|---|
| `test_attack_D1_donatedYieldHijack` | wBTC pool takes 92.21% of the 41,943-MOR tranche (vs 0 in control); attacker claims 34,811 MOR |
| `test_control_noAttack` | wBTC pool ~0 MOR; tranche distributes normally to stETH/USDC pools |
| `test_forkBlockPinned` / `test_depositPoolImplHasCode` | fork + target verified |

Key assertions: attacker claims ≥ 18,000 MOR; wBTC pool share ≥ 40%
of the tranche; stETH pool share crushed to ≤ 10%; control wBTC delta
~0. Zero-sum verified: every MOR the wBTC pool gained came from the
other pools (wBTC +38,676 vs others −38,675, 1 MOR rounding).

## Honest qualifications (also stated in the report)

- The loss figure in the report is the **mainnet model** (~18,060 MOR
  gross, ~$28,400 net per 14 days), not the fork totals — on-fork
  competing yield is distorted (no Lido rebase; aUSDT accrues ~$0.40/day
  on-fork vs ~$454/day live).
- Source-chain claim + LayerZero outbound message are demonstrated;
  the Arbitrum-side MOR mint is not observable from an L1 fork.
- The reporter personally ran this PoC to a passing result (4/4,
  Foundry 1.9.0, 17 Nov 2026, ~62 s).

## Files

- `test/D1DonatedYield.t.sol` — the attack + control PoC
- `test/HarnessSmoke.t.sol` — fork/target smoke test
- `D1-RESULTS.md` — measured numbers and method notes
- `foundry.toml` — `evm_version = "prague"` (Aave V3 Pool uses Cancun
  opcodes); RPC endpoints (public, no keys)
