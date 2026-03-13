// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8183} from "./interfaces/IERC8183.sol";
import {IACPHook} from "./interfaces/IACPHook.sol";

/// @title AgenticCommerce — ERC-8183 Reference Implementation
/// @notice Job escrow with evaluator attestation for agent commerce.
/// @dev    Single ERC-20 payment token per contract. Optional hooks for extensibility.
///         Follows Check-Effects-Interactions pattern. ReentrancyGuard on all token-moving functions.
///         claimRefund is deliberately NOT hookable per spec.
contract AgenticCommerce is IERC8183, IERC165, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Maximum platform fee: 50% (5000 basis points).
    uint256 public constant MAX_FEE_BP = 5000;

    /// @notice Basis-point denominator (10000 = 100%).
    uint256 public constant BP_DENOMINATOR = 10_000;

    /// @notice Gas limit for hook calls to bound execution cost.
    uint256 public constant HOOK_GAS_LIMIT = 500_000;

    // ─────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The ERC-20 token used for all escrow payments.
    IERC20 public immutable PAYMENT_TOKEN;

    // ─────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Platform fee in basis points (e.g. 250 = 2.5%).
    uint256 public platformFeeBP;

    /// @notice Address that receives platform fees on job completion.
    address public treasury;

    /// @notice Monotonically increasing job counter. First job ID is 1.
    uint256 public jobCounter;

    /// @dev Internal storage struct — matches IERC8183.Job fields.
    struct JobStorage {
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

    /// @dev jobId => JobStorage
    mapping(uint256 => JobStorage) internal _jobs;

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Address must not be zero.
    error ZeroAddress();

    /// @dev expiredAt must be strictly in the future.
    error InvalidExpiry();

    /// @dev Current status does not allow this action.
    error InvalidStatus(Status current);

    /// @dev Caller is not authorized for this action.
    error Unauthorized();

    /// @dev Provider has already been assigned to this job.
    error ProviderAlreadySet();

    /// @dev Provider must be set before funding.
    error ProviderNotSet();

    /// @dev expectedBudget does not match job.budget (front-running protection).
    error BudgetMismatch(uint256 actual, uint256 expected);

    /// @dev Budget must be greater than zero to fund.
    error ZeroBudget();

    /// @dev Job has not yet expired.
    error JobNotExpired();

    /// @dev Fee exceeds MAX_FEE_BP.
    error FeeTooHigh();

    /// @dev jobId does not reference a valid job.
    error JobDoesNotExist();

    /// @dev Hook external call failed or ran out of gas.
    error HookCallFailed();

    // ─────────────────────────────────────────────────────────────────────
    // Admin Events
    // ─────────────────────────────────────────────────────────────────────

    event PlatformFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    /// @param paymentToken_ ERC-20 token used for escrow (immutable).
    /// @param platformFeeBP_ Initial platform fee in basis points.
    /// @param treasury_ Address to receive platform fees.
    /// @param owner_ Initial contract owner (admin).
    constructor(
        address paymentToken_,
        uint256 platformFeeBP_,
        address treasury_,
        address owner_
    ) Ownable(owner_) {
        if (paymentToken_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBP_ > MAX_FEE_BP) revert FeeTooHigh();

        PAYMENT_TOKEN = IERC20(paymentToken_);
        platformFeeBP = platformFeeBP_;
        treasury = treasury_;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier jobExists(uint256 jobId) {
        _checkJobExists(jobId);
        _;
    }

    function _checkJobExists(uint256 jobId) internal view {
        if (jobId == 0 || jobId > jobCounter) revert JobDoesNotExist();
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-165
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IERC8183).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core Functions
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC8183
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external override returns (uint256 jobId) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp) revert InvalidExpiry();

        jobId = ++jobCounter;

        _jobs[jobId] = JobStorage({
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            description: description,
            budget: 0,
            expiredAt: expiredAt,
            status: Status.Open,
            hook: hook,
            deliverable: bytes32(0)
        });

        emit JobCreated(jobId, msg.sender, evaluator, provider, expiredAt, description, hook);
    }

    /// @inheritdoc IERC8183
    function setProvider(
        uint256 jobId,
        address provider,
        bytes calldata optParams
    ) external override jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (msg.sender != job.client) revert Unauthorized();
        if (job.status != Status.Open) revert InvalidStatus(job.status);
        if (job.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert ZeroAddress();

        _callBeforeHook(jobId, job.hook, msg.sig, optParams);

        job.provider = provider;

        emit ProviderSet(jobId, provider);

        _callAfterHook(jobId, job.hook, msg.sig, optParams);
    }

    /// @inheritdoc IERC8183
    function setBudget(
        uint256 jobId,
        uint256 amount,
        bytes calldata optParams
    ) external override jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (job.status != Status.Open) revert InvalidStatus(job.status);
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();

        _callBeforeHook(jobId, job.hook, msg.sig, optParams);

        job.budget = amount;

        emit BudgetSet(jobId, amount);

        _callAfterHook(jobId, job.hook, msg.sig, optParams);
    }

    /// @inheritdoc IERC8183
    function fund(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (msg.sender != job.client) revert Unauthorized();
        if (job.status != Status.Open) revert InvalidStatus(job.status);
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.budget == 0) revert ZeroBudget();
        if (job.budget != expectedBudget) revert BudgetMismatch(job.budget, expectedBudget);

        _callBeforeHook(jobId, job.hook, msg.sig, optParams);

        // Effects
        job.status = Status.Funded;

        // Interactions — pull tokens into escrow
        PAYMENT_TOKEN.safeTransferFrom(msg.sender, address(this), job.budget);

        emit JobFunded(jobId, job.budget);

        _callAfterHook(jobId, job.hook, msg.sig, optParams);
    }

    /// @inheritdoc IERC8183
    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external override jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (msg.sender != job.provider) revert Unauthorized();
        if (job.status != Status.Funded) revert InvalidStatus(job.status);

        _callBeforeHook(jobId, job.hook, msg.sig, optParams);

        // Effects
        job.status = Status.Submitted;
        job.deliverable = deliverable;

        emit JobSubmitted(jobId, deliverable);

        _callAfterHook(jobId, job.hook, msg.sig, optParams);
    }

    /// @inheritdoc IERC8183
    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (msg.sender != job.evaluator) revert Unauthorized();
        if (job.status != Status.Submitted) revert InvalidStatus(job.status);

        _callBeforeHook(jobId, job.hook, msg.sig, optParams);

        // Effects
        job.status = Status.Completed;

        // Interactions — distribute escrow: provider gets budget minus platform fee
        uint256 budget = job.budget;
        uint256 fee = (budget * platformFeeBP) / BP_DENOMINATOR;
        uint256 providerAmount = budget - fee;

        if (fee > 0) {
            PAYMENT_TOKEN.safeTransfer(treasury, fee);
        }
        if (providerAmount > 0) {
            PAYMENT_TOKEN.safeTransfer(job.provider, providerAmount);
        }

        emit JobCompleted(jobId, reason);

        _callAfterHook(jobId, job.hook, msg.sig, optParams);
    }

    /// @inheritdoc IERC8183
    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        // Client can reject when Open
        // Evaluator can reject when Funded or Submitted
        if (job.status == Status.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (job.status == Status.Funded || job.status == Status.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert InvalidStatus(job.status);
        }

        _callBeforeHook(jobId, job.hook, msg.sig, optParams);

        // Effects
        Status prevStatus = job.status;
        job.status = Status.Rejected;

        // Interactions — refund client if funds were escrowed
        if (prevStatus == Status.Funded || prevStatus == Status.Submitted) {
            PAYMENT_TOKEN.safeTransfer(job.client, job.budget);
        }

        emit JobRejected(jobId, reason);

        _callAfterHook(jobId, job.hook, msg.sig, optParams);
    }

    /// @inheritdoc IERC8183
    /// @notice Deliberately NOT hookable — funds MUST always be recoverable after expiry.
    function claimRefund(
        uint256 jobId
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (block.timestamp < job.expiredAt) revert JobNotExpired();
        if (job.status != Status.Funded && job.status != Status.Submitted) {
            revert InvalidStatus(job.status);
        }

        // Effects
        job.status = Status.Expired;

        // Interactions — refund client
        PAYMENT_TOKEN.safeTransfer(job.client, job.budget);

        emit JobExpired(jobId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC8183
    function getJob(
        uint256 jobId
    ) external view override jobExists(jobId) returns (Job memory) {
        JobStorage storage s = _jobs[jobId];
        return Job({
            client: s.client,
            provider: s.provider,
            evaluator: s.evaluator,
            description: s.description,
            budget: s.budget,
            expiredAt: s.expiredAt,
            status: s.status,
            hook: s.hook,
            deliverable: s.deliverable
        });
    }

    /// @notice Returns the total number of jobs created.
    function totalJobs() external view returns (uint256) {
        return jobCounter;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the platform fee. Owner only.
    /// @param newFeeBP New fee in basis points (must be ≤ MAX_FEE_BP).
    function setPlatformFee(
        uint256 newFeeBP
    ) external onlyOwner {
        if (newFeeBP > MAX_FEE_BP) revert FeeTooHigh();
        uint256 oldFeeBP = platformFeeBP;
        platformFeeBP = newFeeBP;
        emit PlatformFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @notice Update the treasury address. Owner only.
    /// @param newTreasury New treasury address (must not be zero).
    function setTreasury(
        address newTreasury
    ) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal — Hook Helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Call the beforeAction hook with bounded gas. No-op if hook is address(0).
    function _callBeforeHook(
        uint256 jobId,
        address hook,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        if (hook == address(0)) return;
        (bool success,) = hook.call{gas: HOOK_GAS_LIMIT}(
            abi.encodeCall(IACPHook.beforeAction, (jobId, selector, msg.sender, optParams))
        );
        if (!success) revert HookCallFailed();
    }

    /// @dev Call the afterAction hook with bounded gas. No-op if hook is address(0).
    function _callAfterHook(
        uint256 jobId,
        address hook,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        if (hook == address(0)) return;
        (bool success,) = hook.call{gas: HOOK_GAS_LIMIT}(
            abi.encodeCall(IACPHook.afterAction, (jobId, selector, msg.sender, optParams))
        );
        if (!success) revert HookCallFailed();
    }
}
