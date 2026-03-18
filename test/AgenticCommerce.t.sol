// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AgenticCommerce} from "../src/AgenticCommerce.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

contract AgenticCommerceTest is Test {
    AgenticCommerce ac;
    MockERC20 token;
    MockHook hook;

    address owner = makeAddr("owner");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");
    address treasury = makeAddr("treasury");
    address rando = makeAddr("rando");

    uint256 constant BUDGET = 1000e6;
    uint256 constant FEE_BP = 250;
    uint256 constant EVAL_FEE_BP = 100;
    uint256 constant EXPIRY = 7 days;

    bytes32 constant DELIVERABLE = keccak256("deliverable");
    bytes32 constant REASON = keccak256("reason");

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        hook = new MockHook();

        vm.startPrank(owner);
        ac = new AgenticCommerce(address(token), FEE_BP, EVAL_FEE_BP, treasury, owner);
        ac.setHookWhitelist(address(hook), true);
        vm.stopPrank();

        token.mint(client, 100_000e6);
        vm.prank(client);
        token.approve(address(ac), type(uint256).max);
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _open() internal returns (uint256) {
        vm.prank(client);
        return ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "j", address(0));
    }

    function _openHooked() internal returns (uint256) {
        vm.prank(client);
        return ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "j", address(hook));
    }

    function _openNoProvider() internal returns (uint256) {
        vm.prank(client);
        return ac.createJob(address(0), evaluator, block.timestamp + EXPIRY, "j", address(0));
    }

    function _funded() internal returns (uint256 id) {
        id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");
    }

    function _fundedHooked() internal returns (uint256 id) {
        id = _openHooked();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");
    }

    function _submitted() internal returns (uint256 id) {
        id = _funded();
        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
    }

    function _completed() internal returns (uint256 id) {
        id = _submitted();
        vm.prank(evaluator);
        ac.complete(id, REASON, "");
    }

    function _rejected() internal returns (uint256 id) {
        id = _open();
        vm.prank(client);
        ac.reject(id, REASON, "");
    }

    function _expired() internal returns (uint256 id) {
        id = _funded();
        vm.warp(block.timestamp + EXPIRY);
        ac.claimRefund(id);
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

    function _assertStatus(
        uint256 id,
        IERC8183.Status expected
    ) internal view {
        assertEq(uint8(ac.getJob(id).status), uint8(expected));
    }

    function _assertStatus(
        uint256 id,
        IERC8183.Status expected,
        string memory err
    ) internal view {
        assertEq(uint8(ac.getJob(id).status), uint8(expected), err);
    }

    // =====================================================================
    //  Constructor
    // =====================================================================

    function test_constructor_setsState() public view {
        assertEq(address(ac.PAYMENT_TOKEN()), address(token));
        assertEq(ac.platformFeeBp(), FEE_BP);
        assertEq(ac.evaluatorFeeBp(), EVAL_FEE_BP);
        assertEq(ac.treasury(), treasury);
        assertEq(ac.owner(), owner);
    }

    function test_constructor_revert_zeroToken() public {
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        new AgenticCommerce(address(0), FEE_BP, EVAL_FEE_BP, treasury, owner);
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        new AgenticCommerce(address(token), FEE_BP, EVAL_FEE_BP, address(0), owner);
    }

    function test_constructor_revert_feeTooHigh() public {
        vm.expectRevert(AgenticCommerce.FeeTooHigh.selector);
        new AgenticCommerce(address(token), 3000, 2001, treasury, owner);
    }

    function test_constructor_maxFeeExact() public {
        new AgenticCommerce(address(token), 2500, 2500, treasury, owner);
    }

    // =====================================================================
    //  supportsInterface (ERC-165)
    // =====================================================================

    function test_supportsInterface() public view {
        assertTrue(ac.supportsInterface(type(IERC8183).interfaceId));
        assertTrue(ac.supportsInterface(type(IERC165).interfaceId));
        assertFalse(ac.supportsInterface(0xdeadbeef));
    }

    // =====================================================================
    //  createJob
    // =====================================================================

    function test_createJob_setsAllFields() public {
        vm.prank(client);
        uint256 id = ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "desc", address(hook));

        assertEq(id, 1);
        IERC8183.Job memory j = ac.getJob(id);
        assertEq(j.client, client);
        assertEq(j.provider, provider);
        assertEq(j.evaluator, evaluator);
        assertEq(j.expiredAt, block.timestamp + EXPIRY);
        assertEq(j.hook, address(hook));
        assertEq(j.budget, 0);
        assertEq(uint8(j.status), uint8(IERC8183.Status.Open));
        assertEq(j.deliverable, bytes32(0));
    }

    function test_createJob_withoutProvider() public {
        uint256 id = _openNoProvider();
        assertEq(ac.getJob(id).provider, address(0));
    }

    function test_createJob_incrementsCounter() public {
        _open();
        _open();
        assertEq(ac.totalJobs(), 2);
    }

    function test_createJob_emitsEvent() public {
        vm.prank(client);
        vm.expectEmit(true, true, true, true);
        emit IERC8183.JobCreated(1, client, provider, evaluator, block.timestamp + EXPIRY, address(0));
        ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "e", address(0));
    }

    function test_createJob_revert_zeroEvaluator() public {
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.createJob(provider, address(0), block.timestamp + EXPIRY, "x", address(0));
    }

    function test_createJob_revert_pastExpiry() public {
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.InvalidExpiry.selector);
        ac.createJob(provider, evaluator, block.timestamp, "x", address(0));
    }

    function test_createJob_revert_expiryTooShort() public {
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.InvalidExpiry.selector);
        ac.createJob(provider, evaluator, block.timestamp + 4 minutes, "x", address(0));
    }

    function test_createJob_revert_descriptionTooLong() public {
        bytes memory d = new bytes(1025);
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.DescriptionTooLong.selector);
        ac.createJob(provider, evaluator, block.timestamp + EXPIRY, string(d), address(0));
    }

    function test_createJob_maxDescriptionAllowed() public {
        bytes memory d = new bytes(1024);
        vm.prank(client);
        assertEq(ac.createJob(provider, evaluator, block.timestamp + EXPIRY, string(d), address(0)), 1);
    }

    function test_createJob_revert_hookNotWhitelisted() public {
        MockHook rogue = new MockHook();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.HookNotWhitelisted.selector);
        ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "x", address(rogue));
    }

    function test_createJob_revert_hookBadInterface() public {
        address bad = address(new MockERC20("X", "X", 18));
        vm.prank(owner);
        ac.setHookWhitelist(bad, true);
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.HookInterfaceNotSupported.selector);
        ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "x", bad);
    }

    // =====================================================================
    //  setProvider
    // =====================================================================

    function test_setProvider() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ProviderSet(id, provider);
        ac.setProvider(id, provider, "");
        assertEq(ac.getJob(id).provider, provider);
    }

    function test_setProvider_revert_notClient() public {
        uint256 id = _openNoProvider();
        vm.prank(rando);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.setProvider(id, provider, "");
    }

    function test_setProvider_revert_alreadySet() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ProviderAlreadySet.selector);
        ac.setProvider(id, makeAddr("p2"), "");
    }

    function test_setProvider_revert_zeroProvider() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.setProvider(id, address(0), "");
    }

    function test_setProvider_revert_notOpen() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.setProvider(id, makeAddr("p2"), "");
    }

    // =====================================================================
    //  setBudget
    // =====================================================================

    function test_setBudget_byClient() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectEmit(true, false, false, true);
        emit IERC8183.BudgetSet(id, BUDGET);
        ac.setBudget(id, BUDGET, "");
        assertEq(ac.getJob(id).budget, BUDGET);
    }

    function test_setBudget_byProvider() public {
        uint256 id = _open();
        vm.prank(provider);
        ac.setBudget(id, BUDGET, "");
        assertEq(ac.getJob(id).budget, BUDGET);
    }

    function test_setBudget_overwrite() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(provider);
        ac.setBudget(id, BUDGET * 2, "");
        assertEq(ac.getJob(id).budget, BUDGET * 2);
    }

    function test_setBudget_revert_unauthorized() public {
        uint256 id = _open();
        vm.prank(rando);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.setBudget(id, BUDGET, "");
    }

    function test_setBudget_revert_notOpen() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.setBudget(id, BUDGET, "");
    }

    // =====================================================================
    //  fund
    // =====================================================================

    function test_fund_transfersAndChangesStatus() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");

        uint256 before = token.balanceOf(client);
        vm.prank(client);
        ac.fund(id, BUDGET, "");

        _assertStatus(id, IERC8183.Status.Funded);
        assertEq(token.balanceOf(address(ac)), BUDGET);
        assertEq(token.balanceOf(client), before - BUDGET);
    }

    function test_fund_emitsEvent() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobFunded(id, client, BUDGET);
        ac.fund(id, BUDGET, "");
    }

    function test_fund_revert_notClient() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(provider);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.fund(id, BUDGET, "");
    }

    function test_fund_revert_notOpen() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.fund(id, BUDGET, "");
    }

    function test_fund_revert_providerNotSet() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ProviderNotSet.selector);
        ac.fund(id, BUDGET, "");
    }

    function test_fund_revert_zeroBudget() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ZeroBudget.selector);
        ac.fund(id, 0, "");
    }

    function test_fund_revert_budgetMismatch() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.BudgetMismatch.selector, BUDGET, BUDGET + 1));
        ac.fund(id, BUDGET + 1, "");
    }

    function test_fund_revert_expired() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.warp(ac.getJob(id).expiredAt);
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.JobAlreadyExpired.selector);
        ac.fund(id, BUDGET, "");
    }

    // =====================================================================
    //  submit
    // =====================================================================

    function test_submit() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobSubmitted(id, provider, DELIVERABLE);
        ac.submit(id, DELIVERABLE, "");

        IERC8183.Job memory j = ac.getJob(id);
        assertEq(uint8(j.status), uint8(IERC8183.Status.Submitted));
        assertEq(j.deliverable, DELIVERABLE);
    }

    function test_submit_revert_notProvider() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.submit(id, DELIVERABLE, "");
    }

    function test_submit_revert_notFunded() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Open));
        ac.submit(id, DELIVERABLE, "");
    }

    function test_submit_revert_alreadySubmitted() public {
        uint256 id = _submitted();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Submitted));
        ac.submit(id, DELIVERABLE, "");
    }

    function test_submit_revert_expired() public {
        uint256 id = _funded();
        vm.warp(ac.getJob(id).expiredAt);
        vm.prank(provider);
        vm.expectRevert(AgenticCommerce.JobAlreadyExpired.selector);
        ac.submit(id, DELIVERABLE, "");
    }

    // =====================================================================
    //  complete
    // =====================================================================

    function test_complete_distributesPayment() public {
        uint256 id = _submitted();
        uint256 pBal = token.balanceOf(provider);
        uint256 tBal = token.balanceOf(treasury);
        uint256 eBal = token.balanceOf(evaluator);

        vm.prank(evaluator);
        ac.complete(id, REASON, "");

        _assertStatus(id, IERC8183.Status.Completed);
        assertEq(token.balanceOf(provider), pBal + BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
        assertEq(token.balanceOf(treasury), tBal + _pFee(BUDGET));
        assertEq(token.balanceOf(evaluator), eBal + _eFee(BUDGET));
        assertEq(token.balanceOf(address(ac)), 0);
    }

    function test_complete_emitsEvents() public {
        uint256 id = _submitted();
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobCompleted(id, evaluator, REASON);
        ac.complete(id, REASON, "");
    }

    function test_complete_zeroFees() public {
        AgenticCommerce ac0 = new AgenticCommerce(address(token), 0, 0, treasury, owner);
        token.mint(client, BUDGET);
        vm.prank(client);
        token.approve(address(ac0), BUDGET);

        vm.prank(client);
        uint256 id = ac0.createJob(provider, evaluator, block.timestamp + EXPIRY, "j", address(0));
        vm.prank(client);
        ac0.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac0.fund(id, BUDGET, "");
        vm.prank(provider);
        ac0.submit(id, DELIVERABLE, "");

        uint256 tBal = token.balanceOf(treasury);
        vm.prank(evaluator);
        ac0.complete(id, REASON, "");

        assertEq(token.balanceOf(provider), BUDGET);
        assertEq(token.balanceOf(treasury), tBal);
    }

    function test_complete_evaluatorIsClient() public {
        vm.prank(client);
        uint256 id = ac.createJob(client, client, block.timestamp + EXPIRY, "j", address(0));
        vm.startPrank(client);
        ac.setBudget(id, BUDGET, "");
        ac.fund(id, BUDGET, "");
        ac.submit(id, DELIVERABLE, "");
        ac.complete(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Completed);
    }

    function test_complete_revert_notEvaluator() public {
        uint256 id = _submitted();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.complete(id, REASON, "");
    }

    function test_complete_revert_notSubmitted() public {
        uint256 id = _funded();
        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.complete(id, REASON, "");
    }

    // =====================================================================
    //  reject
    // =====================================================================

    function test_reject_fromOpen() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobRejected(id, client, REASON);
        ac.reject(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Rejected);
    }

    function test_reject_fromFunded_refunds() public {
        uint256 id = _funded();
        uint256 cBal = token.balanceOf(client);
        vm.prank(evaluator);
        ac.reject(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Rejected);
        assertEq(token.balanceOf(client), cBal + BUDGET);
        assertEq(token.balanceOf(address(ac)), 0);
    }

    function test_reject_fromSubmitted_refunds() public {
        uint256 id = _submitted();
        uint256 cBal = token.balanceOf(client);
        vm.prank(evaluator);
        ac.reject(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Rejected);
        assertEq(token.balanceOf(client), cBal + BUDGET);
    }

    function test_reject_revert_clientCannotRejectFunded() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.reject(id, REASON, "");
    }

    function test_reject_revert_evaluatorCannotRejectOpen() public {
        uint256 id = _open();
        vm.prank(evaluator);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.reject(id, REASON, "");
    }

    function test_reject_revert_providerCannotReject() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.reject(id, REASON, "");
    }

    function test_reject_revert_fromCompleted() public {
        uint256 id = _completed();
        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Completed));
        ac.reject(id, REASON, "");
    }

    function test_reject_revert_fromRejected() public {
        uint256 id = _rejected();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Rejected));
        ac.reject(id, REASON, "");
    }

    function test_reject_revert_fromExpired() public {
        uint256 id = _expired();
        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Expired));
        ac.reject(id, REASON, "");
    }

    // =====================================================================
    //  claimRefund
    // =====================================================================

    function test_claimRefund_fromFunded() public {
        uint256 id = _funded();
        uint256 cBal = token.balanceOf(client);
        vm.warp(block.timestamp + EXPIRY);
        vm.prank(rando);
        ac.claimRefund(id);
        _assertStatus(id, IERC8183.Status.Expired);
        assertEq(token.balanceOf(client), cBal + BUDGET);
    }

    function test_claimRefund_fromSubmitted() public {
        uint256 id = _submitted();
        uint256 cBal = token.balanceOf(client);
        vm.warp(block.timestamp + EXPIRY);
        ac.claimRefund(id);
        _assertStatus(id, IERC8183.Status.Expired);
        assertEq(token.balanceOf(client), cBal + BUDGET);
    }

    function test_claimRefund_emitsEvents() public {
        uint256 id = _funded();
        vm.warp(block.timestamp + EXPIRY);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.Refunded(id, client, BUDGET);
        vm.expectEmit(true, false, false, false);
        emit IERC8183.JobExpired(id);
        ac.claimRefund(id);
    }

    function test_claimRefund_revert_notExpired() public {
        uint256 id = _funded();
        vm.expectRevert(AgenticCommerce.JobNotExpired.selector);
        ac.claimRefund(id);
    }

    function test_claimRefund_revert_fromOpen() public {
        uint256 id = _open();
        vm.warp(block.timestamp + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Open));
        ac.claimRefund(id);
    }

    function test_claimRefund_revert_fromCompleted() public {
        uint256 id = _completed();
        vm.warp(block.timestamp + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Completed));
        ac.claimRefund(id);
    }

    function test_claimRefund_revert_fromRejected() public {
        uint256 id = _rejected();
        vm.warp(block.timestamp + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Rejected));
        ac.claimRefund(id);
    }

    function test_claimRefund_revert_fromExpired() public {
        uint256 id = _expired();
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Expired));
        ac.claimRefund(id);
    }

    // =====================================================================
    //  getJob
    // =====================================================================

    function test_getJob_revert_zeroId() public {
        vm.expectRevert(AgenticCommerce.JobDoesNotExist.selector);
        ac.getJob(0);
    }

    function test_getJob_revert_nonexistent() public {
        vm.expectRevert(AgenticCommerce.JobDoesNotExist.selector);
        ac.getJob(999);
    }

    // =====================================================================
    //  Admin: setPlatformFee / setEvaluatorFee / setTreasury / whitelist
    // =====================================================================

    function test_setPlatformFee() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AgenticCommerce.PlatformFeeUpdated(FEE_BP, 500);
        ac.setPlatformFee(500);
        assertEq(ac.platformFeeBp(), 500);
    }

    function test_setPlatformFee_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(AgenticCommerce.FeeTooHigh.selector);
        ac.setPlatformFee(4901);
    }

    function test_setPlatformFee_revert_notOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        ac.setPlatformFee(100);
    }

    function test_setEvaluatorFee() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AgenticCommerce.EvaluatorFeeUpdated(EVAL_FEE_BP, 200);
        ac.setEvaluatorFee(200);
        assertEq(ac.evaluatorFeeBp(), 200);
    }

    function test_setEvaluatorFee_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(AgenticCommerce.FeeTooHigh.selector);
        ac.setEvaluatorFee(4751);
    }

    function test_setEvaluatorFee_revert_notOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        ac.setEvaluatorFee(100);
    }

    function test_setTreasury() public {
        address t2 = makeAddr("t2");
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AgenticCommerce.TreasuryUpdated(treasury, t2);
        ac.setTreasury(t2);
        assertEq(ac.treasury(), t2);
    }

    function test_setTreasury_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.setTreasury(address(0));
    }

    function test_setTreasury_revert_notOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        ac.setTreasury(makeAddr("x"));
    }

    function test_setHookWhitelist() public {
        address h = makeAddr("h");
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit AgenticCommerce.HookWhitelistUpdated(h, true);
        ac.setHookWhitelist(h, true);
        assertTrue(ac.whitelistedHooks(h));
        ac.setHookWhitelist(h, false);
        assertFalse(ac.whitelistedHooks(h));
        vm.stopPrank();
    }

    function test_setHookWhitelist_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.setHookWhitelist(address(0), true);
    }

    function test_setHookWhitelist_revert_notOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        ac.setHookWhitelist(makeAddr("h"), true);
    }

    // =====================================================================
    //  Fee Snapshot
    // =====================================================================

    function test_feeSnapshot_platformFee() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");

        vm.startPrank(owner);
        ac.setPlatformFee(4900);
        ac.setEvaluatorFee(0);
        vm.stopPrank();

        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        ac.complete(id, REASON, "");

        assertEq(token.balanceOf(treasury), _pFee(BUDGET));
        assertEq(token.balanceOf(evaluator), _eFee(BUDGET));
        assertEq(token.balanceOf(provider), BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
    }

    function test_feeSnapshot_treasury() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");

        address t2 = makeAddr("t2");
        vm.prank(owner);
        ac.setTreasury(t2);

        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        ac.complete(id, REASON, "");

        assertEq(token.balanceOf(treasury), _pFee(BUDGET), "snapshotted treasury receives fee");
        assertEq(token.balanceOf(t2), 0, "new treasury gets nothing");
    }

    function test_feeSnapshot_evaluatorFee() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");

        vm.prank(owner);
        ac.setEvaluatorFee(0);

        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        ac.complete(id, REASON, "");

        assertEq(token.balanceOf(evaluator), _eFee(BUDGET), "uses snapshotted eval fee");
    }

    function test_feeSnapshot_evaluatorFeeEmitsEvent() public {
        uint256 id = _submitted();
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit AgenticCommerce.EvaluatorFeePaid(id, evaluator, _eFee(BUDGET));
        ac.complete(id, REASON, "");
    }

    // =====================================================================
    //  Hooks
    // =====================================================================

    function test_hook_calledOnAllHookableActions() public {
        uint256 id = _openHooked();

        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);
        assertEq(hook.lastSelector(), ac.setBudget.selector);

        vm.prank(client);
        ac.fund(id, BUDGET, "");
        assertEq(hook.lastSelector(), ac.fund.selector);

        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        assertEq(hook.lastSelector(), ac.submit.selector);

        vm.prank(evaluator);
        ac.complete(id, REASON, "");
        assertEq(hook.lastSelector(), ac.complete.selector);

        assertEq(hook.beforeCalls(), 4);
        assertEq(hook.afterCalls(), 4);
    }

    function test_hook_calledOnSetProvider() public {
        vm.prank(client);
        uint256 id = ac.createJob(address(0), evaluator, block.timestamp + EXPIRY, "j", address(hook));
        vm.prank(client);
        ac.setProvider(id, provider, "");
        assertEq(hook.lastSelector(), ac.setProvider.selector);
        assertEq(hook.beforeCalls(), 1);
    }

    function test_hook_calledOnReject() public {
        uint256 id = _openHooked();
        vm.prank(client);
        ac.reject(id, REASON, "");
        assertEq(hook.lastSelector(), ac.reject.selector);
    }

    function test_hook_notCalledOnClaimRefund() public {
        uint256 id = _fundedHooked();
        uint256 calls = hook.beforeCalls();
        vm.warp(block.timestamp + EXPIRY);
        ac.claimRefund(id);
        assertEq(hook.beforeCalls(), calls, "hook must NOT be called on claimRefund");
    }

    function test_hook_beforeRevertBlocksAction() public {
        uint256 id = _openHooked();
        hook.setRevertBefore(true);
        vm.prank(client);
        vm.expectRevert("hook:before");
        ac.setBudget(id, BUDGET, "");
    }

    function test_hook_afterRevertRollsBack() public {
        uint256 id = _fundedHooked();
        hook.setRevertAfter(true);
        vm.prank(provider);
        vm.expectRevert("hook:after");
        ac.submit(id, DELIVERABLE, "");
        _assertStatus(id, IERC8183.Status.Funded, "state rolled back");
    }

    function test_hook_dataEncoding_setBudget() public {
        uint256 id = _openHooked();
        bytes memory params = abi.encode(uint256(42));
        vm.prank(client);
        ac.setBudget(id, BUDGET, params);
        assertEq(keccak256(hook.lastData()), keccak256(abi.encode(BUDGET, params)));
    }

    function test_hook_dataEncoding_fund() public {
        uint256 id = _openHooked();
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        bytes memory params = abi.encode(uint256(99));
        vm.prank(client);
        ac.fund(id, BUDGET, params);
        assertEq(keccak256(hook.lastData()), keccak256(params), "fund passes raw optParams");
    }

    // =====================================================================
    //  Edge cases
    // =====================================================================

    function test_edge_minimumBudgetFeeRounding() public {
        uint256 id = _open();
        vm.prank(client);
        ac.setBudget(id, 1, "");
        vm.prank(client);
        ac.fund(id, 1, "");
        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        ac.complete(id, REASON, "");
        assertEq(token.balanceOf(provider), 1, "provider gets full 1 when fees round to 0");
        assertEq(token.balanceOf(address(ac)), 0);
    }

    function test_edge_evaluatorIsClient_accounting() public {
        vm.prank(client);
        uint256 id = ac.createJob(provider, client, block.timestamp + EXPIRY, "j", address(0));
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");

        uint256 cBal = token.balanceOf(client);
        vm.prank(client);
        ac.fund(id, BUDGET, "");

        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        vm.prank(client);
        ac.complete(id, REASON, "");

        // client paid BUDGET, gets eFee back as evaluator
        assertEq(token.balanceOf(client), cBal - BUDGET + _eFee(BUDGET));
        assertEq(token.balanceOf(provider), BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
        assertEq(token.balanceOf(treasury), _pFee(BUDGET));
    }

    function test_edge_allRolesAreSameAddress() public {
        vm.prank(client);
        uint256 id = ac.createJob(client, client, block.timestamp + EXPIRY, "j", address(0));

        uint256 cBal = token.balanceOf(client);
        vm.startPrank(client);
        ac.setBudget(id, BUDGET, "");
        ac.fund(id, BUDGET, "");
        ac.submit(id, DELIVERABLE, "");
        ac.complete(id, REASON, "");
        vm.stopPrank();

        _assertStatus(id, IERC8183.Status.Completed);
        // client = provider + evaluator: gets back net + eFee = BUDGET - pFee
        assertEq(token.balanceOf(client), cBal - _pFee(BUDGET));
        assertEq(token.balanceOf(treasury), _pFee(BUDGET));
    }

    function test_edge_multipleJobsIsolation() public {
        uint256 j1 = _funded();
        uint256 j2 = _funded();

        vm.prank(provider);
        ac.submit(j1, DELIVERABLE, "");
        vm.prank(evaluator);
        ac.complete(j1, REASON, "");

        _assertStatus(j1, IERC8183.Status.Completed);
        _assertStatus(j2, IERC8183.Status.Funded);
    }

    function test_edge_claimRefundExactlyAtExpiry() public {
        uint256 id = _funded();
        vm.warp(ac.getJob(id).expiredAt);
        ac.claimRefund(id);
        _assertStatus(id, IERC8183.Status.Expired);
    }

    // =====================================================================
    //  Integration: full lifecycle paths
    // =====================================================================

    function test_lifecycle_happyPath() public {
        vm.prank(client);
        uint256 id = ac.createJob(provider, evaluator, block.timestamp + EXPIRY, "j", address(0));
        vm.prank(provider);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");
        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");

        uint256 pBal = token.balanceOf(provider);
        vm.prank(evaluator);
        ac.complete(id, REASON, "");

        _assertStatus(id, IERC8183.Status.Completed);
        assertEq(token.balanceOf(provider), pBal + BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
    }

    function test_lifecycle_lateProvider() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        ac.setProvider(id, provider, "");
        vm.prank(client);
        ac.setBudget(id, BUDGET, "");
        vm.prank(client);
        ac.fund(id, BUDGET, "");
        vm.prank(provider);
        ac.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        ac.complete(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Completed);
    }

    function test_lifecycle_expiry() public {
        uint256 id = _funded();
        uint256 cBal = token.balanceOf(client);
        vm.warp(block.timestamp + EXPIRY);
        vm.prank(rando);
        ac.claimRefund(id);
        _assertStatus(id, IERC8183.Status.Expired);
        assertEq(token.balanceOf(client), cBal + BUDGET);
    }

    function test_lifecycle_rejectFromOpen() public {
        uint256 id = _open();
        vm.prank(client);
        ac.reject(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Rejected);
    }

    function test_lifecycle_rejectFromSubmitted() public {
        uint256 id = _submitted();
        uint256 cBal = token.balanceOf(client);
        vm.prank(evaluator);
        ac.reject(id, REASON, "");
        _assertStatus(id, IERC8183.Status.Rejected);
        assertEq(token.balanceOf(client), cBal + BUDGET);
    }

    // =====================================================================
    //  Fuzz
    // =====================================================================

    function testFuzz_feeDistribution(
        uint256 budget,
        uint256 fee,
        uint256 eFee
    ) public {
        budget = bound(budget, 1, 1_000_000e6);
        fee = bound(fee, 0, 2500);
        eFee = bound(eFee, 0, 2500);

        AgenticCommerce fuzzAc = new AgenticCommerce(address(token), fee, eFee, treasury, owner);
        token.mint(client, budget);
        vm.prank(client);
        token.approve(address(fuzzAc), budget);

        vm.prank(client);
        uint256 id = fuzzAc.createJob(provider, evaluator, block.timestamp + EXPIRY, "f", address(0));
        vm.prank(client);
        fuzzAc.setBudget(id, budget, "");
        vm.prank(client);
        fuzzAc.fund(id, budget, "");
        vm.prank(provider);
        fuzzAc.submit(id, DELIVERABLE, "");

        uint256 pBal = token.balanceOf(provider);
        uint256 tBal = token.balanceOf(treasury);
        uint256 eBal = token.balanceOf(evaluator);

        vm.prank(evaluator);
        fuzzAc.complete(id, REASON, "");

        uint256 expPFee = (budget * fee) / 10_000;
        uint256 expEFee = (budget * eFee) / 10_000;
        assertEq(token.balanceOf(provider), pBal + budget - expPFee - expEFee);
        assertEq(token.balanceOf(treasury), tBal + expPFee);
        assertEq(token.balanceOf(evaluator), eBal + expEFee);
    }
}
