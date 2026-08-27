// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IERC8183 — Agentic Commerce Protocol
/// @notice Canonical job-escrow ABI implemented by this ERC-8183 kernel.
interface IERC8183 {
    /// @notice Canonical job lifecycle states.
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    /// @notice Canonical job descriptor returned by `getJob`. Field order is ABI-stable.
    struct Job {
        address client;
        JobStatus status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint256 budget;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        string description;
        uint256 settledAmount;
        address payoutReceiver;
    }

    /// @notice Emitted when a job is created in Open state.
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint48 expiredAt,
        address hook
    );

    /// @notice Emitted when a provider is assigned to an Open job.
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);

    /// @notice Emitted when the provider-side payout receiver is set.
    event PayoutReceiverSet(uint256 indexed jobId, address indexed payoutReceiver);

    /// @notice Emitted when the provider sets or updates the job budget and token.
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);

    /// @notice Emitted when the client funds the escrow (Open → Funded).
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);

    /// @notice Emitted when the provider submits work.
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);

    /// @notice Emitted when the evaluator completes a Submitted job.
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);

    /// @notice Emitted when a job is rejected.
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);

    /// @notice Emitted when a job expires.
    event JobExpired(uint256 indexed jobId);

    /// @notice Emitted when provider-side net payment is released (`amount > 0` only).
    event PaymentReleased(uint256 indexed jobId, address indexed recipient, uint256 amount);

    /// @notice Emitted when the snapshotted platform fee is paid (`amount > 0` only).
    event PlatformFeePaid(uint256 indexed jobId, address indexed platformTreasury, uint256 amount);

    /// @notice Emitted when the snapshotted evaluator fee is paid (`amount > 0` only).
    event EvaluatorFeePaid(uint256 indexed jobId, address indexed evaluator, uint256 amount);

    /// @notice Emitted after a successful `IDisburser.onDisbursement` callback.
    event Disbursed(uint256 indexed jobId, address indexed receiver, bytes4 selector, uint256 amount);

    /// @notice Emitted when escrow remainder is returned to the client.
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    /// @notice Emitted when `settledAmount` increases via `settleClaim` or `approveClaim`.
    event Settled(uint256 indexed jobId, uint256 cumulativeAmount, uint256 delta);

    /// @notice Emitted when the provider files a pending claim. `optParams` is the preimage.
    event ClaimSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable,
        bytes optParams
    );

    /// @notice Emitted after a client `settleClaim`. `deliverable` is the client's attestation.
    event ClaimSettled(
        uint256 indexed jobId, address indexed settler, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );

    /// @notice Emitted after a pending claim is approved.
    event ClaimApproved(
        uint256 indexed jobId, address indexed approver, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );

    /// @notice Emitted when a pending claim is rejected, withdrawn, or superseded.
    event ClaimRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);

    /// @notice Create a job in Open state. `msg.sender` becomes the client.
    /// @param provider Service provider, or `address(0)` to assign later via `setProvider`.
    /// @param evaluator Attestor. MAY equal the client. MUST NOT equal the provider.
    /// @param expiredAt Unix timestamp after which `claimRefund` may become available.
    /// @param description Job brief stored on-chain.
    /// @param hook Optional `IERC8183Hook` (zero for none). Must be whitelisted and ERC-165 valid.
    /// @param providerAgentId Optional ERC-8004 id; stored only when `provider != 0`.
    /// @return jobId Newly assigned job id (starts at 1).
    function createJob(
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) external returns (uint256 jobId);

    /// @notice Provider sets the payout receiver while the job is Open.
    function setPayoutReceiver(
        uint256 jobId,
        address payoutReceiver
    ) external;

    /// @notice Client assigns a provider to an Open job that has none.
    function setProvider(
        uint256 jobId,
        address provider,
        uint256 agentId
    ) external;

    /// @notice Provider sets payment token and budget while the job is Open.
    function setBudget(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) external;

    /// @notice Client funds escrow. `expectedToken` / `expectedBudget` must match stored values.
    function fund(
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external;

    /// @notice Provider submits work. Allowed from Funded, or Open with zero budget.
    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external;

    /// @notice Evaluator completes a Submitted job and pays the remainder via the fee snapshot.
    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external;

    /// @notice Reject a job. Open: client or provider. Funded/Submitted: evaluator.
    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external;

    /// @notice Permissionless refund after expiry. Not hookable.
    function claimRefund(
        uint256 jobId
    ) external;

    /// @notice Provider files a pending claim against a Funded job. No token movement.
    function submitClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external;

    /// @notice Client unilaterally settles a cumulative amount. Does not consume a pending claim.
    function settleClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external;

    /// @notice Client or evaluator approves the pending claim. No expiry check.
    function approveClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external;

    /// @notice Client, evaluator, or provider rejects or withdraws the pending claim. No expiry check.
    function rejectClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes calldata optParams
    ) external;

    /// @notice Canonical job view. Reverts `JobDoesNotExist` for unknown ids.
    function getJob(
        uint256 jobId
    ) external view returns (Job memory);
}
