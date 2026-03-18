// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC8183} from "./interfaces/IERC8183.sol";
import {IACPHook} from "./interfaces/IACPHook.sol";

/// @title AgenticCommerce — ERC-8183 Reference Implementation
/// @notice Job escrow with evaluator attestation for agent commerce.
/// @dev    Single ERC-20 payment token per contract. Optional hooks for extensibility.
///         Follows Check-Effects-Interactions pattern. ReentrancyGuard on all token-moving functions.
///         claimRefund is deliberately NOT hookable per spec.
contract AgenticCommerce is IERC8183, IERC165, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Maximum combined fee (platform + evaluator): 50% (5000 basis points).
    uint256 public constant MAX_FEE_BP = 5000;

    /// @notice Basis-point denominator (10000 = 100%).
    uint256 public constant BP_DENOMINATOR = 10_000;

    /// @notice Gas limit for hook calls to bound execution cost.
    uint256 public constant HOOK_GAS_LIMIT = 500_000;

    /// @notice Minimum duration between creation and expiry.
    uint256 public constant MIN_EXPIRY_DURATION = 5 minutes;

    /// @notice The ERC-20 token used for all escrow payments.
    IERC20 public immutable PAYMENT_TOKEN;

    /// @notice Platform fee in basis points (e.g. 250 = 2.5%).
    uint256 public platformFeeBp;

    /// @notice Evaluator fee in basis points (e.g. 100 = 1%).
    uint256 public evaluatorFeeBp;

    /// @notice Address that receives platform fees on job completion.
    address public treasury;

    /// @notice Monotonically increasing job counter. First job ID is 1.
    uint256 public jobCounter;

    /// @notice Hook addresses that are approved for use. address(0) is always allowed.
    mapping(address => bool) public whitelistedHooks;

    /// @dev Internal storage struct — matches IERC8183.Job fields plus fee snapshots.
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
        uint256 fundedFeeBp;
        uint256 fundedEvalFeeBp;
    }

    /// @dev jobId => JobStorage
    mapping(uint256 => JobStorage) internal _jobs;

    error ZeroAddress();
    error InvalidExpiry();
    error InvalidStatus(Status current);
    error Unauthorized();
    error ProviderAlreadySet();
    error ProviderNotSet();
    error BudgetMismatch(uint256 actual, uint256 expected);
    error ZeroBudget();
    error JobNotExpired();
    error FeeTooHigh();
    error JobDoesNotExist();
    error HookCallFailed();
    error HookNotWhitelisted();
    error HookInterfaceNotSupported();

    event PlatformFeeUpdated(uint256 oldFeeBp, uint256 newFeeBp);
    event EvaluatorFeeUpdated(uint256 oldFeeBp, uint256 newFeeBp);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /// @param paymentToken_ ERC-20 token used for escrow (immutable).
    /// @param platformFeeBp_ Initial platform fee in basis points.
    /// @param evaluatorFeeBp_ Initial evaluator fee in basis points.
    /// @param treasury_ Address to receive platform fees.
    /// @param owner_ Initial contract owner (admin).
    constructor(
        address paymentToken_,
        uint256 platformFeeBp_,
        uint256 evaluatorFeeBp_,
        address treasury_,
        address owner_
    ) Ownable(owner_) {
        if (paymentToken_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBp_ + evaluatorFeeBp_ > MAX_FEE_BP) revert FeeTooHigh();

        PAYMENT_TOKEN = IERC20(paymentToken_);
        platformFeeBp = platformFeeBp_;
        evaluatorFeeBp = evaluatorFeeBp_;
        treasury = treasury_;
    }

    modifier jobExists(
        uint256 jobId
    ) {
        _checkJobExists(jobId);
        _;
    }

    function _checkJobExists(
        uint256 jobId
    ) internal view {
        if (jobId == 0 || jobId > jobCounter) revert JobDoesNotExist();
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IERC8183).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IERC8183
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external override returns (uint256 jobId) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + MIN_EXPIRY_DURATION) revert InvalidExpiry();
        if (hook != address(0)) {
            if (!whitelistedHooks[hook]) revert HookNotWhitelisted();
            if (!ERC165Checker.supportsInterface(hook, type(IACPHook).interfaceId)) {
                revert HookInterfaceNotSupported();
            }
        }

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
            deliverable: bytes32(0),
            fundedFeeBp: 0,
            fundedEvalFeeBp: 0
        });

        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt);
    }

    /// @inheritdoc IERC8183
    function setProvider(
        uint256 jobId,
        address provider,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (msg.sender != job.client) revert Unauthorized();
        if (job.status != Status.Open) revert InvalidStatus(job.status);
        if (job.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert ZeroAddress();

        bytes memory hookData = abi.encode(provider, optParams);
        _callBeforeHook(jobId, job.hook, msg.sig, hookData);

        job.provider = provider;

        emit ProviderSet(jobId, provider);

        _callAfterHook(jobId, job.hook, msg.sig, hookData);
    }

    /// @inheritdoc IERC8183
    function setBudget(
        uint256 jobId,
        uint256 amount,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (job.status != Status.Open) revert InvalidStatus(job.status);
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();

        bytes memory hookData = abi.encode(amount, optParams);
        _callBeforeHook(jobId, job.hook, msg.sig, hookData);

        job.budget = amount;

        emit BudgetSet(jobId, amount);

        _callAfterHook(jobId, job.hook, msg.sig, hookData);
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

        bytes memory hookData = optParams;
        _callBeforeHook(jobId, job.hook, msg.sig, hookData);

        job.status = Status.Funded;
        job.fundedFeeBp = platformFeeBp;
        job.fundedEvalFeeBp = evaluatorFeeBp;

        PAYMENT_TOKEN.safeTransferFrom(msg.sender, address(this), job.budget);

        emit JobFunded(jobId, msg.sender, job.budget);

        _callAfterHook(jobId, job.hook, msg.sig, hookData);
    }

    /// @inheritdoc IERC8183
    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (msg.sender != job.provider) revert Unauthorized();
        if (job.status != Status.Funded) revert InvalidStatus(job.status);

        bytes memory hookData = abi.encode(deliverable, optParams);
        _callBeforeHook(jobId, job.hook, msg.sig, hookData);

        job.status = Status.Submitted;
        job.deliverable = deliverable;

        emit JobSubmitted(jobId, msg.sender, deliverable);

        _callAfterHook(jobId, job.hook, msg.sig, hookData);
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

        bytes memory hookData = abi.encode(reason, optParams);
        _callBeforeHook(jobId, job.hook, msg.sig, hookData);

        job.status = Status.Completed;

        uint256 budget = job.budget;
        uint256 platformFee = (budget * job.fundedFeeBp) / BP_DENOMINATOR;
        uint256 evalFee = (budget * job.fundedEvalFeeBp) / BP_DENOMINATOR;
        uint256 providerAmount = budget - platformFee - evalFee;

        if (platformFee > 0) {
            PAYMENT_TOKEN.safeTransfer(treasury, platformFee);
        }
        if (evalFee > 0) {
            PAYMENT_TOKEN.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        if (providerAmount > 0) {
            PAYMENT_TOKEN.safeTransfer(job.provider, providerAmount);
        }

        emit JobCompleted(jobId, msg.sender, reason);
        if (providerAmount > 0) {
            emit PaymentReleased(jobId, job.provider, providerAmount);
        }

        _callAfterHook(jobId, job.hook, msg.sig, hookData);
    }

    /// @inheritdoc IERC8183
    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];

        if (job.status == Status.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (job.status == Status.Funded || job.status == Status.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert InvalidStatus(job.status);
        }

        bytes memory hookData = abi.encode(reason, optParams);
        _callBeforeHook(jobId, job.hook, msg.sig, hookData);

        Status prevStatus = job.status;
        job.status = Status.Rejected;

        if (prevStatus == Status.Funded || prevStatus == Status.Submitted) {
            PAYMENT_TOKEN.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }

        emit JobRejected(jobId, msg.sender, reason);

        _callAfterHook(jobId, job.hook, msg.sig, hookData);
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

        job.status = Status.Expired;

        PAYMENT_TOKEN.safeTransfer(job.client, job.budget);

        emit JobExpired(jobId);
        emit Refunded(jobId, job.client, job.budget);
    }

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

    /// @notice Update the platform fee. Owner only.
    /// @param newFeeBp New fee in basis points. Combined with evaluatorFeeBp must be ≤ MAX_FEE_BP.
    function setPlatformFee(
        uint256 newFeeBp
    ) external onlyOwner {
        if (newFeeBp + evaluatorFeeBp > MAX_FEE_BP) revert FeeTooHigh();
        uint256 oldFeeBp = platformFeeBp;
        platformFeeBp = newFeeBp;
        emit PlatformFeeUpdated(oldFeeBp, newFeeBp);
    }

    /// @notice Update the evaluator fee. Owner only.
    /// @param newFeeBp New fee in basis points. Combined with platformFeeBp must be ≤ MAX_FEE_BP.
    function setEvaluatorFee(
        uint256 newFeeBp
    ) external onlyOwner {
        if (platformFeeBp + newFeeBp > MAX_FEE_BP) revert FeeTooHigh();
        uint256 oldFeeBp = evaluatorFeeBp;
        evaluatorFeeBp = newFeeBp;
        emit EvaluatorFeeUpdated(oldFeeBp, newFeeBp);
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

    /// @notice Whitelist or remove a hook contract. Owner only.
    /// @param hook   Hook contract address (must not be zero).
    /// @param status True to whitelist, false to remove.
    function setHookWhitelist(
        address hook,
        bool status
    ) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        whitelistedHooks[hook] = status;
        emit HookWhitelistUpdated(hook, status);
    }

    function _callBeforeHook(
        uint256 jobId,
        address hook,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook == address(0)) return;
        (bool success,) = hook.call{gas: HOOK_GAS_LIMIT}(abi.encodeCall(IACPHook.beforeAction, (jobId, selector, data)));
        if (!success) revert HookCallFailed();
    }

    function _callAfterHook(
        uint256 jobId,
        address hook,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook == address(0)) return;
        (bool success,) = hook.call{gas: HOOK_GAS_LIMIT}(abi.encodeCall(IACPHook.afterAction, (jobId, selector, data)));
        if (!success) revert HookCallFailed();
    }
}
