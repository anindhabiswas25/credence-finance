"use client";
/**
 * One helper for every write: switch to the stack's chain, approve the token if the allowance is
 * short, simulate (so a revert shows the protocol's reason before the wallet opens), send, wait,
 * then refresh the API reads and record the action in this device's activity log.
 */
import { useQueryClient } from "@tanstack/react-query";
import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  decodeErrorResult,
  erc20Abi,
  maxUint256,
  type Abi,
  type Address,
  type Hash,
  type TransactionReceipt,
} from "viem";
import { useAccount, useConfig } from "wagmi";
import { readContract, simulateContract, switchChain, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { CredenceStockTokenAbi } from "@credence/sdk";
import { logActivity, type Activity } from "./activity";

export type Write = {
  chainId: number;
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args: readonly unknown[];
};

export type TxPlan = {
  approve?: { token: Address; spender: Address; amount: bigint };
  write: Write;
  /** What to record in the activity log once it is mined. */
  activity?: Omit<Activity, "when" | "chainId" | "hash">;
};

/** Error names from Errors.sol (Appendix C of the build guide) in plain words. */
const ERRORS: Record<string, string> = {
  ActionNotAllowedInState: "This action is paused in the asset's current market state. You can still repay or add collateral.",
  LtvAboveLimit: "That would take your LTV above the limit that applies right now. Try a smaller amount.",
  LtvAboveCoverable: "Your LTV is too high to buy Gap Cover. Repay or add collateral first.",
  CoverWindowClosed: "Gap Cover for this closure closed at the Bell deadline.",
  CapacityExceeded: "The Underwriter Pool is full for this closure. Repay or add collateral instead.",
  PremiumAboveMax: "The premium changed. Review the new amount and try again.",
  BorrowPaused: "New borrowing on this market is paused right now. You can still repay or add collateral.",
  BorrowPausedByGuardian: "New borrowing on this market is paused by the guardian. You can still repay or add collateral.",
  NotAllowlisted: "This token can only be held by allowlisted addresses. Get testnet access on the Faucet page first.",
  InsufficientLiquidity: "There isn't enough idle liquidity for that amount right now.",
  BadReveal: "The reveal doesn't match your commitment. Use the salt saved when you committed.",
  BidBelowReserve: "Your price is below the lot's reserve, so it can never fill.",
  BidTooSmall: "That bid is below the minimum notional.",
  RevealAboveMaxNotional: "Quantity × price is above the maximum you committed.",
  TooManyBids: "This lot already has the maximum number of bids.",
  AlreadyBid: "You already have a bid on this lot.",
  NoBid: "You have no committed bid on this lot.",
  PhaseClosed: "That auction phase has closed.",
  EpochNotSettled: "That epoch hasn't settled yet. Claims open after the reopen settles.",
  NothingToClaim: "There is nothing to claim yet.",
  InsufficientShares: "You don't have that many shares.",
  RequestNotProcessed: "This withdrawal is still in the queue. It is paid as borrowers repay.",
  RequestAlreadyClaimed: "This withdrawal was already claimed.",
  ZeroAmount: "Enter an amount above zero.",
  FaucetCooldown: "You already used the faucet for this token today. Try again after the cooldown.",
  FaucetTokenNotConfigured: "The faucet doesn't hand out this token.",
  HealthFactorTooLow: "That would take your health factor too low. Try a smaller amount.",
  CapExceeded: "That would go over the market's cap.",
  ConcentrationExceeded: "That would put too much of the market in one position.",
  PositionInAuction: "This loan is in an auction right now. Wait until it settles.",
  CorporateActionActive: "A corporate action is in progress for this asset, so this action is paused.",
  NotInBellWindow: "That is only possible inside the Bell window.",
  NoDebt: "This loan has no debt.",
  TooEarly: "That phase hasn't started yet.",
  TooLate: "That phase has ended.",
  TokenFrozen: "This token is frozen for your address.",
  TransferNotAllowed: "This token can't be transferred to that address.",
  WithdrawWindowClosed: "Withdrawal requests are closed during the Bell window. Try again after the reopen.",
  RedemptionsGated: "Redemptions are gated right now. Try again later.",
  RequestNotClaimable: "This request can't be claimed yet.",
  LotNotCleared: "The lot hasn't cleared yet.",
  ERC20InsufficientBalance: "Your wallet balance is too low for this amount.",
  ERC20InsufficientAllowance: "The token approval is too low. Try again.",
};

export function humanError(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "You rejected the request in your wallet.";
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    let name = revert?.data?.errorName;
    // A revert from a token (ERC-20 balance, compliance) isn't in the called contract's ABI; the
    // stock token's ABI carries every protocol and ERC-20 error, so decode against it.
    if (!name && revert?.raw) {
      try {
        name = decodeErrorResult({ abi: CredenceStockTokenAbi, data: revert.raw }).errorName;
      } catch {
        /* unknown selector */
      }
    }
    if (name) return ERRORS[name] ?? `The contract refused: ${name}.`;
    if (revert?.reason) return revert.reason;
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

export function useTx() {
  const config = useConfig();
  const qc = useQueryClient();
  const { address, chainId: current } = useAccount();

  async function run(plan: TxPlan, onStatus: (s: string) => void): Promise<{ hash: Hash; receipt: TransactionReceipt }> {
    if (!address) throw new Error("Connect a wallet first.");
    const { chainId } = plan.write;
    if (current !== chainId) {
      onStatus("Switch network in your wallet…");
      await switchChain(config, { chainId });
    }
    if (plan.approve && plan.approve.amount > 0n) {
      const { token, spender, amount } = plan.approve;
      const allowance = await readContract(config, { chainId, address: token, abi: erc20Abi, functionName: "allowance", args: [address, spender] });
      if (allowance < amount) {
        onStatus("Approve the token in your wallet…");
        // Test tokens on testnet: an unlimited approval saves a second prompt on the next action.
        const h = await writeContract(config, { chainId, address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
        onStatus("Waiting for the approval…");
        await waitForTransactionReceipt(config, { chainId, hash: h });
      }
    }
    onStatus("Confirm in your wallet…");
    const sim = await simulateContract(config, { ...plan.write, account: address } as Parameters<typeof simulateContract>[1]);
    const hash = await writeContract(config, sim.request as Parameters<typeof writeContract>[1]);
    onStatus("Waiting for confirmation…");
    const receipt = await waitForTransactionReceipt(config, { chainId, hash });
    if (receipt.status !== "success") throw new Error("The transaction reverted.");
    if (plan.activity) logActivity(address, { ...plan.activity, chainId, hash, when: Date.now() });
    await qc.invalidateQueries();
    return { hash, receipt };
  }

  return { run, address };
}
