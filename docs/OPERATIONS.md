# Operations & Maintenance Guide

Post-deployment administration for the non-upgradeable ERC-8183 kernel.

## Architecture

- **Non-upgradeable.** No proxy, no pause, no `emergencyWithdraw`.
- **Per-job token.** Constructor does not bind a payment token. Owner allowlists tokens.
- **Fee snapshot.** `fund` captures `platformFeeBp`, `evaluatorFeeBp`, and `treasury` into the job. Admin changes never rewrite funded jobs.
- **`renounceOwnership` disabled.** Always reverts `Unauthorized()`.
- **Public getters.** `treasury` (not `platformTreasury`). No `jobs(uint256)`. `getJob` / `getFeeSnapshot` revert `JobDoesNotExist`.

Do not send ETH; there is no withdraw path.

---

## Roles

| Role | Binding | May | Must not |
| ---- | ------- | --- | -------- |
| Client | `createJob` caller | `setProvider` while Open and provider is 0; `fund`; `reject` while Open | Be the provider |
| Provider | creation or `setProvider` | `setBudget`, `setPayoutReceiver` while Open; `submit`; `reject` while Open | Be the client or evaluator; `complete`; job `reject` once Funded |
| Evaluator | immutable at creation | `complete` / `reject` when Submitted; `reject` when Funded | Be the provider |
| Owner | Ownable2Step | fees (capped), treasury, hook whitelist, token allowlist, `batchDetachHook` | Withdraw escrow; pause refunds; mutate snapshots of funded jobs |
| Anyone | — | `claimRefund` under expiry/grace/pending-claim rules | — |

`evaluator == client` is the no-third-party mode and must keep working.

---

## Admin Operations

### Fees and treasury

```bash
cast send $CORE "setPlatformFee(uint256)" 300 --rpc-url $RPC --private-key $KEY
cast send $CORE "setEvaluatorFee(uint256)" 150 --rpc-url $RPC --private-key $KEY
cast send $CORE "setTreasury(address)" $NEW_TREASURY --rpc-url $RPC --private-key $KEY
```

`platformFeeBp + evaluatorFeeBp ≤ 5000`. Changes apply at the next `fund` only. Snapshotted `fundedTreasury` is not rewritten.

**Finding 7 residual:** if the snapshotted treasury later cannot receive tokens, `complete` livelocks. There is no snapshot-repair admin. Evaluator `reject` or `claimRefund` returns escrow to the client.

### Token allowlist

```bash
cast send $CORE "setPaymentTokenAllowed(address,bool)" $TOKEN true \
  --rpc-url $RPC --private-key $KEY
```

Allowlist does **not** prove plain ERC-20. FoT, rebasing, ERC-777/1363 hooks, pausable/blacklist tokens can still break accounting after `fund`. The delta check is only at `fund`. Do not allowlist tokens that rebase after deposit.

Revoking a token between `setBudget` and `fund` causes `PaymentTokenNotAllowed` at `fund`.

### Hook whitelist and detach

```bash
cast send $CORE "setHookWhitelist(address,bool)" $HOOK true --rpc-url $RPC --private-key $KEY
cast send $CORE "batchDetachHook(uint256[])" "[1,2,3]" --rpc-url $RPC --private-key $KEY
```

Dewhitelist does not affect in-flight jobs. `batchDetachHook` sets `job.hook = address(0)` (owner liveness tool; it can strip a two-phase hook's policy mid-job).

### Ownership

Ownable2Step: `transferOwnership` then `acceptOwnership`. Monitor `OwnershipTransferStarted`.

---

## Refund procedures

### Open

After `expiredAt`, anyone `claimRefund`. No tokens move (nothing escrowed). Provider or client may `reject` while Open without waiting.

### Funded (no pending claim)

After `expiredAt`, anyone `claimRefund`. Remainder (`budget - settledAmount`) returns to the client. No grace period.

A pending claim on Funded reverts `PendingClaimExists` even after expiry. Recovery: `rejectClaim` (Layer 1) then `claimRefund`, or evaluator job `reject`. Kernel `submit` / job `reject` already clear a pending claim.

### Submitted

`claimRefund` waits until `expiredAt + EVALUATION_GRACE_PERIOD` (`1 hours`). During grace the evaluator may still `complete`. After grace, `complete` and `claimRefund` race; that is intended.

### IDisburser liveness

If `payoutReceiver` advertises `IDisburser` and `onDisbursement` reverts, `complete` rolls back including fee transfers. Provider-chosen risk. Evaluator `reject` refunds the client. The callback is not gas-capped. Support is probed at payout time (not cached) so an EOA that later has code (EIP-7702) can become a disburser.

---

## Monitoring

| Event | Notes |
| ----- | ----- |
| `JobCreated` / `JobFunded` / `JobSubmitted` / `JobCompleted` / `JobRejected` / `JobExpired` | lifecycle |
| `PaymentReleased` / `PlatformFeePaid` / `EvaluatorFeePaid` | amounts `> 0` only |
| `Disbursed` | IDisburser callback succeeded |
| `Refunded` | client remainder |
| `ClaimRejected` | pending claim superseded (`submit` sentinel `bytes32("superseded-by-submit")` or job `reject` reason) |
| `HookDetached` | incident |
| `PaymentTokenAllowlistUpdated` / `HookWhitelistUpdated` / fee / treasury / ownership | admin |

Escrow conservation (per allowlisted token):

```text
token.balanceOf(erc8183) >= Σ (budget - settledAmount)
  over jobs in {Funded, Submitted} with that paymentToken
```

Page on violation. `getFeeSnapshot(jobId)` returns the frozen bps and treasury.

---

## Incident response

No pause. Recovery is `reject` / `claimRefund` / `batchDetachHook`.

| Case | Action |
| ---- | ------ |
| Malicious hook reverts hookable calls | `batchDetachHook`; `claimRefund` is never hookable |
| Pending claim + reverting claim hook (Layer 1) | detach, then `rejectClaim` / `claimRefund` |
| Reverting IDisburser | evaluator `reject` |
| Broken snapshotted treasury | evaluator `reject` / `claimRefund` |
| Compromised owner | Ownable2Step delays takeover; attacker can change live fees (capped 50%), treasury, allowlists, detach hooks; cannot drain escrow |
| Bad token on allowlist | revoke; already-funded jobs may be insolvent if the token rebases or blacklists the escrow — that is allowlist policy |

### Health check

```bash
echo "Owner: $(cast call $CORE 'owner()(address)' --rpc-url $RPC)"
echo "Treasury: $(cast call $CORE 'treasury()(address)' --rpc-url $RPC)"
echo "Platform Fee: $(cast call $CORE 'platformFeeBp()(uint256)' --rpc-url $RPC) bp"
echo "Evaluator Fee: $(cast call $CORE 'evaluatorFeeBp()(uint256)' --rpc-url $RPC) bp"
echo "Total Jobs: $(cast call $CORE 'jobCounter()(uint256)' --rpc-url $RPC)"
```

---

## Migration

The kernel is non-upgradeable. A bad deploy is not patched in place. Deploy a new `ERC8183` (new address or new salt). Funded jobs on the bad deploy drain via `reject` / `claimRefund`.
