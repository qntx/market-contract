// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC8183} from "./interfaces/IERC8183.sol";
import {IERC8183Hook} from "./interfaces/IERC8183Hook.sol";
import {IDisburser} from "./interfaces/IDisburser.sol";

/// @title ERC8183 — non-upgradeable Agentic Commerce kernel
/// @notice Per-job ERC-20 escrow with evaluator attestation.
/// @dev Trust model vs the UUPS reference: fee snapshot at `fund`, 50% cap,
///      500k hook gas, no pause, no admin escrow withdrawal.
///
///      A payout receiver that advertises `IDisburser` and reverts in
///      `onDisbursement` rolls back `complete` (including already-performed fee
///      transfers). Evaluator `reject` refunds the client. The callback is not
///      gas-capped.
///
///      Do not send ETH; there is no withdraw path.
contract ERC8183 is IERC8183, IERC165, ReentrancyGuardTransient, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FEE_BP = 5000;
    uint256 public constant BP_DENOMINATOR = 10_000;
    uint256 public constant HOOK_GAS_LIMIT = 500_000;
    uint256 public constant MIN_EXPIRY_DURATION = 5 minutes;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 1024;
    uint256 public constant EVALUATION_GRACE_PERIOD = 1 hours;

    uint256 public platformFeeBp;
    uint256 public evaluatorFeeBp;
    address public treasury;
    uint256 public jobCounter;

    /// @dev Allowlist is policy, not a proof of plain ERC-20. FoT, rebasing,
    ///      ERC-777/1363 hooks, and pausable/blacklist tokens can still break
    ///      accounting after `fund`. The delta check is only at `fund`.
    mapping(address token => bool allowed) public allowedPaymentTokens;
    mapping(address hook => bool allowed) public whitelistedHooks;
    mapping(uint256 jobId => bytes32 hash) public pendingClaimHash;
    mapping(uint256 jobId => mapping(bytes32 claimHash => bool used)) public submittedClaimHash;

    /// @dev Packed storage. 11 words with an empty description (slots 0–10).
    ///
    /// slot 0: client (20) | status (1) | fundedPlatformFeeBp (2) | fundedEvaluatorFeeBp (2)
    /// slot 1: provider (20) | expiredAt (6)
    /// slot 2: evaluator (20) | submittedAt (6)
    /// slot 3: budget (32)
    /// slot 4: hook (20)
    /// slot 5: paymentToken (20)
    /// slot 6: providerAgentId (32)
    /// slot 7: settledAmount (32)
    /// slot 8: payoutReceiver (20)
    /// slot 9: fundedTreasury (20)
    /// slot 10+: description
    struct JobStorage {
        address client;
        JobStatus status;
        uint16 fundedPlatformFeeBp;
        uint16 fundedEvaluatorFeeBp;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint256 budget;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        uint256 settledAmount;
        address payoutReceiver;
        address fundedTreasury;
        string description;
    }

    mapping(uint256 jobId => JobStorage job) internal _jobs;

    error ZeroAddress();
    error InvalidStatus(JobStatus current);
    error Unauthorized();
    error ProviderAlreadySet();
    error ProviderNotSet();
    error BudgetMismatch(uint256 actual, uint256 expected);
    error JobAlreadyExpired();
    error JobNotExpired();
    error FeeTooHigh();
    error JobDoesNotExist();
    error HookNotWhitelisted();
    error InvalidHook();
    error DescriptionTooLong();
    error ExpiryTooShort();
    error InvalidReceiver();
    error PaymentTokenNotAllowed();
    error PaymentTokenMismatch();
    error ProviderCannotBeEvaluator();
    error ClientCannotBeProvider();
    error GracePeriodActive();
    error UnexpectedFundedAmount();
    error PendingClaimExists();

    event HookWhitelistUpdated(address indexed hook, bool status);
    event PaymentTokenAllowlistUpdated(address indexed token, bool status);
    event HookDetached(uint256 indexed jobId, address indexed hook);
    event PlatformFeeUpdated(uint256 oldFeeBp, uint256 newFeeBp);
    event EvaluatorFeeUpdated(uint256 oldFeeBp, uint256 newFeeBp);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    constructor(
        uint256 platformFeeBp_,
        uint256 evaluatorFeeBp_,
        address treasury_,
        address owner_
    ) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (platformFeeBp_ + evaluatorFeeBp_ > MAX_FEE_BP) revert FeeTooHigh();
        platformFeeBp = platformFeeBp_;
        evaluatorFeeBp = evaluatorFeeBp_;
        treasury = treasury_;
    }

    /// @dev Disabled so fee/allowlist/detach admin cannot be burned.
    function renounceOwnership() public pure override {
        revert Unauthorized();
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
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) external nonReentrant returns (uint256 jobId) {
        return _createJob(msg.sender, provider, evaluator, expiredAt, description, hook, providerAgentId);
    }

    function _createJob(
        address client,
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) internal returns (uint256 jobId) {
        if (client == address(0)) revert ZeroAddress();
        if (evaluator == address(0)) revert ZeroAddress();
        if (bytes(description).length > MAX_DESCRIPTION_LENGTH) revert DescriptionTooLong();
        if (expiredAt <= block.timestamp + MIN_EXPIRY_DURATION) revert ExpiryTooShort();
        if (provider != address(0) && provider == client) revert ClientCannotBeProvider();
        if (provider != address(0) && provider == evaluator) revert ProviderCannotBeEvaluator();
        if (hook != address(0) && !whitelistedHooks[hook]) revert HookNotWhitelisted();
        if (hook != address(0) && !ERC165Checker.supportsInterface(hook, type(IERC8183Hook).interfaceId)) {
            revert InvalidHook();
        }

        jobId = ++jobCounter;
        JobStorage storage job = _jobs[jobId];
        job.client = client;
        job.status = JobStatus.Open;
        job.provider = provider;
        job.expiredAt = expiredAt;
        job.evaluator = evaluator;
        job.hook = hook;
        job.providerAgentId = provider != address(0) ? providerAgentId : 0;
        job.description = description;

        emit JobCreated(jobId, client, provider, evaluator, expiredAt, hook);
    }

    /// @inheritdoc IERC8183
    function setProvider(
        uint256 jobId,
        address provider,
        uint256 agentId
    ) external nonReentrant {
        _setProvider(msg.sender, jobId, provider, agentId);
    }

    function _setProvider(
        address actor,
        uint256 jobId,
        address provider,
        uint256 agentId
    ) internal {
        JobStorage storage job = _job(jobId);
        if (actor != job.client) revert Unauthorized();
        if (job.status != JobStatus.Open) revert InvalidStatus(job.status);
        if (block.timestamp >= job.expiredAt) revert JobAlreadyExpired();
        if (job.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert ZeroAddress();
        if (provider == job.client) revert ClientCannotBeProvider();
        if (provider == job.evaluator) revert ProviderCannotBeEvaluator();

        job.provider = provider;
        job.providerAgentId = agentId;
        emit ProviderSet(jobId, provider, agentId);
    }

    /// @inheritdoc IERC8183
    function setPayoutReceiver(
        uint256 jobId,
        address payoutReceiver
    ) external nonReentrant {
        _setPayoutReceiver(msg.sender, jobId, payoutReceiver);
    }

    function _setPayoutReceiver(
        address actor,
        uint256 jobId,
        address payoutReceiver
    ) internal {
        JobStorage storage job = _job(jobId);
        if (actor != job.provider) revert Unauthorized();
        if (job.status != JobStatus.Open) revert InvalidStatus(job.status);
        if (block.timestamp >= job.expiredAt) revert JobAlreadyExpired();
        _validatePayoutReceiver(payoutReceiver, job.paymentToken);

        job.payoutReceiver = payoutReceiver;
        emit PayoutReceiverSet(jobId, payoutReceiver);
    }

    /// @inheritdoc IERC8183
    function setBudget(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) external nonReentrant {
        _setBudget(msg.sender, jobId, token, amount, optParams);
    }

    function _setBudget(
        address actor,
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) internal {
        JobStorage storage job = _job(jobId);
        if (actor != job.provider) revert Unauthorized();
        if (job.status != JobStatus.Open) revert InvalidStatus(job.status);
        if (block.timestamp >= job.expiredAt) revert JobAlreadyExpired();
        if (token == address(0)) revert ZeroAddress();
        if (!allowedPaymentTokens[token]) revert PaymentTokenNotAllowed();
        _validatePayoutReceiver(job.payoutReceiver, token);

        bytes memory data = abi.encode(actor, token, amount, optParams);
        _hookBefore(job.hook, jobId, this.setBudget.selector, data);

        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, token, amount);

        _hookAfter(job.hook, jobId, this.setBudget.selector, data);
    }

    /// @inheritdoc IERC8183
    function fund(
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external nonReentrant {
        _fund(msg.sender, jobId, expectedToken, expectedBudget, optParams);
    }

    function _fund(
        address actor,
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) internal {
        JobStorage storage job = _job(jobId);
        if (actor != job.client) revert Unauthorized();
        if (job.status != JobStatus.Open) revert InvalidStatus(job.status);
        if (block.timestamp >= job.expiredAt) revert JobAlreadyExpired();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.paymentToken != expectedToken) revert PaymentTokenMismatch();
        if (job.budget != expectedBudget) revert BudgetMismatch(job.budget, expectedBudget);
        if (!allowedPaymentTokens[job.paymentToken]) revert PaymentTokenNotAllowed();

        bytes memory data = abi.encode(actor, optParams);
        _hookBefore(job.hook, jobId, this.fund.selector, data);

        // Funded before transfer so an Open `claimRefund` cannot observe pulled tokens.
        job.status = JobStatus.Funded;
        job.fundedPlatformFeeBp = _toUint16(platformFeeBp);
        job.fundedEvaluatorFeeBp = _toUint16(evaluatorFeeBp);
        job.fundedTreasury = treasury;

        if (job.budget > 0) {
            IERC20 token = IERC20(job.paymentToken);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(actor, address(this), job.budget);
            uint256 received = token.balanceOf(address(this)) - balanceBefore;
            if (received != job.budget) revert UnexpectedFundedAmount();
        }
        emit JobFunded(jobId, actor, job.budget);

        _hookAfter(job.hook, jobId, this.fund.selector, data);
    }

    /// @inheritdoc IERC8183
    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external nonReentrant {
        _submit(msg.sender, jobId, deliverable, optParams);
    }

    function _submit(
        address actor,
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        JobStorage storage job = _job(jobId);
        if (actor != job.provider) revert Unauthorized();
        if (job.status != JobStatus.Funded && !(job.status == JobStatus.Open && job.budget == 0)) {
            revert InvalidStatus(job.status);
        }
        if (block.timestamp >= job.expiredAt) revert JobAlreadyExpired();

        bytes memory data = abi.encode(actor, deliverable, optParams);
        if (pendingClaimHash[jobId] != bytes32(0)) {
            delete pendingClaimHash[jobId];
            // Short ASCII sentinel; fits in 32 bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            emit ClaimRejected(jobId, actor, bytes32("superseded-by-submit"));
        }
        _hookBefore(job.hook, jobId, this.submit.selector, data);

        job.status = JobStatus.Submitted;
        // forge-lint: disable-next-line(unsafe-typecast)
        job.submittedAt = uint48(block.timestamp);
        emit JobSubmitted(jobId, actor, deliverable);

        _hookAfter(job.hook, jobId, this.submit.selector, data);
    }

    /// @inheritdoc IERC8183
    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external nonReentrant {
        _complete(msg.sender, jobId, reason, optParams);
    }

    function _complete(
        address actor,
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) internal {
        JobStorage storage job = _job(jobId);
        if (actor != job.evaluator) revert Unauthorized();
        if (job.status != JobStatus.Submitted) revert InvalidStatus(job.status);

        bytes memory data = abi.encode(actor, reason, optParams);
        _hookBefore(job.hook, jobId, this.complete.selector, data);

        job.status = JobStatus.Completed;
        _distributeSettlement(jobId, job, job.budget - job.settledAmount, this.complete.selector, optParams);

        emit JobCompleted(jobId, actor, reason);
        _hookAfter(job.hook, jobId, this.complete.selector, data);
    }

    /// @inheritdoc IERC8183
    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external nonReentrant {
        _reject(msg.sender, jobId, reason, optParams);
    }

    function _reject(
        address actor,
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) internal {
        JobStorage storage job = _job(jobId);
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted) {
            revert InvalidStatus(job.status);
        }
        if (job.status == JobStatus.Open) {
            if (actor != job.client && actor != job.provider) revert Unauthorized();
        } else if (actor != job.evaluator) {
            revert Unauthorized();
        }

        bytes memory data = abi.encode(actor, reason, optParams);
        if (pendingClaimHash[jobId] != bytes32(0)) {
            delete pendingClaimHash[jobId];
            emit ClaimRejected(jobId, actor, reason);
        }
        _hookBefore(job.hook, jobId, this.reject.selector, data);

        JobStatus prev = job.status;
        job.status = JobStatus.Rejected;

        uint256 remainder = job.budget - job.settledAmount;
        if ((prev == JobStatus.Funded || prev == JobStatus.Submitted) && remainder > 0) {
            IERC20(job.paymentToken).safeTransfer(job.client, remainder);
            emit Refunded(jobId, job.client, remainder);
        }

        emit JobRejected(jobId, actor, reason);
        _hookAfter(job.hook, jobId, this.reject.selector, data);
    }

    /// @inheritdoc IERC8183
    function claimRefund(
        uint256 jobId
    ) external nonReentrant {
        JobStorage storage job = _job(jobId);
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted) {
            revert InvalidStatus(job.status);
        }
        if (job.status == JobStatus.Submitted) {
            if (block.timestamp < uint256(job.expiredAt) + EVALUATION_GRACE_PERIOD) {
                revert GracePeriodActive();
            }
        } else if (pendingClaimHash[jobId] != bytes32(0)) {
            revert PendingClaimExists();
        } else if (block.timestamp < job.expiredAt) {
            revert JobNotExpired();
        }

        JobStatus prev = job.status;
        job.status = JobStatus.Expired;

        uint256 remainder = job.budget - job.settledAmount;
        if ((prev == JobStatus.Funded || prev == JobStatus.Submitted) && remainder > 0) {
            IERC20(job.paymentToken).safeTransfer(job.client, remainder);
            emit Refunded(jobId, job.client, remainder);
        }

        emit JobExpired(jobId);
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

    /// @notice Allow or revoke an ERC-20 as a payment token.
    /// @dev Allowlist does not prove plain ERC-20 semantics. FoT, rebasing,
    ///      ERC-777/1363 hooks, and pausable/blacklist tokens can still break
    ///      accounting after `fund`. Admin must vet tokens.
    function setPaymentTokenAllowed(
        address token,
        bool status
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = status;
        emit PaymentTokenAllowlistUpdated(token, status);
    }

    function batchDetachHook(
        uint256[] calldata jobIds
    ) external onlyOwner {
        for (uint256 i = 0; i < jobIds.length; i++) {
            uint256 jobId = jobIds[i];
            JobStorage storage job = _job(jobId);
            address oldHook = job.hook;
            if (oldHook == address(0)) continue;
            job.hook = address(0);
            emit HookDetached(jobId, oldHook);
        }
    }

    /// @inheritdoc IERC8183
    function getJob(
        uint256 jobId
    ) external view returns (Job memory) {
        JobStorage storage s = _job(jobId);
        return Job({
            client: s.client,
            status: s.status,
            provider: s.provider,
            expiredAt: s.expiredAt,
            evaluator: s.evaluator,
            submittedAt: s.submittedAt,
            budget: s.budget,
            hook: s.hook,
            paymentToken: s.paymentToken,
            providerAgentId: s.providerAgentId,
            description: s.description,
            settledAmount: s.settledAmount,
            payoutReceiver: s.payoutReceiver
        });
    }

    function getFeeSnapshot(
        uint256 jobId
    ) external view returns (uint16 platformFeeBp_, uint16 evaluatorFeeBp_, address treasury_) {
        JobStorage storage s = _job(jobId);
        return (s.fundedPlatformFeeBp, s.fundedEvaluatorFeeBp, s.fundedTreasury);
    }

    function _job(
        uint256 jobId
    ) internal view returns (JobStorage storage job) {
        if (jobId == 0 || jobId > jobCounter) revert JobDoesNotExist();
        job = _jobs[jobId];
    }

    function _validatePayoutReceiver(
        address payoutReceiver,
        address paymentToken
    ) internal view {
        if (payoutReceiver == address(this)) revert InvalidReceiver();
        if (payoutReceiver != address(0) && payoutReceiver == paymentToken) revert InvalidReceiver();
    }

    function _distributeSettlement(
        uint256 jobId,
        JobStorage storage job,
        uint256 delta,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        uint256 platformFee = (delta * job.fundedPlatformFeeBp) / BP_DENOMINATOR;
        uint256 evalFee = (delta * job.fundedEvaluatorFeeBp) / BP_DENOMINATOR;
        uint256 net = delta - platformFee - evalFee;
        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(job.fundedTreasury, platformFee);
            emit PlatformFeePaid(jobId, job.fundedTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        _payout(jobId, job, net, selector, optParams);
    }

    function _payout(
        uint256 jobId,
        JobStorage storage job,
        uint256 net,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        address recipient = job.payoutReceiver == address(0) ? job.provider : job.payoutReceiver;
        if (net == 0) return;
        IERC20(job.paymentToken).safeTransfer(recipient, net);
        emit PaymentReleased(jobId, recipient, net);
        if (recipient.code.length > 0 && ERC165Checker.supportsInterface(recipient, type(IDisburser).interfaceId)) {
            IDisburser(recipient).onDisbursement(jobId, selector, job.paymentToken, net, optParams);
            emit Disbursed(jobId, recipient, selector, net);
        }
    }

    function _hookBefore(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook == address(0)) return;
        IERC8183Hook(hook).beforeAction{gas: HOOK_GAS_LIMIT}(jobId, selector, data);
    }

    function _hookAfter(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook == address(0)) return;
        IERC8183Hook(hook).afterAction{gas: HOOK_GAS_LIMIT}(jobId, selector, data);
    }

    function _toUint16(
        uint256 value
    ) internal pure returns (uint16) {
        // Fees are capped at MAX_FEE_BP (5000) before snapshot.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }
}
