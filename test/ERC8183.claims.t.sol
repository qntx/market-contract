// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC8183} from "../src/ERC8183.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";
import {IReentrantERC8183, MockDisburser, ReentrantDisburser} from "./mocks/MockDisburser.sol";

contract ERC8183ClaimsTest is Test {
    ERC8183 internal core;
    MockERC20 internal token;
    MockHook internal hook;

    address internal owner = makeAddr("owner");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal treasury = makeAddr("treasury");
    address internal rando = makeAddr("rando");
    address internal receiver = makeAddr("receiver");

    uint256 internal constant BUDGET = 1000e6;
    uint256 internal constant HALF = 500e6;
    uint256 internal constant FEE_BP = 250;
    uint256 internal constant EVAL_FEE_BP = 100;
    uint256 internal constant EXPIRY = 7 days;

    bytes32 internal constant DELIVERABLE = keccak256("deliverable");
    bytes32 internal constant REASON = keccak256("reason");

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        hook = new MockHook();

        vm.startPrank(owner);
        core = new ERC8183(FEE_BP, EVAL_FEE_BP, treasury, owner);
        core.setPaymentTokenAllowed(address(token), true);
        core.setHookWhitelist(address(hook), true);
        vm.stopPrank();

        token.mint(client, 100_000e6);
        vm.prank(client);
        token.approve(address(core), type(uint256).max);
    }

    function _expiry() internal view returns (uint48) {
        return uint48(block.timestamp + EXPIRY);
    }

    function _open() internal returns (uint256) {
        vm.prank(client);
        return core.createJob(provider, evaluator, _expiry(), "j", address(0), 0);
    }

    function _openHooked() internal returns (uint256) {
        vm.prank(client);
        return core.createJob(provider, evaluator, _expiry(), "j", address(hook), 0);
    }

    function _funded() internal returns (uint256 id) {
        id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
    }

    function _fundedHooked() internal returns (uint256 id) {
        id = _openHooked();
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
    }

    function _pFee(
        uint256 b
    ) internal pure returns (uint256) {
        return (b * FEE_BP) / 10_000;
    }

    function _eFee(
        uint256 b
    ) internal pure returns (uint256) {
        return (b * EVAL_FEE_BP) / 10_000;
    }

    function _net(
        uint256 b
    ) internal pure returns (uint256) {
        return b - _pFee(b) - _eFee(b);
    }

    function _claimHash(
        uint256 amt,
        bytes32 deliv,
        bytes memory opt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(amt, deliv, keccak256(opt)));
    }

    function _assertStatus(
        uint256 id,
        IERC8183.JobStatus expected
    ) internal view {
        assertEq(uint8(core.getJob(id).status), uint8(expected));
    }

    function _assertReentryBlocked(
        ReentrantDisburser disburser
    ) internal view {
        assertTrue(disburser.attempted());
        assertFalse(disburser.reentered());
        assertTrue(disburser.reentryReverted());
        bytes memory revertData = disburser.revertData();
        assertEq(revertData.length, 4);
        bytes4 actualSelector;
        assembly {
            actualSelector := mload(add(revertData, 32))
        }
        assertEq(actualSelector, bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    // =====================================================================
    //  Selectors
    // =====================================================================

    function test_selectors_claimFunctions() public view {
        assertEq(core.submitClaim.selector, bytes4(keccak256("submitClaim(uint256,uint256,bytes32,bytes)")));
        assertEq(core.submitClaim.selector, bytes4(0x5d0e9ca0));
        assertEq(core.settleClaim.selector, bytes4(keccak256("settleClaim(uint256,uint256,bytes32,bytes)")));
        assertEq(core.settleClaim.selector, bytes4(0xe8bcf104));
        assertEq(core.approveClaim.selector, bytes4(keccak256("approveClaim(uint256,uint256,bytes32,bytes)")));
        assertEq(core.approveClaim.selector, bytes4(0x165fbf71));
        assertEq(core.rejectClaim.selector, bytes4(keccak256("rejectClaim(uint256,uint256,bytes32,bytes32,bytes)")));
        assertEq(core.rejectClaim.selector, bytes4(0xd127c867));
    }

    // =====================================================================
    //  submitClaim
    // =====================================================================

    function test_submitClaim_recordsPendingHashAndEmits() public {
        uint256 id = _funded();
        bytes memory opt = hex"1234";
        uint256 pBefore = token.balanceOf(provider);

        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimSubmitted(id, provider, HALF, HALF, DELIVERABLE, opt);
        core.submitClaim(id, HALF, DELIVERABLE, opt);

        assertEq(core.pendingClaimHash(id), _claimHash(HALF, DELIVERABLE, opt));
        assertTrue(core.submittedClaimHash(id, _claimHash(HALF, DELIVERABLE, opt)));
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(provider), pBefore);
        assertEq(token.balanceOf(address(core)), BUDGET);
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    function test_submitClaim_revert_notProvider() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(evaluator);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(rando);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");
    }

    function test_submitClaim_revert_notFunded() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Open));
        core.submitClaim(id, HALF, DELIVERABLE, "");

        id = _funded();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Submitted));
        core.submitClaim(id, HALF, DELIVERABLE, "");
    }

    function test_submitClaim_revert_expired() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(provider);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");
    }

    function test_submitClaim_revert_emptyDeliverable() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(ERC8183.EmptyDeliverable.selector);
        core.submitClaim(id, HALF, bytes32(0), "");
    }

    function test_submitClaim_revert_pendingClaimExists() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(provider);
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.submitClaim(id, BUDGET, keccak256("other"), "");
    }

    function test_submitClaim_revert_noNewSettlement() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        core.submitClaim(id, 0, DELIVERABLE, "");

        vm.prank(client);
        core.settleClaim(id, HALF, bytes32(0), "");
        vm.prank(provider);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");
    }

    function test_submitClaim_revert_exceedsBudget() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(ERC8183.ExceedsBudget.selector);
        core.submitClaim(id, BUDGET + 1, DELIVERABLE, "");
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    function test_submitClaim_revert_claimAlreadySubmitted() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(provider);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");

        vm.prank(provider);
        vm.expectRevert(ERC8183.ClaimAlreadySubmitted.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");
    }

    function test_submitClaim_revert_jobDoesNotExist() public {
        vm.prank(provider);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.submitClaim(0, HALF, DELIVERABLE, "");
        vm.prank(provider);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.submitClaim(1, HALF, DELIVERABLE, "");
    }

    function test_submitClaim_hookDataEncodesCaller() public {
        uint256 id = _fundedHooked();
        bytes memory opt = hex"ab";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);
        (address caller, uint256 amt, bytes32 deliv, bytes memory decoded) =
            abi.decode(hook.lastData(), (address, uint256, bytes32, bytes));
        assertEq(caller, provider);
        assertEq(amt, HALF);
        assertEq(deliv, DELIVERABLE);
        assertEq(decoded, opt);
        assertEq(hook.lastSelector(), core.submitClaim.selector);
        assertEq(hook.beforeCalls(), 3);
        assertEq(hook.afterCalls(), 3);
    }

    function test_submitClaim_hookAfterRevertRollsBack() public {
        uint256 id = _fundedHooked();
        hook.setRevertAfter(true);
        vm.prank(provider);
        vm.expectRevert("hook:after");
        core.submitClaim(id, HALF, DELIVERABLE, "");
        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertFalse(core.submittedClaimHash(id, _claimHash(HALF, DELIVERABLE, "")));
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    // =====================================================================
    //  settleClaim
    // =====================================================================

    function test_settleClaim_releasesDelta() public {
        uint256 id = _funded();
        uint256 pBefore = token.balanceOf(provider);
        uint256 tBefore = token.balanceOf(treasury);
        uint256 eBefore = token.balanceOf(evaluator);

        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PlatformFeePaid(id, treasury, _pFee(HALF));
        vm.expectEmit(true, true, false, true);
        emit IERC8183.EvaluatorFeePaid(id, evaluator, _eFee(HALF));
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PaymentReleased(id, provider, _net(HALF));
        vm.expectEmit(true, false, false, true);
        emit IERC8183.Settled(id, HALF, HALF);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimSettled(id, client, HALF, HALF, bytes32(0));
        core.settleClaim(id, HALF, bytes32(0), "");

        assertEq(core.getJob(id).settledAmount, HALF);
        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertEq(token.balanceOf(provider), pBefore + _net(HALF));
        assertEq(token.balanceOf(treasury), tBefore + _pFee(HALF));
        assertEq(token.balanceOf(evaluator), eBefore + _eFee(HALF));
        assertEq(token.balanceOf(address(core)), HALF);
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    function test_settleClaim_cumulativeSecondDelta() public {
        uint256 id = _funded();
        vm.prank(client);
        core.settleClaim(id, HALF, bytes32(0), "");
        vm.prank(client);
        vm.expectEmit(true, false, false, true);
        emit IERC8183.Settled(id, BUDGET, HALF);
        core.settleClaim(id, BUDGET, bytes32(0), "");
        assertEq(core.getJob(id).settledAmount, BUDGET);
        assertEq(token.balanceOf(address(core)), 0);
        assertEq(token.balanceOf(provider), _net(HALF) + _net(HALF));
    }

    function test_settleClaim_doesNotConsumePending() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, BUDGET, DELIVERABLE, "");
        bytes32 pending = core.pendingClaimHash(id);

        vm.prank(client);
        core.settleClaim(id, HALF, keccak256("stream"), "");

        assertEq(core.pendingClaimHash(id), pending);
        assertEq(core.getJob(id).settledAmount, HALF);
    }

    function test_settleClaim_snapshotTreasuryAndBps() public {
        uint256 id = _funded();
        address newT = makeAddr("newTreasury");
        vm.startPrank(owner);
        core.setPlatformFee(500);
        core.setEvaluatorFee(400);
        core.setTreasury(newT);
        vm.stopPrank();

        uint256 tBefore = token.balanceOf(treasury);
        uint256 ntBefore = token.balanceOf(newT);
        uint256 eBefore = token.balanceOf(evaluator);
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PlatformFeePaid(id, treasury, _pFee(HALF));
        core.settleClaim(id, HALF, bytes32(0), "");

        assertEq(token.balanceOf(treasury), tBefore + _pFee(HALF));
        assertEq(token.balanceOf(newT), ntBefore);
        assertEq(token.balanceOf(evaluator), eBefore + _eFee(HALF));
        assertEq(token.balanceOf(provider), _net(HALF));
    }

    function test_settleClaim_paysPayoutReceiver() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, receiver);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        vm.prank(client);
        core.settleClaim(id, HALF, bytes32(0), "");
        assertEq(token.balanceOf(receiver), _net(HALF));
        assertEq(token.balanceOf(provider), 0);
    }

    function test_settleClaim_disburserCallback() public {
        MockDisburser d = new MockDisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        bytes memory opt = hex"cafe";
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.Disbursed(id, address(d), core.settleClaim.selector, _net(HALF));
        core.settleClaim(id, HALF, bytes32(0), opt);

        assertEq(d.callCount(), 1);
        assertEq(d.lastSelector(), core.settleClaim.selector);
        assertEq(d.lastAmount(), _net(HALF));
        assertEq(d.lastData(), opt);
        assertEq(token.balanceOf(address(d)), _net(HALF));
    }

    function test_settleClaim_reentrancyBlocked() public {
        ReentrantDisburser d = new ReentrantDisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        d.setReentry(IReentrantERC8183(address(core)), id, BUDGET, ReentrantDisburser.Action.SettleClaim);

        vm.prank(client);
        core.settleClaim(id, HALF, bytes32(0), "");
        assertEq(core.getJob(id).settledAmount, HALF);
        _assertReentryBlocked(d);
    }

    function test_settleClaim_revert_disburserReverts() public {
        MockDisburser d = new MockDisburser();
        d.setShouldRevert(true);
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        vm.prank(client);
        vm.expectRevert("MockDisburser: forced revert");
        core.settleClaim(id, HALF, bytes32(0), "");
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    function test_settleClaim_revert_notClient() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.settleClaim(id, HALF, bytes32(0), "");
        vm.prank(evaluator);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.settleClaim(id, HALF, bytes32(0), "");
    }

    function test_settleClaim_revert_notFunded() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Open));
        core.settleClaim(id, HALF, bytes32(0), "");

        id = _funded();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Submitted));
        core.settleClaim(id, HALF, bytes32(0), "");
    }

    function test_settleClaim_revert_expired() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(client);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.settleClaim(id, HALF, bytes32(0), "");
    }

    function test_settleClaim_revert_noNewSettlement() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        core.settleClaim(id, 0, bytes32(0), "");
        vm.prank(client);
        core.settleClaim(id, HALF, bytes32(0), "");
        vm.prank(client);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        core.settleClaim(id, HALF, bytes32(0), "");
    }

    function test_settleClaim_revert_exceedsBudget() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(ERC8183.ExceedsBudget.selector);
        core.settleClaim(id, BUDGET + 1, bytes32(0), "");
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    function test_settleClaim_revert_jobDoesNotExist() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.settleClaim(0, HALF, bytes32(0), "");
    }

    function test_settleClaim_hookDataEncodesCaller() public {
        uint256 id = _fundedHooked();
        bytes memory opt = hex"11";
        vm.prank(client);
        core.settleClaim(id, HALF, DELIVERABLE, opt);
        (address caller, uint256 amt, bytes32 deliv, bytes memory decoded) =
            abi.decode(hook.lastData(), (address, uint256, bytes32, bytes));
        assertEq(caller, client);
        assertEq(amt, HALF);
        assertEq(deliv, DELIVERABLE);
        assertEq(decoded, opt);
        assertEq(hook.lastSelector(), core.settleClaim.selector);
    }

    function test_settleClaim_hookAfterRevertRollsBack() public {
        uint256 id = _fundedHooked();
        hook.setRevertAfter(true);
        vm.prank(client);
        vm.expectRevert("hook:after");
        core.settleClaim(id, HALF, bytes32(0), "");
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    // =====================================================================
    //  approveClaim
    // =====================================================================

    function test_approveClaim_evaluatorPaysDelta() public {
        uint256 id = _funded();
        bytes memory opt = hex"1234";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);

        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PaymentReleased(id, provider, _net(HALF));
        vm.expectEmit(true, false, false, true);
        emit IERC8183.Settled(id, HALF, HALF);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimApproved(id, evaluator, HALF, HALF, DELIVERABLE);
        core.approveClaim(id, HALF, DELIVERABLE, opt);

        assertEq(core.getJob(id).settledAmount, HALF);
        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertEq(token.balanceOf(provider), _net(HALF));
        assertEq(token.balanceOf(address(core)), HALF);
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    function test_approveClaim_clientCanApprove() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(client);
        core.approveClaim(id, HALF, DELIVERABLE, "");
        assertEq(core.getJob(id).settledAmount, HALF);
        assertEq(core.pendingClaimHash(id), bytes32(0));
    }

    function test_approveClaim_afterExpiry() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.warp(core.getJob(id).expiredAt + 1);
        vm.prank(evaluator);
        core.approveClaim(id, HALF, DELIVERABLE, "");
        assertEq(core.getJob(id).settledAmount, HALF);
    }

    function test_approveClaim_snapshotTreasuryAndBps() public {
        uint256 id = _funded();
        address newT = makeAddr("newTreasury");
        vm.startPrank(owner);
        core.setPlatformFee(500);
        core.setEvaluatorFee(400);
        core.setTreasury(newT);
        vm.stopPrank();

        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");

        uint256 tBefore = token.balanceOf(treasury);
        uint256 ntBefore = token.balanceOf(newT);
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PlatformFeePaid(id, treasury, _pFee(HALF));
        core.approveClaim(id, HALF, DELIVERABLE, "");

        assertEq(token.balanceOf(treasury), tBefore + _pFee(HALF));
        assertEq(token.balanceOf(newT), ntBefore);
        assertEq(token.balanceOf(evaluator), _eFee(HALF));
        assertEq(token.balanceOf(provider), _net(HALF));
    }

    function test_approveClaim_settleWhilePendingShrinksDelta() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, BUDGET, DELIVERABLE, "");

        vm.prank(client);
        core.settleClaim(id, HALF, keccak256("stream"), "");
        assertEq(core.pendingClaimHash(id), _claimHash(BUDGET, DELIVERABLE, ""));

        vm.prank(evaluator);
        vm.expectEmit(true, false, false, true);
        emit IERC8183.Settled(id, BUDGET, HALF);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimApproved(id, evaluator, BUDGET, HALF, DELIVERABLE);
        core.approveClaim(id, BUDGET, DELIVERABLE, "");

        assertEq(core.getJob(id).settledAmount, BUDGET);
        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertEq(token.balanceOf(address(core)), 0);
        assertEq(token.balanceOf(provider), _net(HALF) + _net(HALF));
    }

    function test_approveClaim_revert_whenSettleCoveredClaim() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(client);
        core.settleClaim(id, HALF, keccak256("stream"), "");

        vm.prank(evaluator);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        core.approveClaim(id, HALF, DELIVERABLE, "");
        assertEq(core.pendingClaimHash(id), _claimHash(HALF, DELIVERABLE, ""));
    }

    function test_approveClaim_revert_unauthorized() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(provider);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.approveClaim(id, HALF, DELIVERABLE, "");
        vm.prank(rando);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.approveClaim(id, HALF, DELIVERABLE, "");
    }

    function test_approveClaim_revert_notFunded() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Open));
        core.approveClaim(id, HALF, DELIVERABLE, "");

        id = _funded();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Submitted));
        core.approveClaim(id, HALF, DELIVERABLE, "");
    }

    function test_approveClaim_revert_noPendingClaim() public {
        uint256 id = _funded();
        vm.prank(evaluator);
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        core.approveClaim(id, HALF, DELIVERABLE, "");
    }

    function test_approveClaim_revert_hashMismatch() public {
        uint256 id = _funded();
        bytes memory opt = hex"1234";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);
        vm.prank(evaluator);
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        core.approveClaim(id, HALF, DELIVERABLE, hex"5678");
        assertEq(core.pendingClaimHash(id), _claimHash(HALF, DELIVERABLE, opt));
        assertEq(core.getJob(id).settledAmount, 0);
    }

    function test_approveClaim_revert_jobDoesNotExist() public {
        vm.prank(evaluator);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.approveClaim(1, HALF, DELIVERABLE, "");
    }

    function test_approveClaim_disburserCallback() public {
        MockDisburser d = new MockDisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        bytes memory opt = hex"99";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.Disbursed(id, address(d), core.approveClaim.selector, _net(HALF));
        core.approveClaim(id, HALF, DELIVERABLE, opt);
        assertEq(d.lastSelector(), core.approveClaim.selector);
        assertEq(d.lastData(), opt);
        assertEq(token.balanceOf(address(d)), _net(HALF));
    }

    function test_approveClaim_revert_disburserRevertsRestoresPending() public {
        MockDisburser d = new MockDisburser();
        d.setShouldRevert(true);
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        bytes32 pending = core.pendingClaimHash(id);

        vm.prank(evaluator);
        vm.expectRevert("MockDisburser: forced revert");
        core.approveClaim(id, HALF, DELIVERABLE, "");
        assertEq(core.pendingClaimHash(id), pending);
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    function test_approveClaim_hookDataEncodesCaller() public {
        uint256 id = _fundedHooked();
        bytes memory opt = hex"22";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);
        vm.prank(evaluator);
        core.approveClaim(id, HALF, DELIVERABLE, opt);
        (address caller, uint256 amt, bytes32 deliv, bytes memory decoded) =
            abi.decode(hook.lastData(), (address, uint256, bytes32, bytes));
        assertEq(caller, evaluator);
        assertEq(amt, HALF);
        assertEq(deliv, DELIVERABLE);
        assertEq(decoded, opt);
        assertEq(hook.lastSelector(), core.approveClaim.selector);
    }

    // =====================================================================
    //  rejectClaim
    // =====================================================================

    function test_rejectClaim_consumesHash() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        uint256 pBefore = token.balanceOf(provider);

        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimRejected(id, client, REASON);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");

        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertTrue(core.submittedClaimHash(id, _claimHash(HALF, DELIVERABLE, "")));
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(provider), pBefore);
        assertEq(token.balanceOf(address(core)), BUDGET);
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    function test_rejectClaim_providerWithdrawThenRefileDifferent() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(provider);
        core.rejectClaim(id, HALF, DELIVERABLE, keccak256("withdrawn"), "");

        vm.prank(provider);
        vm.expectRevert(ERC8183.ClaimAlreadySubmitted.selector);
        core.submitClaim(id, HALF, DELIVERABLE, "");

        bytes memory newOpt = hex"01";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, newOpt);
        assertEq(core.pendingClaimHash(id), _claimHash(HALF, DELIVERABLE, newOpt));

        vm.prank(provider);
        core.rejectClaim(id, HALF, DELIVERABLE, keccak256("withdrawn"), newOpt);

        bytes32 next = keccak256("milestone-2");
        vm.prank(provider);
        core.submitClaim(id, HALF, next, "");
        assertEq(core.pendingClaimHash(id), _claimHash(HALF, next, ""));
    }

    function test_rejectClaim_evaluatorAndProviderAuthorized() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(evaluator);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");
        assertEq(core.pendingClaimHash(id), bytes32(0));

        bytes32 next = keccak256("m2");
        vm.prank(provider);
        core.submitClaim(id, HALF, next, "");
        vm.prank(provider);
        core.rejectClaim(id, HALF, next, REASON, "");
        assertEq(core.pendingClaimHash(id), bytes32(0));
    }

    function test_rejectClaim_afterExpiryThenRefund() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.warp(core.getJob(id).expiredAt + 1);

        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.claimRefund(id);

        vm.prank(provider);
        core.rejectClaim(id, HALF, DELIVERABLE, keccak256("withdrawn"), "");
        core.claimRefund(id);

        _assertStatus(id, IERC8183.JobStatus.Expired);
        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertEq(token.balanceOf(client), 100_000e6);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_rejectClaim_revert_unauthorized() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(rando);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");
    }

    function test_rejectClaim_revert_notFunded() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Open));
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");

        id = _funded();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Submitted));
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");
    }

    function test_rejectClaim_revert_noPending() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");
    }

    function test_rejectClaim_revert_hashMismatch() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(client);
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        core.rejectClaim(id, HALF, keccak256("other"), REASON, "");
        assertEq(core.pendingClaimHash(id), _claimHash(HALF, DELIVERABLE, ""));
    }

    function test_rejectClaim_revert_jobDoesNotExist() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.rejectClaim(1, HALF, DELIVERABLE, REASON, "");
    }

    function test_rejectClaim_hookDataEncodesCallerAndReason() public {
        uint256 id = _fundedHooked();
        bytes memory opt = hex"33";
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);
        vm.prank(client);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, opt);
        (address caller, uint256 amt, bytes32 deliv, bytes32 reason, bytes memory decoded) =
            abi.decode(hook.lastData(), (address, uint256, bytes32, bytes32, bytes));
        assertEq(caller, client);
        assertEq(amt, HALF);
        assertEq(deliv, DELIVERABLE);
        assertEq(reason, REASON);
        assertEq(decoded, opt);
        assertEq(hook.lastSelector(), core.rejectClaim.selector);
    }

    function test_rejectClaim_hookAfterRevertRollsBack() public {
        uint256 id = _fundedHooked();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        bytes32 pending = core.pendingClaimHash(id);
        hook.setRevertAfter(true);
        vm.prank(client);
        vm.expectRevert("hook:after");
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, "");
        assertEq(core.pendingClaimHash(id), pending);
    }

    // =====================================================================
    //  Interactions
    // =====================================================================

    function test_claimRefund_revert_whilePending() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.warp(core.getJob(id).expiredAt + 30 days);
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.claimRefund(id);
        _assertStatus(id, IERC8183.JobStatus.Funded);
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    function test_submit_supersedesPendingClaim() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");

        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimRejected(id, provider, bytes32("superseded-by-submit"));
        core.submit(id, keccak256("final"), "");

        _assertStatus(id, IERC8183.JobStatus.Submitted);
        assertEq(core.pendingClaimHash(id), bytes32(0));

        vm.prank(evaluator);
        core.complete(id, REASON, "");
        assertEq(core.getJob(id).settledAmount, 0);
        assertEq(token.balanceOf(address(core)), 0);
        assertEq(token.balanceOf(provider), _net(BUDGET));
    }

    function test_reject_clearsPendingClaim() public {
        uint256 id = _funded();
        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, "");
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimRejected(id, evaluator, REASON);
        core.reject(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Rejected);
        assertEq(core.pendingClaimHash(id), bytes32(0));
        assertEq(token.balanceOf(client), 100_000e6);
        assertEq(token.balanceOf(provider), 0);
    }

    function test_complete_paysRemainderAfterPartialSettle() public {
        uint256 id = _funded();
        vm.prank(client);
        core.settleClaim(id, HALF, bytes32(0), "");
        vm.prank(provider);
        core.submit(id, keccak256("final"), "");
        vm.prank(evaluator);
        core.complete(id, REASON, "");

        _assertStatus(id, IERC8183.JobStatus.Completed);
        assertEq(core.getJob(id).settledAmount, HALF);
        assertEq(token.balanceOf(provider), _net(HALF) + _net(HALF));
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_neverExceedsBudget() public {
        uint256 id = _funded();
        vm.prank(client);
        core.settleClaim(id, BUDGET, bytes32(0), "");
        vm.prank(client);
        vm.expectRevert(ERC8183.ExceedsBudget.selector);
        core.settleClaim(id, BUDGET + 1, bytes32(0), "");
        vm.prank(provider);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        core.submitClaim(id, BUDGET, DELIVERABLE, "");
        assertEq(core.getJob(id).settledAmount, BUDGET);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_claimRefund_afterFullSettle() public {
        uint256 id = _funded();
        vm.prank(client);
        core.settleClaim(id, BUDGET, bytes32(0), "");
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        _assertStatus(id, IERC8183.JobStatus.Expired);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function testFuzz_settleClaim_neverExceedsBudget(
        uint256 a,
        uint256 b
    ) public {
        uint256 id = _funded();
        a = bound(a, 1, BUDGET);
        vm.prank(client);
        core.settleClaim(id, a, bytes32(0), "");
        assertLe(core.getJob(id).settledAmount, BUDGET);
        assertEq(token.balanceOf(address(core)), BUDGET - a);

        if (a == BUDGET) {
            vm.prank(client);
            vm.expectRevert(ERC8183.NoNewSettlement.selector);
            core.settleClaim(id, a, bytes32(0), "");
            return;
        }
        b = bound(b, a + 1, BUDGET);
        vm.prank(client);
        core.settleClaim(id, b, bytes32(0), "");
        assertLe(core.getJob(id).settledAmount, BUDGET);
        assertEq(token.balanceOf(address(core)), BUDGET - b);
    }
}
