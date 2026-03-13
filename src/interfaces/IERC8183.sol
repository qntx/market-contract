// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IERC8183 — Agentic Commerce Protocol
/// @notice Canonical interface for job escrow with evaluator attestation for agent commerce.
/// @dev Implementations MUST emit the declared events on every corresponding state transition.
///      See https://eips.ethereum.org/EIPS/eip-8183
interface IERC8183 {
    /// @notice Canonical job lifecycle states.
    ///         Open → Funded → Submitted → Terminal (Completed | Rejected | Expired)
    enum Status {
        Open, //      0 – Created; budget not yet set or not yet funded.
        Funded, //    1 – Budget escrowed. Provider may submit; evaluator may reject.
        Submitted, // 2 – Provider submitted work. Evaluator may complete or reject.
        Completed, // 3 – Terminal. Escrow released to provider (minus platform fee).
        Rejected, //  4 – Terminal. Escrow refunded to client.
        Expired //    5 – Terminal. Escrow refunded to client (after expiredAt).
    }

    /// @notice Minimal job descriptor returned by getJob().
    struct Job {
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        Status status;
        address hook;
        bytes32 deliverable;
    }

    /// @notice Emitted when a new job is created in Open state.
    event JobCreated(
        uint256 indexed jobId, address indexed client, address provider, address evaluator, uint256 expiredAt
    );

    /// @notice Emitted when a provider is assigned to a job.
    event ProviderSet(uint256 indexed jobId, address indexed provider);

    /// @notice Emitted when a job budget is set or updated.
    event BudgetSet(uint256 indexed jobId, uint256 amount);

    /// @notice Emitted when client funds the escrow (Open → Funded).
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);

    /// @notice Emitted when provider submits work (Funded → Submitted).
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);

    /// @notice Emitted when evaluator marks job completed (Submitted → Completed).
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);

    /// @notice Emitted when job is rejected by client (Open) or evaluator (Funded/Submitted).
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);

    /// @notice Emitted when job expires and funds are refunded.
    event JobExpired(uint256 indexed jobId);

    /// @notice Emitted when escrowed payment is released to the provider.
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);

    /// @notice Emitted when escrowed funds are refunded to the client.
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    /// @notice Create a job in Open state.
    /// @dev    Provider MAY be address(0); client MUST call setProvider before fund.
    ///         Evaluator MUST NOT be address(0). expiredAt MUST be in the future.
    /// @param provider   Address of the service provider (or zero for later assignment).
    /// @param evaluator  Address that attests completion/rejection. MAY equal client.
    /// @param expiredAt  Unix timestamp after which anyone may trigger refund.
    /// @param description Job brief or scope reference (stored on-chain).
    /// @param hook       Optional hook contract (address(0) for no hook).
    /// @return jobId     The ID of the created job.
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId);

    /// @notice Set the provider for a job created without one.
    /// @dev    Client only. SHALL revert if not Open, provider already set, or provider is zero.
    /// @param jobId     Job identifier.
    /// @param provider  Provider address to assign.
    /// @param optParams Forwarded to hook contract if set.
    function setProvider(
        uint256 jobId,
        address provider,
        bytes calldata optParams
    ) external;

    /// @notice Set or update the budget for a job.
    /// @dev    Client or provider. SHALL revert if not Open.
    /// @param jobId     Job identifier.
    /// @param amount    Budget amount in payment token units.
    /// @param optParams Forwarded to hook contract if set.
    function setBudget(
        uint256 jobId,
        uint256 amount,
        bytes calldata optParams
    ) external;

    /// @notice Fund the job escrow, transitioning Open → Funded.
    /// @dev    Client only. SHALL revert if provider not set, budget is zero,
    ///         or budget != expectedBudget (front-running protection).
    /// @param jobId          Job identifier.
    /// @param expectedBudget Must match job.budget exactly.
    /// @param optParams      Forwarded to hook contract if set.
    function fund(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external;

    /// @notice Submit work deliverable (Funded → Submitted).
    /// @dev    Provider only. deliverable is a reference (hash, CID, commitment).
    /// @param jobId       Job identifier.
    /// @param deliverable Reference to submitted work.
    /// @param optParams   Forwarded to hook contract if set.
    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external;

    /// @notice Complete the job (Submitted → Completed). Escrow released to provider.
    /// @dev    Evaluator only. reason enables audit and reputation composition.
    /// @param jobId     Job identifier.
    /// @param reason    Attestation reason (e.g. hash of evaluation evidence).
    /// @param optParams Forwarded to hook contract if set.
    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external;

    /// @notice Reject the job. Escrow refunded to client if funds were escrowed.
    /// @dev    Client may reject when Open. Evaluator may reject when Funded or Submitted.
    /// @param jobId     Job identifier.
    /// @param reason    Attestation reason.
    /// @param optParams Forwarded to hook contract if set.
    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external;

    /// @notice Claim refund after expiry. Deliberately NOT hookable.
    /// @dev    Anyone may call when block.timestamp >= job.expiredAt and status is Funded or Submitted.
    /// @param jobId Job identifier.
    function claimRefund(
        uint256 jobId
    ) external;

    /// @notice Get job details.
    /// @param jobId Job identifier.
    /// @return Job struct with all fields.
    function getJob(
        uint256 jobId
    ) external view returns (Job memory);
}
