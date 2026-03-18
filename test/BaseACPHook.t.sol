// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseACPHook} from "../src/BaseACPHook.sol";
import {IACPHook} from "../src/interfaces/IACPHook.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AgenticCommerce} from "../src/AgenticCommerce.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Concrete hook that records which virtual function was called and with what args.
contract ConcreteHook is BaseACPHook {
    bytes32 public route;
    uint256 public jobId;
    address public decodedAddr;
    uint256 public decodedAmount;
    bytes32 public decodedHash;
    bytes public decodedOpt;

    constructor(
        address acp_
    ) BaseACPHook(acp_) {}

    function _preSetProvider(
        uint256 j,
        address p,
        bytes memory o
    ) internal override {
        route = "preSetProvider";
        jobId = j;
        decodedAddr = p;
        decodedOpt = o;
    }

    function _postSetProvider(
        uint256 j,
        address p,
        bytes memory o
    ) internal override {
        route = "postSetProvider";
        jobId = j;
        decodedAddr = p;
        decodedOpt = o;
    }

    function _preSetBudget(
        uint256 j,
        uint256 a,
        bytes memory o
    ) internal override {
        route = "preSetBudget";
        jobId = j;
        decodedAmount = a;
        decodedOpt = o;
    }

    function _postSetBudget(
        uint256 j,
        uint256 a,
        bytes memory o
    ) internal override {
        route = "postSetBudget";
        jobId = j;
        decodedAmount = a;
        decodedOpt = o;
    }

    function _preFund(
        uint256 j,
        bytes memory o
    ) internal override {
        route = "preFund";
        jobId = j;
        decodedOpt = o;
    }

    function _postFund(
        uint256 j,
        bytes memory o
    ) internal override {
        route = "postFund";
        jobId = j;
        decodedOpt = o;
    }

    function _preSubmit(
        uint256 j,
        bytes32 d,
        bytes memory o
    ) internal override {
        route = "preSubmit";
        jobId = j;
        decodedHash = d;
        decodedOpt = o;
    }

    function _postSubmit(
        uint256 j,
        bytes32 d,
        bytes memory o
    ) internal override {
        route = "postSubmit";
        jobId = j;
        decodedHash = d;
        decodedOpt = o;
    }

    function _preComplete(
        uint256 j,
        bytes32 r,
        bytes memory o
    ) internal override {
        route = "preComplete";
        jobId = j;
        decodedHash = r;
        decodedOpt = o;
    }

    function _postComplete(
        uint256 j,
        bytes32 r,
        bytes memory o
    ) internal override {
        route = "postComplete";
        jobId = j;
        decodedHash = r;
        decodedOpt = o;
    }

    function _preReject(
        uint256 j,
        bytes32 r,
        bytes memory o
    ) internal override {
        route = "preReject";
        jobId = j;
        decodedHash = r;
        decodedOpt = o;
    }

    function _postReject(
        uint256 j,
        bytes32 r,
        bytes memory o
    ) internal override {
        route = "postReject";
        jobId = j;
        decodedHash = r;
        decodedOpt = o;
    }

    /// @dev Expose _getJob for testing.
    function getJobFromAcp(
        uint256 jid
    ) external view returns (IERC8183.Job memory) {
        return _getJob(jid);
    }
}

contract BaseACPHookTest is Test {
    ConcreteHook hook;
    address acp = makeAddr("acp");

    bytes4 constant SEL_SET_PROVIDER = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 constant SEL_SET_BUDGET = bytes4(keccak256("setBudget(uint256,uint256,bytes)"));
    bytes4 constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 constant SEL_COMPLETE = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 constant SEL_REJECT = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    function setUp() public {
        hook = new ConcreteHook(acp);
    }

    // =====================================================================
    //  Constructor
    // =====================================================================

    function test_constructor_setsAcp() public view {
        assertEq(hook.ACP(), acp);
    }

    function test_constructor_revert_zeroAddress() public {
        vm.expectRevert(BaseACPHook.ZeroAddress.selector);
        new ConcreteHook(address(0));
    }

    // =====================================================================
    //  supportsInterface
    // =====================================================================

    function test_supportsInterface() public view {
        assertTrue(hook.supportsInterface(type(IACPHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0xdeadbeef));
    }

    // =====================================================================
    //  onlyAcp
    // =====================================================================

    function test_beforeAction_revert_notAcp() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(BaseACPHook.OnlyAcp.selector);
        hook.beforeAction(1, SEL_FUND, "");
    }

    function test_afterAction_revert_notAcp() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(BaseACPHook.OnlyAcp.selector);
        hook.afterAction(1, SEL_FUND, "");
    }

    // =====================================================================
    //  beforeAction routing + data decoding
    // =====================================================================

    function test_before_setProvider() public {
        address p = makeAddr("p");
        bytes memory opt = hex"cafe";

        vm.prank(acp);
        hook.beforeAction(42, SEL_SET_PROVIDER, abi.encode(p, opt));

        assertEq(hook.route(), "preSetProvider");
        assertEq(hook.jobId(), 42);
        assertEq(hook.decodedAddr(), p);
        assertEq(hook.decodedOpt(), opt);
    }

    function test_before_setBudget() public {
        vm.prank(acp);
        hook.beforeAction(7, SEL_SET_BUDGET, abi.encode(uint256(1000), hex"beef"));

        assertEq(hook.route(), "preSetBudget");
        assertEq(hook.jobId(), 7);
        assertEq(hook.decodedAmount(), 1000);
    }

    function test_before_fund() public {
        bytes memory rawOpt = hex"1234";
        vm.prank(acp);
        hook.beforeAction(3, SEL_FUND, rawOpt);

        assertEq(hook.route(), "preFund");
        assertEq(hook.jobId(), 3);
        assertEq(hook.decodedOpt(), rawOpt);
    }

    function test_before_submit() public {
        bytes32 d = keccak256("work");
        vm.prank(acp);
        hook.beforeAction(5, SEL_SUBMIT, abi.encode(d, hex"aa"));

        assertEq(hook.route(), "preSubmit");
        assertEq(hook.decodedHash(), d);
    }

    function test_before_complete() public {
        bytes32 r = keccak256("good");
        vm.prank(acp);
        hook.beforeAction(9, SEL_COMPLETE, abi.encode(r, hex"bb"));

        assertEq(hook.route(), "preComplete");
        assertEq(hook.decodedHash(), r);
    }

    function test_before_reject() public {
        bytes32 r = keccak256("bad");
        vm.prank(acp);
        hook.beforeAction(11, SEL_REJECT, abi.encode(r, hex"cc"));

        assertEq(hook.route(), "preReject");
        assertEq(hook.decodedHash(), r);
    }

    // =====================================================================
    //  afterAction routing + data decoding
    // =====================================================================

    function test_after_setProvider() public {
        address p = makeAddr("p");
        vm.prank(acp);
        hook.afterAction(42, SEL_SET_PROVIDER, abi.encode(p, hex""));

        assertEq(hook.route(), "postSetProvider");
        assertEq(hook.decodedAddr(), p);
    }

    function test_after_setBudget() public {
        vm.prank(acp);
        hook.afterAction(1, SEL_SET_BUDGET, abi.encode(uint256(500), hex""));

        assertEq(hook.route(), "postSetBudget");
        assertEq(hook.decodedAmount(), 500);
    }

    function test_after_fund() public {
        vm.prank(acp);
        hook.afterAction(1, SEL_FUND, hex"abcd");
        assertEq(hook.route(), "postFund");
    }

    function test_after_submit() public {
        bytes32 d = keccak256("x");
        vm.prank(acp);
        hook.afterAction(1, SEL_SUBMIT, abi.encode(d, hex""));
        assertEq(hook.route(), "postSubmit");
        assertEq(hook.decodedHash(), d);
    }

    function test_after_complete() public {
        bytes32 r = keccak256("y");
        vm.prank(acp);
        hook.afterAction(1, SEL_COMPLETE, abi.encode(r, hex""));
        assertEq(hook.route(), "postComplete");
        assertEq(hook.decodedHash(), r);
    }

    function test_after_reject() public {
        bytes32 r = keccak256("z");
        vm.prank(acp);
        hook.afterAction(1, SEL_REJECT, abi.encode(r, hex""));
        assertEq(hook.route(), "postReject");
        assertEq(hook.decodedHash(), r);
    }

    // =====================================================================
    //  Unknown selector → silent no-op
    // =====================================================================

    function test_before_unknownSelector_noOp() public {
        vm.prank(acp);
        hook.beforeAction(1, bytes4(0xdeadbeef), "");
        assertEq(hook.route(), bytes32(0), "no route should be set");
    }

    function test_after_unknownSelector_noOp() public {
        vm.prank(acp);
        hook.afterAction(1, bytes4(0xdeadbeef), "");
        assertEq(hook.route(), bytes32(0));
    }

    // =====================================================================
    //  _getJob integration
    // =====================================================================

    function test_getJob_readsFromAcp() public {
        MockERC20 tkn = new MockERC20("T", "T", 6);
        address owner_ = makeAddr("owner");
        address client_ = makeAddr("client");

        AgenticCommerce realAc = new AgenticCommerce(address(tkn), 0, 0, makeAddr("treasury"), owner_);
        ConcreteHook realHook = new ConcreteHook(address(realAc));

        vm.prank(client_);
        uint256 jid = realAc.createJob(makeAddr("prov"), makeAddr("eval"), block.timestamp + 7 days, "test", address(0));

        IERC8183.Job memory j = realHook.getJobFromAcp(jid);
        assertEq(j.client, client_);
        assertEq(j.id, jid);
    }

    // =====================================================================
    //  Selector correctness (guards against typos in keccak constants)
    // =====================================================================

    function test_selectorConstants_matchInterface() public view {
        assertEq(SEL_SET_PROVIDER, AgenticCommerce.setProvider.selector);
        assertEq(SEL_SET_BUDGET, AgenticCommerce.setBudget.selector);
        assertEq(SEL_FUND, AgenticCommerce.fund.selector);
        assertEq(SEL_SUBMIT, AgenticCommerce.submit.selector);
        assertEq(SEL_COMPLETE, AgenticCommerce.complete.selector);
        assertEq(SEL_REJECT, AgenticCommerce.reject.selector);
    }
}
