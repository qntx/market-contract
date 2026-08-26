// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC8183} from "../src/ERC8183.sol";
import {ERC8183WithAuthorization} from "../src/ERC8183WithAuthorization.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";
import {MockDisburser} from "./mocks/MockDisburser.sol";
import {MockERC1271NonceObserver, MockERC1271Rejector} from "./mocks/MockERC1271NonceObserver.sol";

contract ERC8183WithAuthorizationTest is Test {
    uint256 internal constant TWENTY_USDC = 20_000_000;
    uint256 internal constant TEN_USDC = 10_000_000;
    uint72 internal constant MAX_UINT72 = type(uint72).max;
    bytes32 internal constant DELIVERABLE = keccak256("deliverable");
    bytes32 internal constant REASON = keccak256("reason");
    bytes32 internal constant MILESTONE = keccak256("milestone-1");

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant CREATE_JOB_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateJobAuthorization(address signer,address provider,address evaluator,uint48 expiredAt,bytes32 descriptionHash,address hook,uint256 providerAgentId,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetPayoutReceiverAuthorization(address signer,uint256 jobId,address payoutReceiver,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant SET_PROVIDER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetProviderAuthorization(address signer,uint256 jobId,address provider,uint256 agentId,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant SET_BUDGET_AUTHORIZATION_TYPEHASH = keccak256(
        "SetBudgetAuthorization(address signer,uint256 jobId,address token,uint256 amount,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant FUND_AUTHORIZATION_TYPEHASH = keccak256(
        "FundAuthorization(address signer,uint256 jobId,address expectedToken,uint256 expectedBudget,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant SUBMIT_AUTHORIZATION_TYPEHASH = keccak256(
        "SubmitAuthorization(address signer,uint256 jobId,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant COMPLETE_AUTHORIZATION_TYPEHASH = keccak256(
        "CompleteAuthorization(address signer,uint256 jobId,uint48 submittedAt,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant REJECT_AUTHORIZATION_TYPEHASH = keccak256(
        "RejectAuthorization(address signer,uint256 jobId,uint48 submittedAt,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "SubmitClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant SETTLE_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "SettleClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant APPROVE_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "ApproveClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 internal constant REJECT_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "RejectClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );

    ERC8183WithAuthorization internal core;
    MockERC20 internal usdc;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal relayer = makeAddr("relayer");
    address internal client;
    uint256 internal clientPk;
    address internal provider;
    uint256 internal providerPk;
    address internal evaluator;
    uint256 internal evaluatorPk;

    function setUp() public {
        (client, clientPk) = makeAddrAndKey("client");
        (provider, providerPk) = makeAddrAndKey("provider");
        (evaluator, evaluatorPk) = makeAddrAndKey("evaluator");

        usdc = new MockERC20("USDC", "USDC", 6);

        vm.startPrank(owner);
        core = new ERC8183WithAuthorization(0, 0, treasury, owner);
        core.setPaymentTokenAllowed(address(usdc), true);
        vm.stopPrank();

        usdc.mint(client, TWENTY_USDC);
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);
    }

    function _futureExpiry() internal view returns (uint48) {
        return uint48(block.timestamp + 3600);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 7200;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes("ERC8183")), keccak256(bytes("1")), block.chainid, address(core)
            )
        );
    }

    function _sign(
        uint256 signerPk,
        bytes32 structHash
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _packNonce(
        address signer,
        uint72 nonce
    ) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(signer)) << 96) | uint256(nonce));
    }

    function _hashBytes(
        bytes memory value
    ) internal pure returns (bytes32) {
        return keccak256(value);
    }

    function _hashString(
        string memory value
    ) internal pure returns (bytes32) {
        return keccak256(bytes(value));
    }

    function _claimBindingHash(
        uint256 amount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(amount, deliverable, keccak256(optParams)));
    }

    function _auth(
        address signer,
        uint72 nonce,
        uint256 deadline,
        bytes memory sig
    ) internal pure returns (ERC8183WithAuthorization.Authorization memory) {
        return ERC8183WithAuthorization.Authorization({signer: signer, nonce: nonce, deadline: deadline, sig: sig});
    }

    function _createParams(
        address provider_,
        address evaluator_,
        uint48 expiredAt,
        string memory description,
        address hook,
        uint256 providerAgentId
    ) internal pure returns (ERC8183WithAuthorization.CreateJobAuthorizationParams memory) {
        return ERC8183WithAuthorization.CreateJobAuthorizationParams({
            provider: provider_,
            evaluator: evaluator_,
            expiredAt: expiredAt,
            description: description,
            hook: hook,
            providerAgentId: providerAgentId
        });
    }

    function _signCreateJob(
        uint256 signerPk,
        address signer,
        address provider_,
        address evaluator_,
        uint48 expiredAt,
        string memory description,
        address hook,
        uint256 providerAgentId,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    CREATE_JOB_AUTHORIZATION_TYPEHASH,
                    signer,
                    provider_,
                    evaluator_,
                    expiredAt,
                    _hashString(description),
                    hook,
                    providerAgentId,
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSetPayoutReceiver(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address payoutReceiver,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH, signer, jobId, payoutReceiver, nonce, deadline)
            )
        );
    }

    function _signSetProvider(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address provider_,
        uint256 agentId,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(SET_PROVIDER_AUTHORIZATION_TYPEHASH, signer, jobId, provider_, agentId, nonce, deadline)
            )
        );
    }

    function _signSetBudget(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address token,
        uint256 amount,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SET_BUDGET_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    token,
                    amount,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signFund(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    FUND_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    expectedToken,
                    expectedBudget,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSubmit(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SUBMIT_AUTHORIZATION_TYPEHASH, signer, jobId, deliverable, _hashBytes(optParams), nonce, deadline
                )
            )
        );
    }

    function _signComplete(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint48 submittedAt,
        bytes32 reason,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    COMPLETE_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    submittedAt,
                    reason,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signReject(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint48 submittedAt,
        bytes32 reason,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    REJECT_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    submittedAt,
                    reason,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSubmitClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSettleClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SETTLE_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signApproveClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    APPROVE_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signRejectClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    REJECT_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    reason,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _createFundedJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, evaluator, _futureExpiry(), "claim auth job", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");
    }

    function _relayCreateJob(
        address signer,
        uint256 signerPk,
        address provider_,
        address evaluator_,
        uint48 expiry,
        string memory description,
        uint72 nonce,
        uint256 deadline
    ) internal returns (uint256 jobId) {
        bytes memory sig = _signCreateJob(
            signerPk, signer, provider_, evaluator_, expiry, description, address(0), 0, nonce, deadline
        );
        vm.prank(relayer);
        jobId = core.createJobWithAuthorization(
            _createParams(provider_, evaluator_, expiry, description, address(0), 0),
            _auth(signer, nonce, deadline, sig)
        );
    }

    function _relaySetBudget(
        uint256 jobId,
        uint72 nonce,
        uint256 deadline
    ) internal {
        bytes memory sig = _signSetBudget(providerPk, provider, jobId, address(usdc), TWENTY_USDC, "", nonce, deadline);
        vm.prank(relayer);
        core.setBudgetWithAuthorization(jobId, address(usdc), TWENTY_USDC, "", _auth(provider, nonce, deadline, sig));
    }

    function _relayFund(
        uint256 jobId,
        uint72 nonce,
        uint256 deadline
    ) internal {
        bytes memory sig = _signFund(clientPk, client, jobId, address(usdc), TWENTY_USDC, "", nonce, deadline);
        vm.prank(relayer);
        core.fundWithAuthorization(jobId, address(usdc), TWENTY_USDC, "", _auth(client, nonce, deadline, sig));
    }

    function _relaySubmit(
        uint256 jobId,
        bytes32 deliverable,
        uint72 nonce,
        uint256 deadline
    ) internal {
        bytes memory sig = _signSubmit(providerPk, provider, jobId, deliverable, "", nonce, deadline);
        vm.prank(relayer);
        core.submitWithAuthorization(jobId, deliverable, "", _auth(provider, nonce, deadline, sig));
    }

    function _relayComplete(
        uint256 jobId,
        bytes32 reason,
        uint72 nonce,
        uint256 deadline
    ) internal {
        uint48 submittedAt = core.getJob(jobId).submittedAt;
        bytes memory sig = _signComplete(evaluatorPk, evaluator, jobId, submittedAt, reason, "", nonce, deadline);
        vm.prank(relayer);
        core.completeWithAuthorization(jobId, reason, "", _auth(evaluator, nonce, deadline, sig));
    }

    // =====================================================================
    //  Domain / typehashes
    // =====================================================================

    function test_domainSeparatorUsesERC8183ProtocolDomain() public view {
        assertEq(core.DOMAIN_SEPARATOR(), _domainSeparator());
    }

    function test_authorizationTypehashesArePublic() public view {
        assertEq(core.CREATE_JOB_AUTHORIZATION_TYPEHASH(), CREATE_JOB_AUTHORIZATION_TYPEHASH);
        assertEq(core.SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH(), SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH);
        assertEq(core.SET_PROVIDER_AUTHORIZATION_TYPEHASH(), SET_PROVIDER_AUTHORIZATION_TYPEHASH);
        assertEq(core.SET_BUDGET_AUTHORIZATION_TYPEHASH(), SET_BUDGET_AUTHORIZATION_TYPEHASH);
        assertEq(core.FUND_AUTHORIZATION_TYPEHASH(), FUND_AUTHORIZATION_TYPEHASH);
        assertEq(core.SUBMIT_AUTHORIZATION_TYPEHASH(), SUBMIT_AUTHORIZATION_TYPEHASH);
        assertEq(core.COMPLETE_AUTHORIZATION_TYPEHASH(), COMPLETE_AUTHORIZATION_TYPEHASH);
        assertEq(core.REJECT_AUTHORIZATION_TYPEHASH(), REJECT_AUTHORIZATION_TYPEHASH);
        assertEq(core.SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH(), SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH);
        assertEq(core.SETTLE_CLAIM_AUTHORIZATION_TYPEHASH(), SETTLE_CLAIM_AUTHORIZATION_TYPEHASH);
        assertEq(core.APPROVE_CLAIM_AUTHORIZATION_TYPEHASH(), APPROVE_CLAIM_AUTHORIZATION_TYPEHASH);
        assertEq(core.REJECT_CLAIM_AUTHORIZATION_TYPEHASH(), REJECT_CLAIM_AUTHORIZATION_TYPEHASH);
    }

    // =====================================================================
    //  Full flow
    // =====================================================================

    function test_relaysFullSignedJobFlow() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "authorization image job";

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(client, _packNonce(client, 1));
        uint256 jobId = _relayCreateJob(client, clientPk, provider, evaluator, expiry, description, 1, deadline);

        assertEq(core.getJob(jobId).client, client);
        assertEq(core.getJob(jobId).payoutReceiver, address(0));

        _relaySetBudget(jobId, 2, deadline);
        _relayFund(jobId, 3, deadline);

        _relaySubmit(jobId, DELIVERABLE, 4, deadline);

        _relayComplete(jobId, REASON, 5, deadline);

        assertEq(uint8(core.getJob(jobId).status), uint8(IERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(usdc.balanceOf(relayer), 0);
    }

    function test_createJobWithAuthorizationLeavesPayoutReceiverUnset() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "authorization receiver job";
        uint72 nonce = 6;

        bytes memory sig =
            _signCreateJob(clientPk, client, provider, evaluator, expiry, description, address(0), 0, nonce, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(client, _packNonce(client, nonce));
        vm.prank(relayer);
        uint256 jobId = core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, description, address(0), 0), _auth(client, nonce, deadline, sig)
        );

        IERC8183.Job memory job = core.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.payoutReceiver, address(0));
    }

    function test_setPayoutReceiverWithAuthorization_ProviderOnlyOpenOnlyAndLocksAfterFund() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint256 jobId = _relayCreateJob(client, clientPk, provider, evaluator, expiry, "receiver auth job", 1, deadline);
        address plainReceiver = makeAddr("plainReceiver");
        address secondReceiver = makeAddr("secondReceiver");

        bytes memory clientSig = _signSetPayoutReceiver(clientPk, client, jobId, plainReceiver, 2, deadline);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, plainReceiver, _auth(client, 2, deadline, clientSig));

        bytes memory providerSig = _signSetPayoutReceiver(providerPk, provider, jobId, plainReceiver, 3, deadline);
        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(provider, _packNonce(provider, 3));
        vm.expectEmit(true, true, true, true, address(core));
        emit IERC8183.PayoutReceiverSet(jobId, plainReceiver);
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, plainReceiver, _auth(provider, 3, deadline, providerSig));

        assertEq(core.getJob(jobId).payoutReceiver, plainReceiver);

        _relaySetBudget(jobId, 4, deadline);
        _relayFund(jobId, 5, deadline);

        bytes memory lockedSig = _signSetPayoutReceiver(providerPk, provider, jobId, secondReceiver, 6, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Funded));
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, secondReceiver, _auth(provider, 6, deadline, lockedSig));
    }

    function test_relaysClientAuthorizedSetProvider() public {
        vm.prank(client);
        uint256 jobId = core.createJob(address(0), evaluator, _futureExpiry(), "late provider", address(0), 0);
        uint256 deadline = _deadline();
        uint256 agentId = 7;
        bytes memory sig = _signSetProvider(clientPk, client, jobId, provider, agentId, 61, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(client, _packNonce(client, 61));
        vm.prank(relayer);
        core.setProviderWithAuthorization(jobId, provider, agentId, _auth(client, 61, deadline, sig));

        assertEq(core.getJob(jobId).provider, provider);
        assertEq(core.getJob(jobId).providerAgentId, agentId);
        assertTrue(core.authorizationNonceUsed(_packNonce(client, 61)));
    }

    function test_relaysEvaluatorAuthorizedReject() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        uint48 submittedAt = core.getJob(jobId).submittedAt;
        bytes memory sig = _signReject(evaluatorPk, evaluator, jobId, submittedAt, REASON, "", 62, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(evaluator, _packNonce(evaluator, 62));
        vm.prank(relayer);
        core.rejectWithAuthorization(jobId, REASON, "", _auth(evaluator, 62, deadline, sig));

        assertEq(uint8(core.getJob(jobId).status), uint8(IERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
        assertTrue(core.authorizationNonceUsed(_packNonce(evaluator, 62)));
    }

    // =====================================================================
    //  submittedAt binding
    // =====================================================================

    function test_completeWithAuthorization_RevertsWhenSignedBeforeSubmission() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        uint72 nonce = 67;

        bytes memory sig = _signComplete(evaluatorPk, evaluator, jobId, 0, REASON, "", nonce, deadline);

        vm.prank(provider);
        core.submit(jobId, DELIVERABLE, "");
        assertGt(core.getJob(jobId).submittedAt, 0);

        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.completeWithAuthorization(jobId, REASON, "", _auth(evaluator, nonce, deadline, sig));

        assertFalse(core.authorizationNonceUsed(_packNonce(evaluator, nonce)));
        assertEq(uint8(core.getJob(jobId).status), uint8(IERC8183.JobStatus.Submitted));
        assertEq(usdc.balanceOf(provider), 0);
    }

    function test_rejectWithAuthorization_RevertsWhenSignedBeforeSubmission() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        uint72 nonce = 68;

        bytes memory sig = _signReject(evaluatorPk, evaluator, jobId, 0, REASON, "", nonce, deadline);

        vm.prank(provider);
        core.submit(jobId, DELIVERABLE, "");
        assertGt(core.getJob(jobId).submittedAt, 0);

        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.rejectWithAuthorization(jobId, REASON, "", _auth(evaluator, nonce, deadline, sig));

        assertFalse(core.authorizationNonceUsed(_packNonce(evaluator, nonce)));
        assertEq(uint8(core.getJob(jobId).status), uint8(IERC8183.JobStatus.Submitted));
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
    }

    // =====================================================================
    //  fund binding
    // =====================================================================

    function test_fundWithAuthorization_pullsFromSignerNotRelayer() public {
        uint256 deadline = _deadline();
        uint256 jobId =
            _relayCreateJob(client, clientPk, provider, evaluator, _futureExpiry(), "fund signer", 70, deadline);
        _relaySetBudget(jobId, 71, deadline);

        uint256 clientBefore = usdc.balanceOf(client);
        _relayFund(jobId, 72, deadline);

        assertEq(usdc.balanceOf(client), clientBefore - TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(uint8(core.getJob(jobId).status), uint8(IERC8183.JobStatus.Funded));
        assertEq(core.getJob(jobId).client, client);
    }

    function test_fundWithAuthorization_RevertsWhenPaymentTokenChangesAfterSigning() public {
        MockERC20 other = new MockERC20("USDT", "USDT", 6);

        vm.prank(owner);
        core.setPaymentTokenAllowed(address(other), true);

        other.mint(client, TWENTY_USDC);
        vm.prank(client);
        other.approve(address(core), TWENTY_USDC);

        uint256 deadline = _deadline();
        uint256 jobId =
            _relayCreateJob(client, clientPk, provider, evaluator, _futureExpiry(), "fund token binding", 65, deadline);

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");

        uint72 nonce = 66;
        bytes memory sig = _signFund(clientPk, client, jobId, address(usdc), TWENTY_USDC, "", nonce, deadline);

        vm.prank(provider);
        core.setBudget(jobId, address(other), TWENTY_USDC, "");

        vm.expectRevert(ERC8183.PaymentTokenMismatch.selector);
        vm.prank(relayer);
        core.fundWithAuthorization(jobId, address(usdc), TWENTY_USDC, "", _auth(client, nonce, deadline, sig));

        assertFalse(core.authorizationNonceUsed(_packNonce(client, nonce)));
        assertEq(usdc.balanceOf(address(core)), 0);
        assertEq(other.balanceOf(address(core)), 0);
    }

    // =====================================================================
    //  Claims
    // =====================================================================

    function test_relaysProviderAuthorizedClaimIntoPendingStateAndApproval() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes memory optParams = hex"1234";

        bytes memory submitClaimSig =
            _signSubmitClaim(providerPk, provider, jobId, TEN_USDC, MILESTONE, optParams, 21, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(provider, _packNonce(provider, 21));
        vm.expectEmit(true, true, true, true, address(core));
        emit IERC8183.ClaimSubmitted(jobId, provider, TEN_USDC, TEN_USDC, MILESTONE, optParams);
        vm.prank(relayer);
        core.submitClaimWithAuthorization(
            jobId, TEN_USDC, MILESTONE, optParams, _auth(provider, 21, deadline, submitClaimSig)
        );

        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, MILESTONE, optParams));
        assertEq(usdc.balanceOf(provider), 0);

        bytes memory approveClaimSig =
            _signApproveClaim(evaluatorPk, evaluator, jobId, TEN_USDC, MILESTONE, optParams, 22, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(evaluator, _packNonce(evaluator, 22));
        vm.expectEmit(true, true, true, true, address(core));
        emit IERC8183.ClaimApproved(jobId, evaluator, TEN_USDC, TEN_USDC, MILESTONE);
        vm.prank(relayer);
        core.approveClaimWithAuthorization(
            jobId, TEN_USDC, MILESTONE, optParams, _auth(evaluator, 22, deadline, approveClaimSig)
        );

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
    }

    function test_relaysProviderAuthorizedClaimRejectionClearsPendingState() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes memory submitClaimSig =
            _signSubmitClaim(providerPk, provider, jobId, TEN_USDC, MILESTONE, "", 24, deadline);
        vm.prank(relayer);
        core.submitClaimWithAuthorization(jobId, TEN_USDC, MILESTONE, "", _auth(provider, 24, deadline, submitClaimSig));

        bytes memory rejectClaimSig =
            _signRejectClaim(providerPk, provider, jobId, TEN_USDC, MILESTONE, REASON, "", 25, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(provider, _packNonce(provider, 25));
        vm.expectEmit(true, true, true, true, address(core));
        emit IERC8183.ClaimRejected(jobId, provider, REASON);
        vm.prank(relayer);
        core.rejectClaimWithAuthorization(
            jobId, TEN_USDC, MILESTONE, REASON, "", _auth(provider, 25, deadline, rejectClaimSig)
        );

        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_relaysClientAuthorizedSettleClaimFastPath() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes32 deliverable = bytes32(0);

        bytes memory settleClaimSig = _signSettleClaim(clientPk, client, jobId, TEN_USDC, deliverable, "", 23, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(client, _packNonce(client, 23));
        vm.expectEmit(true, true, true, true, address(core));
        emit IERC8183.ClaimSettled(jobId, client, TEN_USDC, TEN_USDC, deliverable);
        vm.prank(relayer);
        core.settleClaimWithAuthorization(jobId, TEN_USDC, deliverable, "", _auth(client, 23, deadline, settleClaimSig));

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
    }

    function test_claimAuthorizationRejectsCrossFunctionReplayWithSameLayout() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        uint72 nonce = 67;

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, MILESTONE, "");

        bytes memory settleSig = _signSettleClaim(clientPk, client, jobId, TEN_USDC, MILESTONE, "", nonce, deadline);

        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.approveClaimWithAuthorization(jobId, TEN_USDC, MILESTONE, "", _auth(client, nonce, deadline, settleSig));

        assertFalse(core.authorizationNonceUsed(_packNonce(client, nonce)));
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, MILESTONE, ""));
        assertEq(core.getJob(jobId).settledAmount, 0);
    }

    // =====================================================================
    //  Nonce / expiry / tamper
    // =====================================================================

    function test_rejectsReplayedAuthorizations() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "replay test";
        uint72 authNonce = 11;
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, authNonce, deadline
        );
        ERC8183WithAuthorization.Authorization memory auth = _auth(client, authNonce, deadline, sig);

        vm.prank(relayer);
        core.createJobWithAuthorization(params, auth);
        assertTrue(core.authorizationNonceUsed(_packNonce(client, authNonce)));

        vm.expectRevert(ERC8183WithAuthorization.AuthorizationNonceUsed.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, auth);
    }

    function test_rejectsExpiredAuthorizations() public {
        uint48 expiry = _futureExpiry();
        uint256 expiredDeadline = block.timestamp - 1;
        uint72 expiredNonce = 12;
        bytes memory expiredSig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, "expired", address(0), 0, expiredNonce, expiredDeadline
        );
        vm.expectRevert(ERC8183WithAuthorization.AuthorizationExpired.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, "expired", address(0), 0),
            _auth(client, expiredNonce, expiredDeadline, expiredSig)
        );
        assertFalse(core.authorizationNonceUsed(_packNonce(client, expiredNonce)));
        assertEq(core.jobCounter(), 0);
    }

    function test_rejectsTamperedAuthorizations() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 tamperedNonce = 13;
        bytes memory tamperedSig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, "signed", address(0), 0, tamperedNonce, deadline
        );
        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, "tampered", address(0), 0),
            _auth(client, tamperedNonce, deadline, tamperedSig)
        );
        assertFalse(core.authorizationNonceUsed(_packNonce(client, tamperedNonce)));
    }

    function test_rejectsWrongSigner() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 14;
        bytes memory sig = _signCreateJob(
            providerPk, client, provider, evaluator, expiry, "wrong signer", address(0), 0, nonce, deadline
        );
        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, "wrong signer", address(0), 0),
            _auth(client, nonce, deadline, sig)
        );
        assertFalse(core.authorizationNonceUsed(_packNonce(client, nonce)));
    }

    function test_acceptsMaximumUint72NonceAndStoresPackedKey() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "max nonce";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, MAX_UINT72, deadline
        );
        bytes32 packed = _packNonce(client, MAX_UINT72);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(client, packed);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(client, MAX_UINT72, deadline, sig));

        assertTrue(core.authorizationNonceUsed(packed));
    }

    function test_allowsDifferentSignersToUseSameNumericNonce() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "shared nonce";
        uint72 sharedNonce = 42;
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory createSig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, sharedNonce, deadline
        );

        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(client, sharedNonce, deadline, createSig));

        uint256 jobId = 1;
        bytes memory setBudgetSig =
            _signSetBudget(providerPk, provider, jobId, address(usdc), TWENTY_USDC, "", sharedNonce, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(provider, _packNonce(provider, sharedNonce));
        vm.prank(relayer);
        core.setBudgetWithAuthorization(
            jobId, address(usdc), TWENTY_USDC, "", _auth(provider, sharedNonce, deadline, setBudgetSig)
        );

        assertTrue(core.authorizationNonceUsed(_packNonce(client, sharedNonce)));
        assertTrue(core.authorizationNonceUsed(_packNonce(provider, sharedNonce)));
    }

    // =====================================================================
    //  ERC-1271
    // =====================================================================

    function test_reservesPackedNonceBeforeERC1271SignatureValidation() public {
        MockERC1271NonceObserver contractSigner = new MockERC1271NonceObserver();
        address signer = address(contractSigner);
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 31;
        bytes32 packed = _packNonce(signer, nonce);
        string memory description = "erc1271 nonce reservation";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = abi.encode(address(core), packed);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationUsed(signer, packed);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(signer, nonce, deadline, sig));

        assertTrue(core.authorizationNonceUsed(packed));
        assertEq(core.getJob(1).client, signer);
    }

    function test_rejectsERC1271InvalidSignatureAndRollsBackNonce() public {
        MockERC1271Rejector contractSigner = new MockERC1271Rejector();
        address signer = address(contractSigner);
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 32;
        bytes32 packed = _packNonce(signer, nonce);
        string memory description = "erc1271 invalid";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);

        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(signer, nonce, deadline, hex""));

        assertFalse(core.authorizationNonceUsed(packed));
        assertEq(core.jobCounter(), 0);
    }

    // =====================================================================
    //  cancelAuthorization
    // =====================================================================

    function test_cancelAuthorizationBurnsSignerNonce() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 63;
        string memory description = "cancelled";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig =
            _signCreateJob(clientPk, client, provider, evaluator, expiry, description, address(0), 0, nonce, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit ERC8183WithAuthorization.AuthorizationCanceled(client, _packNonce(client, nonce));
        vm.prank(client);
        core.cancelAuthorization(nonce);

        assertTrue(core.authorizationNonceUsed(_packNonce(client, nonce)));

        vm.expectRevert(ERC8183WithAuthorization.AuthorizationNonceUsed.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(client, nonce, deadline, sig));
    }

    function test_cancelAuthorizationRejectsUsedNonce() public {
        uint72 nonce = 64;

        vm.prank(client);
        core.cancelAuthorization(nonce);

        vm.expectRevert(ERC8183WithAuthorization.AuthorizationNonceUsed.selector);
        vm.prank(client);
        core.cancelAuthorization(nonce);
    }

    function test_cancelAuthorization_relayerBurnsOwnNonceNotSigner() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 69;
        string memory description = "not relayable cancel";
        bytes memory sig =
            _signCreateJob(clientPk, client, provider, evaluator, expiry, description, address(0), 0, nonce, deadline);

        vm.prank(relayer);
        core.cancelAuthorization(nonce);

        assertTrue(core.authorizationNonceUsed(_packNonce(relayer, nonce)));
        assertFalse(core.authorizationNonceUsed(_packNonce(client, nonce)));

        vm.prank(relayer);
        uint256 jobId = core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, description, address(0), 0), _auth(client, nonce, deadline, sig)
        );
        assertEq(core.getJob(jobId).client, client);
    }

    // =====================================================================
    //  Canonical selectors
    // =====================================================================

    function test_withAuthorization_hooksSeeCanonicalSelectorsAndSigner() public {
        MockHook hook = new MockHook();
        vm.prank(owner);
        core.setHookWhitelist(address(hook), true);

        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        bytes memory createSig =
            _signCreateJob(clientPk, client, provider, evaluator, expiry, "hooked", address(hook), 0, 80, deadline);
        vm.prank(relayer);
        uint256 jobId = core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, "hooked", address(hook), 0),
            _auth(client, 80, deadline, createSig)
        );

        _relaySetBudget(jobId, 81, deadline);
        assertEq(hook.lastSelector(), IERC8183.setBudget.selector);
        (address budgetCaller,,,) = abi.decode(hook.lastData(), (address, address, uint256, bytes));
        assertEq(budgetCaller, provider);

        _relayFund(jobId, 82, deadline);
        assertEq(hook.lastSelector(), IERC8183.fund.selector);
        (address fundCaller,) = abi.decode(hook.lastData(), (address, bytes));
        assertEq(fundCaller, client);

        _relaySubmit(jobId, DELIVERABLE, 83, deadline);
        assertEq(hook.lastSelector(), IERC8183.submit.selector);

        _relayComplete(jobId, REASON, 84, deadline);
        assertEq(hook.lastSelector(), IERC8183.complete.selector);
        (address completeCaller,,) = abi.decode(hook.lastData(), (address, bytes32, bytes));
        assertEq(completeCaller, evaluator);
        assertTrue(hook.lastSelector() != core.completeWithAuthorization.selector);
        assertTrue(hook.lastSelector() != core.fundWithAuthorization.selector);
    }

    function test_completeWithAuthorization_disburserSeesCanonicalSelector() public {
        MockDisburser disburser = new MockDisburser();
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, _futureExpiry(), "disburser", address(0), 0);
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(disburser));
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(provider);
        core.submit(jobId, DELIVERABLE, "");

        _relayComplete(jobId, REASON, 90, _deadline());

        assertEq(disburser.lastSelector(), IERC8183.complete.selector);
        assertEq(disburser.callCount(), 1);
        assertTrue(disburser.lastSelector() != core.completeWithAuthorization.selector);
    }
}
