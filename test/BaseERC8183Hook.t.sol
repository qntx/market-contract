// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BaseERC8183Hook} from "../src/BaseERC8183Hook.sol";
import {ERC8183} from "../src/ERC8183.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {IERC8183Hook} from "../src/interfaces/IERC8183Hook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

/// @dev Records which virtual fired and the decoded fields.
contract RecorderHook is BaseERC8183Hook {
    bytes32 public lastPre;
    bytes32 public lastPost;
    uint256 public preCount;
    uint256 public postCount;

    uint256 public jobId;
    address public caller;
    address public token;
    uint256 public amount;
    bytes32 public deliverable;
    bytes32 public reason;
    bytes public optParams;

    constructor(
        address core_
    ) BaseERC8183Hook(core_) {}

    function _markPre(
        bytes32 tag,
        uint256 j,
        address c,
        bytes memory o
    ) internal {
        lastPre = tag;
        preCount++;
        jobId = j;
        caller = c;
        optParams = o;
    }

    function _markPost(
        bytes32 tag,
        uint256 j,
        address c,
        bytes memory o
    ) internal {
        lastPost = tag;
        postCount++;
        jobId = j;
        caller = c;
        optParams = o;
    }

    function _preSetBudget(
        uint256 j,
        address c,
        address t,
        uint256 a,
        bytes memory o
    ) internal override {
        token = t;
        amount = a;
        _markPre("preSetBudget", j, c, o);
    }

    function _postSetBudget(
        uint256 j,
        address c,
        address t,
        uint256 a,
        bytes memory o
    ) internal override {
        token = t;
        amount = a;
        _markPost("postSetBudget", j, c, o);
    }

    function _preFund(
        uint256 j,
        address c,
        bytes memory o
    ) internal override {
        _markPre("preFund", j, c, o);
    }

    function _postFund(
        uint256 j,
        address c,
        bytes memory o
    ) internal override {
        _markPost("postFund", j, c, o);
    }

    function _preSubmit(
        uint256 j,
        address c,
        bytes32 d,
        bytes memory o
    ) internal override {
        deliverable = d;
        _markPre("preSubmit", j, c, o);
    }

    function _postSubmit(
        uint256 j,
        address c,
        bytes32 d,
        bytes memory o
    ) internal override {
        deliverable = d;
        _markPost("postSubmit", j, c, o);
    }

    function _preComplete(
        uint256 j,
        address c,
        bytes32 r,
        bytes memory o
    ) internal override {
        reason = r;
        _markPre("preComplete", j, c, o);
    }

    function _postComplete(
        uint256 j,
        address c,
        bytes32 r,
        bytes memory o
    ) internal override {
        reason = r;
        _markPost("postComplete", j, c, o);
    }

    function _preReject(
        uint256 j,
        address c,
        bytes32 r,
        bytes memory o
    ) internal override {
        reason = r;
        _markPre("preReject", j, c, o);
    }

    function _postReject(
        uint256 j,
        address c,
        bytes32 r,
        bytes memory o
    ) internal override {
        reason = r;
        _markPost("postReject", j, c, o);
    }

    function _preSubmitClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        _markPre("preSubmitClaim", j, c, o);
    }

    function _postSubmitClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        _markPost("postSubmitClaim", j, c, o);
    }

    function _preSettleClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        _markPre("preSettleClaim", j, c, o);
    }

    function _postSettleClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        _markPost("postSettleClaim", j, c, o);
    }

    function _preApproveClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        _markPre("preApproveClaim", j, c, o);
    }

    function _postApproveClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        _markPost("postApproveClaim", j, c, o);
    }

    function _preRejectClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes32 r,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        reason = r;
        _markPre("preRejectClaim", j, c, o);
    }

    function _postRejectClaim(
        uint256 j,
        address c,
        uint256 a,
        bytes32 d,
        bytes32 r,
        bytes memory o
    ) internal override {
        amount = a;
        deliverable = d;
        reason = r;
        _markPost("postRejectClaim", j, c, o);
    }
}

contract BaseERC8183HookTest is Test {
    bytes4 internal constant SEL_SET_BUDGET = IERC8183.setBudget.selector;
    bytes4 internal constant SEL_FUND = IERC8183.fund.selector;
    bytes4 internal constant SEL_SUBMIT = IERC8183.submit.selector;
    bytes4 internal constant SEL_COMPLETE = IERC8183.complete.selector;
    bytes4 internal constant SEL_REJECT = IERC8183.reject.selector;
    bytes4 internal constant SEL_SUBMIT_CLAIM = IERC8183.submitClaim.selector;
    bytes4 internal constant SEL_SETTLE_CLAIM = IERC8183.settleClaim.selector;
    bytes4 internal constant SEL_APPROVE_CLAIM = IERC8183.approveClaim.selector;
    bytes4 internal constant SEL_REJECT_CLAIM = IERC8183.rejectClaim.selector;
    bytes4 internal constant SEL_FUND_FEBRUARY = bytes4(keccak256("fund(uint256,uint256,bytes)"));

    ERC8183 internal core;
    MockERC20 internal token;
    RecorderHook internal hook;
    MockHook internal router;

    address internal owner = makeAddr("owner");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal treasury = makeAddr("treasury");
    address internal rando = makeAddr("rando");

    uint256 internal constant BUDGET = 1000e6;
    uint256 internal constant HALF = 500e6;
    uint256 internal constant FEE_BP = 250;
    uint256 internal constant EVAL_FEE_BP = 100;
    uint256 internal constant EXPIRY = 7 days;

    bytes32 internal constant DELIVERABLE = keccak256("deliverable");
    bytes32 internal constant REASON = keccak256("reason");

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        router = new MockHook();

        vm.startPrank(owner);
        core = new ERC8183(FEE_BP, EVAL_FEE_BP, treasury, owner);
        hook = new RecorderHook(address(core));
        core.setPaymentTokenAllowed(address(token), true);
        core.setHookWhitelist(address(hook), true);
        core.setHookWhitelist(address(router), true);
        vm.stopPrank();

        token.mint(client, 100_000e6);
        vm.prank(client);
        token.approve(address(core), type(uint256).max);
    }

    function _expiry() internal view returns (uint48) {
        return uint48(block.timestamp + EXPIRY);
    }

    function _openHooked() internal returns (uint256) {
        vm.prank(client);
        return core.createJob(provider, evaluator, _expiry(), "j", address(hook), 0);
    }

    function _openRouted() internal returns (uint256) {
        vm.prank(client);
        return core.createJob(provider, evaluator, _expiry(), "j", address(router), 0);
    }

    function _fundedHooked() internal returns (uint256 id) {
        id = _openHooked();
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
    }

    function _asCore() internal {
        vm.startPrank(address(core));
    }

    // =====================================================================
    //  Selectors
    // =====================================================================

    function test_baseHook_fundSelector_isCanonical() public pure {
        assertEq(SEL_FUND, IERC8183.fund.selector);
        assertEq(SEL_FUND, bytes4(0x1f989ec8));
        assertEq(SEL_FUND, bytes4(keccak256("fund(uint256,address,uint256,bytes)")));
        assertTrue(SEL_FUND != SEL_FUND_FEBRUARY);
        assertEq(SEL_FUND_FEBRUARY, bytes4(0xd2e13f50));
        assertEq(SEL_SET_BUDGET, IERC8183.setBudget.selector);
        assertEq(SEL_SUBMIT, IERC8183.submit.selector);
        assertEq(SEL_COMPLETE, IERC8183.complete.selector);
        assertEq(SEL_REJECT, IERC8183.reject.selector);
        assertEq(SEL_SUBMIT_CLAIM, IERC8183.submitClaim.selector);
        assertEq(SEL_SETTLE_CLAIM, IERC8183.settleClaim.selector);
        assertEq(SEL_APPROVE_CLAIM, IERC8183.approveClaim.selector);
        assertEq(SEL_REJECT_CLAIM, IERC8183.rejectClaim.selector);
        assertEq(SEL_SET_BUDGET, bytes4(keccak256("setBudget(uint256,address,uint256,bytes)")));
        assertEq(SEL_SUBMIT, bytes4(keccak256("submit(uint256,bytes32,bytes)")));
        assertEq(SEL_COMPLETE, bytes4(keccak256("complete(uint256,bytes32,bytes)")));
        assertEq(SEL_REJECT, bytes4(keccak256("reject(uint256,bytes32,bytes)")));
        assertEq(SEL_SUBMIT_CLAIM, bytes4(keccak256("submitClaim(uint256,uint256,bytes32,bytes)")));
        assertEq(SEL_SETTLE_CLAIM, bytes4(keccak256("settleClaim(uint256,uint256,bytes32,bytes)")));
        assertEq(SEL_APPROVE_CLAIM, bytes4(keccak256("approveClaim(uint256,uint256,bytes32,bytes)")));
        assertEq(SEL_REJECT_CLAIM, bytes4(keccak256("rejectClaim(uint256,uint256,bytes32,bytes32,bytes)")));
    }

    // =====================================================================
    //  Constructor / ERC-165
    // =====================================================================

    function test_constructor_setsErc8183Contract() public view {
        assertEq(hook.erc8183Contract(), address(core));
    }

    function test_constructor_revert_zeroAddress() public {
        vm.expectRevert(BaseERC8183Hook.ZeroAddress.selector);
        new RecorderHook(address(0));
    }

    function test_supportsInterface() public view {
        assertTrue(hook.supportsInterface(type(IERC8183Hook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertEq(type(IERC8183Hook).interfaceId, bytes4(0x7ff6bc9e));
        assertFalse(hook.supportsInterface(0xdeadbeef));
        assertFalse(hook.supportsInterface(type(IERC8183).interfaceId));
    }

    // =====================================================================
    //  onlyERC8183
    // =====================================================================

    function test_beforeAction_allowsKernel() public {
        _asCore();
        hook.beforeAction(1, SEL_FUND, abi.encode(client, hex"aa"));
        vm.stopPrank();
        assertEq(hook.lastPre(), "preFund");
        assertEq(hook.caller(), client);
    }

    function test_afterAction_allowsKernel() public {
        _asCore();
        hook.afterAction(1, SEL_FUND, abi.encode(client, hex"aa"));
        vm.stopPrank();
        assertEq(hook.lastPost(), "postFund");
    }

    function test_beforeAction_revert_notAuthorized() public {
        uint256 id = _openRouted();
        vm.prank(rando);
        vm.expectRevert(BaseERC8183Hook.OnlyERC8183Contract.selector);
        hook.beforeAction(id, SEL_FUND, abi.encode(client, hex""));
    }

    function test_afterAction_revert_notAuthorized() public {
        uint256 id = _openRouted();
        vm.prank(rando);
        vm.expectRevert(BaseERC8183Hook.OnlyERC8183Contract.selector);
        hook.afterAction(id, SEL_FUND, abi.encode(client, hex""));
    }

    function test_baseHook_onlyERC8183_allowsJobHook() public {
        uint256 id = _openRouted();
        bytes memory data = abi.encode(client, hex"bb");

        vm.prank(address(router));
        hook.beforeAction(id, SEL_FUND, data);
        assertEq(hook.lastPre(), "preFund");
        assertEq(hook.jobId(), id);
        assertEq(hook.caller(), client);

        vm.prank(address(router));
        hook.afterAction(id, SEL_FUND, data);
        assertEq(hook.lastPost(), "postFund");
    }

    function test_beforeAction_revert_bogusJobId() public {
        vm.prank(rando);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        hook.beforeAction(999, SEL_FUND, abi.encode(client, hex""));
    }

    function test_afterAction_revert_bogusJobId() public {
        vm.prank(address(router));
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        hook.afterAction(0, SEL_FUND, abi.encode(client, hex""));
    }

    // =====================================================================
    //  Lifecycle virtuals
    // =====================================================================

    function test_setBudget_virtuals() public {
        bytes memory opt = hex"cafe";
        bytes memory data = abi.encode(provider, address(token), BUDGET, opt);
        _asCore();
        hook.beforeAction(7, SEL_SET_BUDGET, data);
        assertEq(hook.lastPre(), "preSetBudget");
        assertEq(hook.jobId(), 7);
        assertEq(hook.caller(), provider);
        assertEq(hook.token(), address(token));
        assertEq(hook.amount(), BUDGET);
        assertEq(hook.optParams(), opt);

        hook.afterAction(7, SEL_SET_BUDGET, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postSetBudget");
        assertEq(hook.caller(), provider);
        assertEq(hook.token(), address(token));
        assertEq(hook.amount(), BUDGET);
    }

    function test_fund_virtuals() public {
        bytes memory opt = hex"11";
        bytes memory data = abi.encode(client, opt);
        _asCore();
        hook.beforeAction(3, SEL_FUND, data);
        assertEq(hook.lastPre(), "preFund");
        assertEq(hook.jobId(), 3);
        assertEq(hook.caller(), client);
        assertEq(hook.optParams(), opt);

        hook.afterAction(3, SEL_FUND, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postFund");
    }

    function test_submit_virtuals() public {
        bytes memory opt = hex"22";
        bytes memory data = abi.encode(provider, DELIVERABLE, opt);
        _asCore();
        hook.beforeAction(5, SEL_SUBMIT, data);
        assertEq(hook.lastPre(), "preSubmit");
        assertEq(hook.caller(), provider);
        assertEq(hook.deliverable(), DELIVERABLE);
        assertEq(hook.optParams(), opt);

        hook.afterAction(5, SEL_SUBMIT, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postSubmit");
        assertEq(hook.deliverable(), DELIVERABLE);
    }

    function test_complete_virtuals() public {
        bytes memory opt = hex"33";
        bytes memory data = abi.encode(evaluator, REASON, opt);
        _asCore();
        hook.beforeAction(9, SEL_COMPLETE, data);
        assertEq(hook.lastPre(), "preComplete");
        assertEq(hook.caller(), evaluator);
        assertEq(hook.reason(), REASON);

        hook.afterAction(9, SEL_COMPLETE, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postComplete");
        assertEq(hook.reason(), REASON);
    }

    function test_reject_virtuals() public {
        bytes memory opt = hex"44";
        bytes memory data = abi.encode(evaluator, REASON, opt);
        _asCore();
        hook.beforeAction(11, SEL_REJECT, data);
        assertEq(hook.lastPre(), "preReject");
        assertEq(hook.caller(), evaluator);
        assertEq(hook.reason(), REASON);

        hook.afterAction(11, SEL_REJECT, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postReject");
    }

    // =====================================================================
    //  Claim virtuals
    // =====================================================================

    function test_submitClaim_virtuals() public {
        bytes memory opt = hex"55";
        bytes memory data = abi.encode(provider, HALF, DELIVERABLE, opt);
        _asCore();
        hook.beforeAction(2, SEL_SUBMIT_CLAIM, data);
        assertEq(hook.lastPre(), "preSubmitClaim");
        assertEq(hook.caller(), provider);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);
        assertEq(hook.optParams(), opt);

        hook.afterAction(2, SEL_SUBMIT_CLAIM, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postSubmitClaim");
    }

    function test_settleClaim_virtuals() public {
        bytes memory opt = hex"66";
        bytes memory data = abi.encode(client, HALF, DELIVERABLE, opt);
        _asCore();
        hook.beforeAction(2, SEL_SETTLE_CLAIM, data);
        assertEq(hook.lastPre(), "preSettleClaim");
        assertEq(hook.caller(), client);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);

        hook.afterAction(2, SEL_SETTLE_CLAIM, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postSettleClaim");
    }

    function test_approveClaim_virtuals() public {
        bytes memory opt = hex"77";
        bytes memory data = abi.encode(evaluator, HALF, DELIVERABLE, opt);
        _asCore();
        hook.beforeAction(2, SEL_APPROVE_CLAIM, data);
        assertEq(hook.lastPre(), "preApproveClaim");
        assertEq(hook.caller(), evaluator);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);

        hook.afterAction(2, SEL_APPROVE_CLAIM, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postApproveClaim");
    }

    function test_rejectClaim_virtuals_includeReason() public {
        bytes memory opt = hex"88";
        bytes32 claimReason = keccak256("nope");
        bytes memory data = abi.encode(client, HALF, DELIVERABLE, claimReason, opt);
        _asCore();
        hook.beforeAction(2, SEL_REJECT_CLAIM, data);
        assertEq(hook.lastPre(), "preRejectClaim");
        assertEq(hook.caller(), client);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);
        assertEq(hook.reason(), claimReason);
        assertEq(hook.optParams(), opt);

        hook.afterAction(2, SEL_REJECT_CLAIM, data);
        vm.stopPrank();
        assertEq(hook.lastPost(), "postRejectClaim");
        assertEq(hook.reason(), claimReason);
    }

    // =====================================================================
    //  Unknown selector → no-op (including February fund)
    // =====================================================================

    function test_before_unknownSelector_noOp() public {
        _asCore();
        hook.beforeAction(1, bytes4(0xdeadbeef), "");
        vm.stopPrank();
        assertEq(hook.lastPre(), bytes32(0));
        assertEq(hook.preCount(), 0);
    }

    function test_after_unknownSelector_noOp() public {
        _asCore();
        hook.afterAction(1, bytes4(0xdeadbeef), "");
        vm.stopPrank();
        assertEq(hook.lastPost(), bytes32(0));
        assertEq(hook.postCount(), 0);
    }

    function test_before_februaryFundSelector_noOp() public {
        _asCore();
        hook.beforeAction(1, SEL_FUND_FEBRUARY, abi.encode(client, hex"aa"));
        vm.stopPrank();
        assertEq(hook.lastPre(), bytes32(0));
        assertEq(hook.preCount(), 0);
    }

    // =====================================================================
    //  Kernel integration
    // =====================================================================

    function test_kernel_lifecycle_virtuals() public {
        uint256 id = _openHooked();

        bytes memory optBudget = hex"01";
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, optBudget);
        assertEq(hook.lastPre(), "preSetBudget");
        assertEq(hook.lastPost(), "postSetBudget");
        assertEq(hook.jobId(), id);
        assertEq(hook.caller(), provider);
        assertEq(hook.token(), address(token));
        assertEq(hook.amount(), BUDGET);
        assertEq(hook.optParams(), optBudget);
        assertEq(hook.preCount(), 1);
        assertEq(hook.postCount(), 1);

        bytes memory optFund = hex"02";
        vm.prank(client);
        core.fund(id, address(token), BUDGET, optFund);
        assertEq(hook.lastPre(), "preFund");
        assertEq(hook.lastPost(), "postFund");
        assertEq(hook.caller(), client);
        assertEq(hook.optParams(), optFund);

        bytes memory optSubmit = hex"03";
        vm.prank(provider);
        core.submit(id, DELIVERABLE, optSubmit);
        assertEq(hook.lastPre(), "preSubmit");
        assertEq(hook.lastPost(), "postSubmit");
        assertEq(hook.caller(), provider);
        assertEq(hook.deliverable(), DELIVERABLE);

        bytes memory optComplete = hex"04";
        vm.prank(evaluator);
        core.complete(id, REASON, optComplete);
        assertEq(hook.lastPre(), "preComplete");
        assertEq(hook.lastPost(), "postComplete");
        assertEq(hook.caller(), evaluator);
        assertEq(hook.reason(), REASON);
        assertEq(hook.preCount(), 4);
        assertEq(hook.postCount(), 4);
    }

    function test_kernel_reject_virtuals() public {
        uint256 id = _openHooked();
        vm.prank(provider);
        core.reject(id, REASON, hex"09");
        assertEq(hook.lastPre(), "preReject");
        assertEq(hook.lastPost(), "postReject");
        assertEq(hook.caller(), provider);
        assertEq(hook.reason(), REASON);
    }

    function test_kernel_claim_virtuals_includingRejectClaimReason() public {
        uint256 id = _fundedHooked();
        bytes memory opt = hex"ab";

        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, opt);
        assertEq(hook.lastPre(), "preSubmitClaim");
        assertEq(hook.lastPost(), "postSubmitClaim");
        assertEq(hook.caller(), provider);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);
        assertEq(hook.optParams(), opt);

        vm.prank(client);
        core.rejectClaim(id, HALF, DELIVERABLE, REASON, opt);
        assertEq(hook.lastPre(), "preRejectClaim");
        assertEq(hook.lastPost(), "postRejectClaim");
        assertEq(hook.caller(), client);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);
        assertEq(hook.reason(), REASON);
        assertEq(hook.optParams(), opt);
    }

    function test_kernel_settleClaim_and_approveClaim_virtuals() public {
        uint256 id = _fundedHooked();

        vm.prank(client);
        core.settleClaim(id, 100e6, DELIVERABLE, hex"c1");
        assertEq(hook.lastPre(), "preSettleClaim");
        assertEq(hook.lastPost(), "postSettleClaim");
        assertEq(hook.caller(), client);
        assertEq(hook.amount(), 100e6);

        vm.prank(provider);
        core.submitClaim(id, HALF, DELIVERABLE, hex"c2");
        assertEq(hook.lastPost(), "postSubmitClaim");

        vm.prank(evaluator);
        core.approveClaim(id, HALF, DELIVERABLE, hex"c2");
        assertEq(hook.lastPre(), "preApproveClaim");
        assertEq(hook.lastPost(), "postApproveClaim");
        assertEq(hook.caller(), evaluator);
        assertEq(hook.amount(), HALF);
        assertEq(hook.deliverable(), DELIVERABLE);
        assertEq(hook.optParams(), hex"c2");
    }
}
