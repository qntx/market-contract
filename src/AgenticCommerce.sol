// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC8183} from "./interfaces/IERC8183.sol";
import {IACPHook} from "./interfaces/IACPHook.sol";

/// @title AgenticCommerce — ERC-8183 Reference Implementation
/// @notice Job escrow with evaluator attestation for agent commerce.
/// @dev    Single ERC-20 payment token per contract. Optional hooks for extensibility.
///         claimRefund is deliberately NOT hookable per spec.
contract AgenticCommerce is IERC8183, IERC165, ReentrancyGuardTransient, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FEE_BP = 5000;
    uint256 public constant BP_DENOMINATOR = 10_000;
    uint256 public constant HOOK_GAS_LIMIT = 500_000;
    uint256 public constant MIN_EXPIRY_DURATION = 5 minutes;

    IERC20 public immutable PAYMENT_TOKEN;

    uint256 public platformFeeBp;
    uint256 public evaluatorFeeBp;
    address public treasury;
    uint256 public jobCounter;

    mapping(address => bool) public whitelistedHooks;

    /// @dev Storage-optimised job struct. Packed fields in slot 3 save ~3 slots per job.
    ///      Layout: [client|provider|evaluator] = 3 slots, [hook+status+expiredAt+fees] = 1 slot,
    ///      [budget] = 1 slot, [deliverable] = 1 slot, [description ptr] = 1 slot → 7 total.
    struct JobStorage {
        address client;
        address provider;
        address evaluator;
        address hook;
        Status status;
        uint48 expiredAt;
        uint16 fundedFeeBp;
        uint16 fundedEvalFeeBp;
        uint256 budget;
        bytes32 deliverable;
        string description;
    }

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
    error HookNotWhitelisted();
    error HookInterfaceNotSupported();

    event PlatformFeeUpdated(uint256 oldFeeBp, uint256 newFeeBp);
    event EvaluatorFeeUpdated(uint256 oldFeeBp, uint256 newFeeBp);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

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

        JobStorage storage s = _jobs[jobId];
        s.client = msg.sender;
        s.provider = provider;
        s.evaluator = evaluator;
        s.hook = hook;
        s.expiredAt = _safeCastToU48(expiredAt);
        s.description = description;

        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, hook);
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
        _hookBefore(job.hook, jobId, msg.sig, hookData);

        job.provider = provider;
        emit ProviderSet(jobId, provider);

        _hookAfter(job.hook, jobId, msg.sig, hookData);
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
        _hookBefore(job.hook, jobId, msg.sig, hookData);

        job.budget = amount;
        emit BudgetSet(jobId, amount);

        _hookAfter(job.hook, jobId, msg.sig, hookData);
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
        if (block.timestamp >= job.expiredAt) revert JobNotExpired();

        _hookBefore(job.hook, jobId, msg.sig, optParams);

        job.status = Status.Funded;
        // forge-lint: disable-next-line(unsafe-typecast)
        job.fundedFeeBp = uint16(platformFeeBp);
        // forge-lint: disable-next-line(unsafe-typecast)
        job.fundedEvalFeeBp = uint16(evaluatorFeeBp);

        PAYMENT_TOKEN.safeTransferFrom(msg.sender, address(this), job.budget);
        emit JobFunded(jobId, msg.sender, job.budget);

        _hookAfter(job.hook, jobId, msg.sig, optParams);
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
        _hookBefore(job.hook, jobId, msg.sig, hookData);

        job.status = Status.Submitted;
        job.deliverable = deliverable;
        emit JobSubmitted(jobId, msg.sender, deliverable);

        _hookAfter(job.hook, jobId, msg.sig, hookData);
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
        _hookBefore(job.hook, jobId, msg.sig, hookData);

        job.status = Status.Completed;

        uint256 budget = job.budget;
        uint256 pFee = (budget * job.fundedFeeBp) / BP_DENOMINATOR;
        uint256 eFee = (budget * job.fundedEvalFeeBp) / BP_DENOMINATOR;
        uint256 net = budget - pFee - eFee;

        if (pFee > 0) PAYMENT_TOKEN.safeTransfer(treasury, pFee);
        if (eFee > 0) {
            PAYMENT_TOKEN.safeTransfer(job.evaluator, eFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, eFee);
        }
        if (net > 0) PAYMENT_TOKEN.safeTransfer(job.provider, net);

        emit JobCompleted(jobId, msg.sender, reason);
        if (net > 0) emit PaymentReleased(jobId, job.provider, net);

        _hookAfter(job.hook, jobId, msg.sig, hookData);
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
        _hookBefore(job.hook, jobId, msg.sig, hookData);

        Status prev = job.status;
        job.status = Status.Rejected;

        if ((prev == Status.Funded || prev == Status.Submitted) && job.budget > 0) {
            PAYMENT_TOKEN.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }

        emit JobRejected(jobId, msg.sender, reason);

        _hookAfter(job.hook, jobId, msg.sig, hookData);
    }

    /// @inheritdoc IERC8183
    function claimRefund(
        uint256 jobId
    ) external override nonReentrant jobExists(jobId) {
        JobStorage storage job = _jobs[jobId];
        if (block.timestamp < job.expiredAt) revert JobNotExpired();
        if (job.status != Status.Funded && job.status != Status.Submitted) {
            revert InvalidStatus(job.status);
        }

        job.status = Status.Expired;

        if (job.budget > 0) {
            PAYMENT_TOKEN.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }

        emit JobExpired(jobId);
    }

    /// @inheritdoc IERC8183
    function getJob(
        uint256 jobId
    ) external view override jobExists(jobId) returns (Job memory) {
        JobStorage storage s = _jobs[jobId];
        return Job({
            id: jobId,
            client: s.client,
            provider: s.provider,
            evaluator: s.evaluator,
            description: s.description,
            budget: s.budget,
            expiredAt: uint256(s.expiredAt),
            status: s.status,
            hook: s.hook,
            deliverable: s.deliverable
        });
    }

    function totalJobs() external view returns (uint256) {
        return jobCounter;
    }

    function setPlatformFee(
        uint256 newFeeBp
    ) external onlyOwner {
        if (newFeeBp + evaluatorFeeBp > MAX_FEE_BP) revert FeeTooHigh();
        emit PlatformFeeUpdated(platformFeeBp, newFeeBp);
        platformFeeBp = newFeeBp;
    }

    function setEvaluatorFee(
        uint256 newFeeBp
    ) external onlyOwner {
        if (platformFeeBp + newFeeBp > MAX_FEE_BP) revert FeeTooHigh();
        emit EvaluatorFeeUpdated(evaluatorFeeBp, newFeeBp);
        evaluatorFeeBp = newFeeBp;
    }

    function setTreasury(
        address newTreasury
    ) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setHookWhitelist(
        address hook,
        bool status
    ) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        whitelistedHooks[hook] = status;
        emit HookWhitelistUpdated(hook, status);
    }

    function _hookBefore(
        address hook,
        uint256 jobId,
        bytes4 sel,
        bytes memory data
    ) internal {
        if (hook == address(0)) return;
        IACPHook(hook).beforeAction{gas: HOOK_GAS_LIMIT}(jobId, sel, data);
    }

    function _hookAfter(
        address hook,
        uint256 jobId,
        bytes4 sel,
        bytes memory data
    ) internal {
        if (hook == address(0)) return;
        IACPHook(hook).afterAction{gas: HOOK_GAS_LIMIT}(jobId, sel, data);
    }

    function _safeCastToU48(
        uint256 value
    ) internal pure returns (uint48) {
        if (value > type(uint48).max) revert InvalidExpiry();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(value);
    }
}
