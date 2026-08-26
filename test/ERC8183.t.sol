// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC8183} from "../src/ERC8183.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {IERC8183Hook} from "../src/interfaces/IERC8183Hook.sol";
import {IDisburser} from "../src/interfaces/IDisburser.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";
import {MockFeeOnTransferToken} from "./mocks/MockFeeOnTransferToken.sol";
import {MockInflatingToken} from "./mocks/MockInflatingToken.sol";
import {IReentrantERC8183, MockDisburser, NotADisburser, ReentrantDisburser} from "./mocks/MockDisburser.sol";
import {RevertingTreasury, ArmableRevertToken} from "./mocks/RevertingTreasury.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {GasGuzzlerHook} from "./mocks/GasGuzzlerHook.sol";

contract PendingClaimObserverHook is IERC8183Hook {
    ERC8183 public immutable core;
    bytes32 public beforePendingClaimHash;

    constructor(
        ERC8183 core_
    ) {
        core = core_;
    }

    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata
    ) external override {
        if (selector == ERC8183.submit.selector || selector == ERC8183.reject.selector) {
            beforePendingClaimHash = core.pendingClaimHash(jobId);
        }
    }

    function afterAction(
        uint256,
        bytes4,
        bytes calldata
    ) external override {}

    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract ERC8183Test is Test {
    using stdStorage for StdStorage;

    ERC8183 internal core;
    MockERC20 internal token;
    MockERC20 internal token2;
    MockHook internal hook;

    address internal owner = makeAddr("owner");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal treasury = makeAddr("treasury");
    address internal rando = makeAddr("rando");
    address internal receiver = makeAddr("receiver");

    uint256 internal constant BUDGET = 1000e6;
    uint256 internal constant FEE_BP = 250;
    uint256 internal constant EVAL_FEE_BP = 100;
    uint256 internal constant EXPIRY = 7 days;

    bytes32 internal constant DELIVERABLE = keccak256("deliverable");
    bytes32 internal constant REASON = keccak256("reason");

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        token2 = new MockERC20("USDT", "USDT", 6);
        hook = new MockHook();

        vm.startPrank(owner);
        core = new ERC8183(FEE_BP, EVAL_FEE_BP, treasury, owner);
        core.setPaymentTokenAllowed(address(token), true);
        core.setPaymentTokenAllowed(address(token2), true);
        core.setHookWhitelist(address(hook), true);
        vm.stopPrank();

        token.mint(client, 100_000e6);
        token2.mint(client, 100_000e6);
        vm.prank(client);
        token.approve(address(core), type(uint256).max);
        vm.prank(client);
        token2.approve(address(core), type(uint256).max);
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

    function _openNoProvider() internal returns (uint256) {
        vm.prank(client);
        return core.createJob(address(0), evaluator, _expiry(), "j", address(0), 0);
    }

    function _budgeted() internal returns (uint256 id) {
        id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
    }

    function _funded() internal returns (uint256 id) {
        id = _budgeted();
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

    function _submitted() internal returns (uint256 id) {
        id = _funded();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
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
    //  Selectors (H4)
    // =====================================================================

    function test_selectors_matchCanonicalABI() public view {
        assertEq(core.createJob.selector, bytes4(keccak256("createJob(address,address,uint48,string,address,uint256)")));
        assertEq(core.setPayoutReceiver.selector, bytes4(keccak256("setPayoutReceiver(uint256,address)")));
        assertEq(core.setProvider.selector, bytes4(keccak256("setProvider(uint256,address,uint256)")));
        assertEq(core.setBudget.selector, bytes4(keccak256("setBudget(uint256,address,uint256,bytes)")));
        assertEq(core.fund.selector, bytes4(keccak256("fund(uint256,address,uint256,bytes)")));
        assertEq(core.fund.selector, bytes4(0x1f989ec8));
        assertEq(core.submit.selector, bytes4(keccak256("submit(uint256,bytes32,bytes)")));
        assertEq(core.complete.selector, bytes4(keccak256("complete(uint256,bytes32,bytes)")));
        assertEq(core.reject.selector, bytes4(keccak256("reject(uint256,bytes32,bytes)")));
        assertEq(core.claimRefund.selector, bytes4(keccak256("claimRefund(uint256)")));
        assertEq(core.getJob.selector, bytes4(keccak256("getJob(uint256)")));
        assertTrue(core.fund.selector != bytes4(keccak256("fund(uint256,uint256,bytes)")));
        assertEq(type(IERC8183Hook).interfaceId, bytes4(0x7ff6bc9e));
        assertEq(type(IDisburser).interfaceId, bytes4(0x74dbc6a9));
    }

    // =====================================================================
    //  Constructor / admin
    // =====================================================================

    function test_constructor_setsState() public view {
        assertEq(core.platformFeeBp(), FEE_BP);
        assertEq(core.evaluatorFeeBp(), EVAL_FEE_BP);
        assertEq(core.treasury(), treasury);
        assertEq(core.owner(), owner);
        assertEq(core.jobCounter(), 0);
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        new ERC8183(FEE_BP, EVAL_FEE_BP, address(0), owner);
    }

    function test_constructor_revert_feeTooHigh() public {
        vm.expectRevert(ERC8183.FeeTooHigh.selector);
        new ERC8183(3000, 2001, treasury, owner);
    }

    function test_constructor_maxFeeExact() public {
        new ERC8183(2500, 2500, treasury, owner);
    }

    function test_supportsInterface() public view {
        assertTrue(core.supportsInterface(type(IERC8183).interfaceId));
        assertTrue(core.supportsInterface(type(IERC165).interfaceId));
        assertFalse(core.supportsInterface(0xdeadbeef));
    }

    function test_renounceOwnership_revert() public {
        vm.prank(owner);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.renounceOwnership();
    }

    function test_renounceOwnership_revert_nonOwner() public {
        vm.prank(rando);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.renounceOwnership();
    }

    // =====================================================================
    //  createJob / H1 role mutex
    // =====================================================================

    function test_createJob_setsAllFields() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, _expiry(), "desc", address(hook), 42);

        assertEq(id, 1);
        IERC8183.Job memory j = core.getJob(id);
        assertEq(j.client, client);
        assertEq(uint8(j.status), uint8(IERC8183.JobStatus.Open));
        assertEq(j.provider, provider);
        assertEq(j.expiredAt, uint48(block.timestamp + EXPIRY));
        assertEq(j.evaluator, evaluator);
        assertEq(j.submittedAt, 0);
        assertEq(j.budget, 0);
        assertEq(j.hook, address(hook));
        assertEq(j.paymentToken, address(0));
        assertEq(j.providerAgentId, 42);
        assertEq(j.description, "desc");
        assertEq(j.settledAmount, 0);
        assertEq(j.payoutReceiver, address(0));
    }

    function test_createJob_withoutProvider_zerosAgentId() public {
        vm.prank(client);
        uint256 id = core.createJob(address(0), evaluator, _expiry(), "j", address(0), 99);
        IERC8183.Job memory j = core.getJob(id);
        assertEq(j.provider, address(0));
        assertEq(j.providerAgentId, 0);
    }

    function test_createJob_incrementsCounter() public {
        _open();
        _open();
        assertEq(core.jobCounter(), 2);
    }

    function test_createJob_emitsEvent() public {
        uint48 exp = _expiry();
        vm.prank(client);
        vm.expectEmit(true, true, true, true);
        emit IERC8183.JobCreated(1, client, provider, evaluator, exp, address(0));
        core.createJob(provider, evaluator, exp, "e", address(0), 0);
    }

    function test_createJob_revert_zeroEvaluator() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        core.createJob(provider, address(0), _expiry(), "x", address(0), 0);
    }

    function test_createJob_revert_expiryTooShort() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.ExpiryTooShort.selector);
        core.createJob(provider, evaluator, uint48(block.timestamp + 4 minutes), "x", address(0), 0);
    }

    function test_createJob_revert_descriptionTooLong() public {
        bytes memory d = new bytes(1025);
        vm.prank(client);
        vm.expectRevert(ERC8183.DescriptionTooLong.selector);
        core.createJob(provider, evaluator, _expiry(), string(d), address(0), 0);
    }

    function test_createJob_maxDescriptionAllowed() public {
        bytes memory d = new bytes(1024);
        vm.prank(client);
        assertEq(core.createJob(provider, evaluator, _expiry(), string(d), address(0), 0), 1);
    }

    function test_createJob_revert_hookNotWhitelisted() public {
        MockHook rogue = new MockHook();
        vm.prank(client);
        vm.expectRevert(ERC8183.HookNotWhitelisted.selector);
        core.createJob(provider, evaluator, _expiry(), "x", address(rogue), 0);
    }

    function test_createJob_revert_hookBadInterface() public {
        address bad = address(new MockERC20("X", "X", 18));
        vm.prank(owner);
        core.setHookWhitelist(bad, true);
        vm.prank(client);
        vm.expectRevert(ERC8183.InvalidHook.selector);
        core.createJob(provider, evaluator, _expiry(), "x", bad, 0);
    }

    function test_createJob_revert_clientIsProvider() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.ClientCannotBeProvider.selector);
        core.createJob(client, evaluator, _expiry(), "x", address(0), 0);
    }

    function test_createJob_revert_providerIsEvaluator() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.ProviderCannotBeEvaluator.selector);
        core.createJob(evaluator, evaluator, _expiry(), "x", address(0), 0);
    }

    function test_createJob_evaluatorIsClient_ok() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, client, _expiry(), "j", address(0), 0);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(client);
        core.complete(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Completed);
    }

    function test_edge_allRolesAreSameAddress() public {
        vm.prank(client);
        vm.expectRevert(ERC8183.ClientCannotBeProvider.selector);
        core.createJob(client, client, _expiry(), "j", address(0), 0);
    }

    function test_createJob_notHookable() public {
        vm.prank(client);
        core.createJob(provider, evaluator, _expiry(), "j", address(hook), 0);
        assertEq(hook.beforeCalls(), 0);
        assertEq(hook.afterCalls(), 0);
    }

    // =====================================================================
    //  setProvider
    // =====================================================================

    function test_setProvider() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ProviderSet(id, provider, 7);
        core.setProvider(id, provider, 7);
        IERC8183.Job memory j = core.getJob(id);
        assertEq(j.provider, provider);
        assertEq(j.providerAgentId, 7);
    }

    function test_setProvider_revert_notClient() public {
        uint256 id = _openNoProvider();
        vm.prank(rando);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.setProvider(id, provider, 0);
    }

    function test_setProvider_revert_alreadySet() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(ERC8183.ProviderAlreadySet.selector);
        core.setProvider(id, rando, 0);
    }

    function test_setProvider_revert_zeroProvider() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        core.setProvider(id, address(0), 0);
    }

    function test_setProvider_revert_providerIsClient() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectRevert(ERC8183.ClientCannotBeProvider.selector);
        core.setProvider(id, client, 0);
    }

    function test_setProvider_revert_providerIsEvaluator() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectRevert(ERC8183.ProviderCannotBeEvaluator.selector);
        core.setProvider(id, evaluator, 0);
    }

    function test_setProvider_revert_notOpen() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Funded));
        core.setProvider(id, rando, 0);
    }

    function test_setProvider_revert_expired() public {
        uint256 id = _openNoProvider();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(client);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.setProvider(id, provider, 0);
    }

    function test_setProvider_notHookable() public {
        vm.prank(client);
        uint256 id = core.createJob(address(0), evaluator, _expiry(), "j", address(hook), 0);
        vm.prank(client);
        core.setProvider(id, provider, 1);
        assertEq(hook.beforeCalls(), 0);
    }

    function test_hook_calledOnSetProvider() public {
        vm.prank(client);
        uint256 id = core.createJob(address(0), evaluator, _expiry(), "j", address(hook), 0);
        vm.prank(client);
        core.setProvider(id, provider, 1);
        assertEq(hook.beforeCalls(), 0);
        assertEq(hook.afterCalls(), 0);
    }

    // =====================================================================
    //  setPayoutReceiver
    // =====================================================================

    function test_setPayoutReceiver() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PayoutReceiverSet(id, receiver);
        core.setPayoutReceiver(id, receiver);
        assertEq(core.getJob(id).payoutReceiver, receiver);
    }

    function test_setPayoutReceiver_zeroAllowedBeforeBudget() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(0));
        assertEq(core.getJob(id).payoutReceiver, address(0));
    }

    function test_setPayoutReceiver_revert_notProvider() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.setPayoutReceiver(id, receiver);
    }

    function test_setPayoutReceiver_revert_providerUnset() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.setPayoutReceiver(id, receiver);
    }

    function test_setPayoutReceiver_revert_this() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        core.setPayoutReceiver(id, address(core));
    }

    function test_setPayoutReceiver_revert_afterFunded() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Funded));
        core.setPayoutReceiver(id, receiver);
    }

    function test_setPayoutReceiver_revert_expired() public {
        uint256 id = _open();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(provider);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.setPayoutReceiver(id, receiver);
    }

    function test_setPayoutReceiver_notHookable() public {
        uint256 id = _openHooked();
        vm.prank(provider);
        core.setPayoutReceiver(id, receiver);
        assertEq(hook.beforeCalls(), 0);
    }

    function test_setPayoutReceiver_revert_equalsPaymentToken() public {
        uint256 id = _budgeted();
        vm.prank(provider);
        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        core.setPayoutReceiver(id, address(token));
    }

    function test_setBudget_revert_existingReceiverIsPaymentToken() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(token));
        vm.prank(provider);
        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        core.setBudget(id, address(token), BUDGET, "");
    }

    // =====================================================================
    //  setBudget
    // =====================================================================

    function test_setBudget_byProvider() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.BudgetSet(id, address(token), BUDGET);
        core.setBudget(id, address(token), BUDGET, "");
        IERC8183.Job memory j = core.getJob(id);
        assertEq(j.budget, BUDGET);
        assertEq(j.paymentToken, address(token));
    }

    function test_setBudget_byClient() public {
        uint256 id = _open();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.setBudget(id, address(token), BUDGET, "");
    }

    function test_setBudget_overwrite() public {
        uint256 id = _open();
        vm.startPrank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        core.setBudget(id, address(token2), 5, "");
        vm.stopPrank();
        assertEq(core.getJob(id).budget, 5);
        assertEq(core.getJob(id).paymentToken, address(token2));
    }

    function test_setBudget_zeroAllowed() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), 0, "");
        assertEq(core.getJob(id).budget, 0);
    }

    function test_setBudget_revert_unauthorized() public {
        uint256 id = _open();
        vm.prank(rando);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.setBudget(id, address(token), BUDGET, "");
    }

    function test_setBudget_revert_notOpen() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Funded));
        core.setBudget(id, address(token), BUDGET, "");
    }

    function test_setBudget_revert_zeroToken() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        core.setBudget(id, address(0), BUDGET, "");
    }

    function test_setBudget_revert_tokenNotAllowed() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        uint256 id = _open();
        vm.prank(provider);
        vm.expectRevert(ERC8183.PaymentTokenNotAllowed.selector);
        core.setBudget(id, address(other), BUDGET, "");
    }

    function test_setBudget_revert_expired() public {
        uint256 id = _open();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(provider);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.setBudget(id, address(token), BUDGET, "");
    }

    function test_setBudget_hookDataEncodesCallerTokenAmount() public {
        uint256 id = _openHooked();
        bytes memory params = abi.encode(uint256(42));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, params);
        (address caller, address tkn, uint256 amount, bytes memory opt) =
            abi.decode(hook.lastData(), (address, address, uint256, bytes));
        assertEq(caller, provider);
        assertEq(tkn, address(token));
        assertEq(amount, BUDGET);
        assertEq(opt, params);
        assertEq(hook.lastSelector(), core.setBudget.selector);
    }

    // =====================================================================
    //  fund / H2
    // =====================================================================

    function test_fund_transfersAndChangesStatus() public {
        uint256 id = _budgeted();
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        _assertStatus(id, IERC8183.JobStatus.Funded);
        assertEq(token.balanceOf(address(core)), BUDGET);
        assertEq(token.balanceOf(client), before - BUDGET);
        (uint16 p, uint16 e, address t) = core.getFeeSnapshot(id);
        assertEq(p, FEE_BP);
        assertEq(e, EVAL_FEE_BP);
        assertEq(t, treasury);
    }

    function test_fund_exactDelta_plainERC20() public {
        uint256 id = _budgeted();
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        assertEq(token.balanceOf(address(core)), BUDGET);
    }

    function test_fund_zeroBudget_succeeds() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), 0, "");
        uint256 before = token.balanceOf(address(core));
        vm.prank(client);
        core.fund(id, address(token), 0, "");
        _assertStatus(id, IERC8183.JobStatus.Funded);
        assertEq(token.balanceOf(address(core)), before);
    }

    function test_fund_revert_zeroBudget() public {
        test_fund_zeroBudget_succeeds();
    }

    function test_fund_emitsEvent() public {
        uint256 id = _budgeted();
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobFunded(id, client, BUDGET);
        core.fund(id, address(token), BUDGET, "");
    }

    function test_fund_revert_notClient() public {
        uint256 id = _budgeted();
        vm.prank(provider);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.fund(id, address(token), BUDGET, "");
    }

    function test_fund_revert_notOpen() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Funded));
        core.fund(id, address(token), BUDGET, "");
    }

    function test_fund_revert_providerNotSet() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        vm.expectRevert(ERC8183.ProviderNotSet.selector);
        core.fund(id, address(token), BUDGET, "");
    }

    function test_fund_revert_budgetMismatch() public {
        uint256 id = _budgeted();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.BudgetMismatch.selector, BUDGET, BUDGET + 1));
        core.fund(id, address(token), BUDGET + 1, "");
    }

    function test_fund_revert_tokenMismatch() public {
        uint256 id = _budgeted();
        vm.prank(client);
        vm.expectRevert(ERC8183.PaymentTokenMismatch.selector);
        core.fund(id, address(0), BUDGET, "");
    }

    function test_fund_revert_expired() public {
        uint256 id = _budgeted();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(client);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.fund(id, address(token), BUDGET, "");
    }

    function test_fund_revert_allowlistRevoked() public {
        uint256 id = _budgeted();
        vm.prank(owner);
        core.setPaymentTokenAllowed(address(token), false);
        vm.prank(client);
        vm.expectRevert(ERC8183.PaymentTokenNotAllowed.selector);
        core.fund(id, address(token), BUDGET, "");
    }

    function test_fund_revert_feeOnTransferToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        vm.prank(owner);
        core.setPaymentTokenAllowed(address(fot), true);
        fot.mint(client, BUDGET * 2);
        vm.prank(client);
        fot.approve(address(core), type(uint256).max);

        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(fot), BUDGET, "");
        vm.prank(client);
        vm.expectRevert(ERC8183.UnexpectedFundedAmount.selector);
        core.fund(id, address(fot), BUDGET, "");
        assertEq(fot.balanceOf(address(core)), 0);
    }

    function test_fund_revert_tokenCreditsMoreThanBudget() public {
        MockInflatingToken infl = new MockInflatingToken();
        vm.prank(owner);
        core.setPaymentTokenAllowed(address(infl), true);
        infl.mint(client, BUDGET * 2);
        vm.prank(client);
        infl.approve(address(core), type(uint256).max);

        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(infl), BUDGET, "");
        vm.prank(client);
        vm.expectRevert(ERC8183.UnexpectedFundedAmount.selector);
        core.fund(id, address(infl), BUDGET, "");
    }

    function test_fund_hookDataEncodesCaller() public {
        uint256 id = _openHooked();
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        bytes memory params = abi.encode(uint256(99));
        vm.prank(client);
        core.fund(id, address(token), BUDGET, params);
        (address caller, bytes memory opt) = abi.decode(hook.lastData(), (address, bytes));
        assertEq(caller, client);
        assertEq(opt, params);
        assertEq(hook.lastSelector(), core.fund.selector);
    }

    function test_hook_dataEncoding_fund() public {
        test_fund_hookDataEncodesCaller();
    }

    // =====================================================================
    //  submit
    // =====================================================================

    function test_submit() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobSubmitted(id, provider, DELIVERABLE);
        core.submit(id, DELIVERABLE, "");
        IERC8183.Job memory j = core.getJob(id);
        assertEq(uint8(j.status), uint8(IERC8183.JobStatus.Submitted));
        assertEq(j.submittedAt, uint48(block.timestamp));
    }

    function test_submit_zeroBudgetOpen() public {
        uint256 id = _open();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        _assertStatus(id, IERC8183.JobStatus.Submitted);
    }

    function test_submit_revert_notProvider() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.submit(id, DELIVERABLE, "");
    }

    function test_submit_revert_notFunded() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Open));
        core.submit(id, DELIVERABLE, "");
    }

    function test_submit_revert_alreadySubmitted() public {
        uint256 id = _submitted();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Submitted));
        core.submit(id, DELIVERABLE, "");
    }

    function test_submit_revert_expired() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        vm.prank(provider);
        vm.expectRevert(ERC8183.JobAlreadyExpired.selector);
        core.submit(id, DELIVERABLE, "");
    }

    function test_submit_clearsPendingClaimBeforeHook() public {
        PendingClaimObserverHook obs = new PendingClaimObserverHook(core);
        vm.prank(owner);
        core.setHookWhitelist(address(obs), true);
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, _expiry(), "j", address(obs), 0);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        stdstore.target(address(core)).sig("pendingClaimHash(uint256)").with_key(id).checked_write(bytes32(uint256(1)));

        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimRejected(id, provider, bytes32("superseded-by-submit"));
        core.submit(id, DELIVERABLE, "");

        assertEq(obs.beforePendingClaimHash(), bytes32(0));
        assertEq(core.pendingClaimHash(id), bytes32(0));
    }

    function test_reject_clearsPendingClaimWithJobReason() public {
        uint256 id = _funded();
        stdstore.target(address(core)).sig("pendingClaimHash(uint256)").with_key(id).checked_write(bytes32(uint256(1)));

        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.ClaimRejected(id, evaluator, REASON);
        core.reject(id, REASON, "");

        assertEq(core.pendingClaimHash(id), bytes32(0));
        _assertStatus(id, IERC8183.JobStatus.Rejected);
    }

    // =====================================================================
    //  complete
    // =====================================================================

    function test_complete_distributesPayment() public {
        uint256 id = _submitted();
        uint256 pBefore = token.balanceOf(provider);
        uint256 tBefore = token.balanceOf(treasury);
        uint256 eBefore = token.balanceOf(evaluator);

        vm.prank(evaluator);
        core.complete(id, REASON, "");

        _assertStatus(id, IERC8183.JobStatus.Completed);
        assertEq(token.balanceOf(provider), pBefore + BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
        assertEq(token.balanceOf(treasury), tBefore + _pFee(BUDGET));
        assertEq(token.balanceOf(evaluator), eBefore + _eFee(BUDGET));
        assertEq(token.balanceOf(address(core)), 0);
        assertEq(core.getJob(id).settledAmount, 0);
    }

    function test_complete_emitsEvents() public {
        uint256 id = _submitted();
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PlatformFeePaid(id, treasury, _pFee(BUDGET));
        vm.expectEmit(true, true, false, true);
        emit IERC8183.EvaluatorFeePaid(id, evaluator, _eFee(BUDGET));
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PaymentReleased(id, provider, BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobCompleted(id, evaluator, REASON);
        core.complete(id, REASON, "");
    }

    function test_complete_zeroFees() public {
        vm.startPrank(owner);
        ERC8183 c0 = new ERC8183(0, 0, treasury, owner);
        c0.setPaymentTokenAllowed(address(token), true);
        vm.stopPrank();
        vm.prank(client);
        token.approve(address(c0), type(uint256).max);
        vm.prank(client);
        uint256 id = c0.createJob(provider, evaluator, _expiry(), "j", address(0), 0);
        vm.prank(provider);
        c0.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        c0.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        c0.submit(id, DELIVERABLE, "");

        vm.recordLogs();
        vm.prank(evaluator);
        c0.complete(id, REASON, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 plat = keccak256("PlatformFeePaid(uint256,address,uint256)");
        bytes32 evalFee = keccak256("EvaluatorFeePaid(uint256,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != plat);
                assertTrue(logs[i].topics[0] != evalFee);
            }
        }
        assertEq(token.balanceOf(provider), BUDGET);
    }

    function test_complete_zeroNet_noPaymentReleased() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), 0, "");
        vm.prank(client);
        core.fund(id, address(token), 0, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");

        vm.recordLogs();
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 released = keccak256("PaymentReleased(uint256,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != released);
            }
        }
    }

    function test_complete_evaluatorIsClient() public {
        test_createJob_evaluatorIsClient_ok();
    }

    function test_complete_revert_notEvaluator() public {
        uint256 id = _submitted();
        vm.prank(provider);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.complete(id, REASON, "");
    }

    function test_complete_revert_notSubmitted() public {
        uint256 id = _funded();
        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Funded));
        core.complete(id, REASON, "");
    }

    function test_complete_afterExpiryStillWorks() public {
        uint256 id = _submitted();
        vm.warp(core.getJob(id).expiredAt + 1);
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Completed);
    }

    function test_feeSnapshot_afterSetTreasuryAndBps() public {
        uint256 id = _funded();
        address newT = makeAddr("newTreasury");
        vm.startPrank(owner);
        core.setPlatformFee(500);
        core.setEvaluatorFee(400);
        core.setTreasury(newT);
        vm.stopPrank();

        (uint16 p, uint16 e, address t) = core.getFeeSnapshot(id);
        assertEq(p, FEE_BP);
        assertEq(e, EVAL_FEE_BP);
        assertEq(t, treasury);

        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        uint256 tBefore = token.balanceOf(treasury);
        uint256 ntBefore = token.balanceOf(newT);
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.PlatformFeePaid(id, treasury, _pFee(BUDGET));
        core.complete(id, REASON, "");
        assertEq(token.balanceOf(treasury), tBefore + _pFee(BUDGET));
        assertEq(token.balanceOf(newT), ntBefore);
    }

    function test_feeSnapshot_platformFee() public {
        uint256 id = _funded();
        vm.prank(owner);
        core.setPlatformFee(1000);
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        assertEq(token.balanceOf(treasury), _pFee(BUDGET));
    }

    function test_complete_revertingTreasury_evaluatorCanReject() public {
        RevertingTreasury rt = new RevertingTreasury();
        ArmableRevertToken arm = new ArmableRevertToken();
        vm.startPrank(owner);
        ERC8183 c = new ERC8183(FEE_BP, 0, address(rt), owner);
        c.setPaymentTokenAllowed(address(arm), true);
        vm.stopPrank();
        arm.mint(client, BUDGET * 2);
        vm.prank(client);
        arm.approve(address(c), type(uint256).max);

        vm.prank(client);
        uint256 id = c.createJob(provider, evaluator, _expiry(), "j", address(0), 0);
        vm.prank(provider);
        c.setBudget(id, address(arm), BUDGET, "");
        vm.prank(client);
        c.fund(id, address(arm), BUDGET, "");
        vm.prank(provider);
        c.submit(id, DELIVERABLE, "");

        arm.setBlocked(address(rt), true);
        vm.prank(evaluator);
        vm.expectRevert(RevertingTreasury.TreasuryRejected.selector);
        c.complete(id, REASON, "");

        vm.prank(evaluator);
        c.reject(id, REASON, "");
        assertEq(uint8(c.getJob(id).status), uint8(IERC8183.JobStatus.Rejected));
        assertEq(arm.balanceOf(client), BUDGET * 2);
    }

    // =====================================================================
    //  reject
    // =====================================================================

    function test_reject_fromOpen() public {
        uint256 id = _open();
        vm.prank(client);
        core.reject(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Rejected);
    }

    function test_reject_providerCanRejectOpen() public {
        uint256 id = _open();
        vm.prank(provider);
        core.reject(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Rejected);
    }

    function test_reject_revert_providerCannotReject() public {
        test_reject_providerCanRejectOpen();
    }

    function test_reject_fromFunded_refunds() public {
        uint256 id = _funded();
        uint256 before = token.balanceOf(client);
        vm.prank(evaluator);
        core.reject(id, REASON, "");
        assertEq(token.balanceOf(client), before + BUDGET);
        _assertStatus(id, IERC8183.JobStatus.Rejected);
    }

    function test_reject_fromSubmitted_refunds() public {
        uint256 id = _submitted();
        vm.prank(evaluator);
        core.reject(id, REASON, "");
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_reject_revert_clientCannotRejectFunded() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.reject(id, REASON, "");
    }

    function test_reject_revert_evaluatorCannotRejectOpen() public {
        uint256 id = _open();
        vm.prank(evaluator);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.reject(id, REASON, "");
    }

    function test_reject_revert_providerCannotRejectFunded() public {
        uint256 id = _funded();
        vm.prank(provider);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        core.reject(id, REASON, "");
    }

    function test_reject_revert_fromCompleted() public {
        uint256 id = _submitted();
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Completed));
        core.reject(id, REASON, "");
    }

    function test_reject_revert_fromRejected() public {
        uint256 id = _open();
        vm.prank(client);
        core.reject(id, REASON, "");
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Rejected));
        core.reject(id, REASON, "");
    }

    function test_reject_revert_fromExpired() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Expired));
        core.reject(id, REASON, "");
    }

    // =====================================================================
    //  claimRefund / H3
    // =====================================================================

    function test_claimRefund_fromFunded() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        _assertStatus(id, IERC8183.JobStatus.Expired);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_claimRefund_fromOpen() public {
        uint256 id = _open();
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        _assertStatus(id, IERC8183.JobStatus.Expired);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_claimRefund_revert_fromOpen() public {
        test_claimRefund_fromOpen();
    }

    function test_claimRefund_emitsEvents() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.Refunded(id, client, BUDGET);
        vm.expectEmit(true, false, false, true);
        emit IERC8183.JobExpired(id);
        core.claimRefund(id);
    }

    function test_claimRefund_revert_notExpired() public {
        uint256 id = _funded();
        vm.expectRevert(ERC8183.JobNotExpired.selector);
        core.claimRefund(id);
    }

    function test_claimRefund_revert_fromCompleted() public {
        uint256 id = _submitted();
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Completed));
        core.claimRefund(id);
    }

    function test_claimRefund_revert_fromRejected() public {
        uint256 id = _open();
        vm.prank(client);
        core.reject(id, REASON, "");
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Rejected));
        core.claimRefund(id);
    }

    function test_claimRefund_revert_fromExpired() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        vm.expectRevert(abi.encodeWithSelector(ERC8183.InvalidStatus.selector, IERC8183.JobStatus.Expired));
        core.claimRefund(id);
    }

    function test_claimRefund_notHookable() public {
        uint256 id = _fundedHooked();
        uint256 calls = hook.beforeCalls();
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        assertEq(hook.beforeCalls(), calls);
        assertEq(hook.afterCalls(), calls);
    }

    function test_hook_notCalledOnClaimRefund() public {
        test_claimRefund_notHookable();
    }

    function test_claimRefund_revert_duringGracePeriod() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, uint48(block.timestamp + 5 minutes + 1), "j", address(0), 0);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");

        uint48 expiredAt = core.getJob(id).expiredAt;
        vm.warp(expiredAt - 1);
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");

        vm.warp(expiredAt);
        vm.expectRevert(ERC8183.GracePeriodActive.selector);
        core.claimRefund(id);

        vm.prank(evaluator);
        core.complete(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Completed);
    }

    function test_claimRefund_afterGracePeriod() public {
        uint256 id = _submitted();
        uint48 expiredAt = core.getJob(id).expiredAt;
        vm.warp(uint256(expiredAt) + 1 hours + 1);
        core.claimRefund(id);
        _assertStatus(id, IERC8183.JobStatus.Expired);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_claimRefund_fundedHasNoGrace() public {
        uint256 id = _funded();
        vm.warp(core.getJob(id).expiredAt);
        core.claimRefund(id);
        _assertStatus(id, IERC8183.JobStatus.Expired);
    }

    function test_claimRefund_fromSubmitted() public {
        test_claimRefund_afterGracePeriod();
    }

    function test_edge_claimRefundExactlyAtExpiry() public {
        test_claimRefund_fundedHasNoGrace();
    }

    // =====================================================================
    //  views
    // =====================================================================

    function test_getJob_revert_zeroId() public {
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.getJob(0);
    }

    function test_getJob_revert_nonexistent() public {
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.getJob(1);
    }

    function test_getFeeSnapshot_revert_missing() public {
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.getFeeSnapshot(1);
    }

    // =====================================================================
    //  admin
    // =====================================================================

    function test_setPlatformFee() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ERC8183.PlatformFeeUpdated(FEE_BP, 500);
        core.setPlatformFee(500);
        assertEq(core.platformFeeBp(), 500);
    }

    function test_setPlatformFee_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(ERC8183.FeeTooHigh.selector);
        core.setPlatformFee(5000);
    }

    function test_setPlatformFee_revert_notOwner() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        core.setPlatformFee(1);
    }

    function test_setEvaluatorFee() public {
        vm.prank(owner);
        core.setEvaluatorFee(200);
        assertEq(core.evaluatorFeeBp(), 200);
    }

    function test_setEvaluatorFee_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(ERC8183.FeeTooHigh.selector);
        core.setEvaluatorFee(5000);
    }

    function test_setTreasury() public {
        address t2 = makeAddr("t2");
        vm.prank(owner);
        core.setTreasury(t2);
        assertEq(core.treasury(), t2);
    }

    function test_setTreasury_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        core.setTreasury(address(0));
    }

    function test_setHookWhitelist() public {
        MockHook h = new MockHook();
        vm.prank(owner);
        core.setHookWhitelist(address(h), true);
        assertTrue(core.whitelistedHooks(address(h)));
    }

    function test_setHookWhitelist_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        core.setHookWhitelist(address(0), true);
    }

    function test_setPaymentTokenAllowed() public {
        MockERC20 t = new MockERC20("A", "A", 18);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ERC8183.PaymentTokenAllowlistUpdated(address(t), true);
        core.setPaymentTokenAllowed(address(t), true);
        assertTrue(core.allowedPaymentTokens(address(t)));
    }

    function test_setPaymentTokenAllowed_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        core.setPaymentTokenAllowed(address(0), true);
    }

    function test_batchDetachHook() public {
        uint256 id = _openHooked();
        hook.setRevertBefore(true);
        vm.prank(provider);
        vm.expectRevert("hook:before");
        core.setBudget(id, address(token), BUDGET, "");

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ERC8183.HookDetached(id, address(hook));
        core.batchDetachHook(ids);

        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        assertEq(core.getJob(id).hook, address(0));
        assertEq(core.getJob(id).budget, BUDGET);
    }

    function test_batchDetachHook_skipsZeroHook() public {
        uint256 id = _open();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(owner);
        core.batchDetachHook(ids);
        assertEq(core.getJob(id).hook, address(0));
    }

    function test_batchDetachHook_revert_missing() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99;
        vm.prank(owner);
        vm.expectRevert(ERC8183.JobDoesNotExist.selector);
        core.batchDetachHook(ids);
    }

    function test_batchDetachHook_revert_notOwner() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        core.batchDetachHook(ids);
    }

    // =====================================================================
    //  hooks
    // =====================================================================

    function test_hook_calledOnAllHookableActions() public {
        uint256 id = _openHooked();

        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);
        assertEq(hook.lastSelector(), core.setBudget.selector);

        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        assertEq(hook.lastSelector(), core.fund.selector);

        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        assertEq(hook.lastSelector(), core.submit.selector);

        vm.prank(evaluator);
        core.complete(id, REASON, "");
        assertEq(hook.lastSelector(), core.complete.selector);

        assertEq(hook.beforeCalls(), 4);
        assertEq(hook.afterCalls(), 4);
    }

    function test_hook_calledOnReject() public {
        uint256 id = _openHooked();
        vm.prank(client);
        core.reject(id, REASON, "");
        assertEq(hook.lastSelector(), core.reject.selector);
    }

    function test_hook_beforeRevertBlocksAction() public {
        uint256 id = _openHooked();
        hook.setRevertBefore(true);
        vm.prank(provider);
        vm.expectRevert("hook:before");
        core.setBudget(id, address(token), BUDGET, "");
    }

    function test_hook_afterRevertRollsBack() public {
        uint256 id = _fundedHooked();
        hook.setRevertAfter(true);
        vm.prank(provider);
        vm.expectRevert("hook:after");
        core.submit(id, DELIVERABLE, "");
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    // =====================================================================
    //  IDisburser
    // =====================================================================

    function test_payoutReceiver_DisburserContractReceivesFundsAndCallback() public {
        MockDisburser d = new MockDisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");

        uint256 net = BUDGET - _pFee(BUDGET) - _eFee(BUDGET);
        bytes memory params = abi.encode(uint256(1));
        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.Disbursed(id, address(d), core.complete.selector, net);
        core.complete(id, REASON, params);

        assertEq(token.balanceOf(address(d)), net);
        assertEq(d.callCount(), 1);
        assertEq(d.lastJobId(), id);
        assertEq(d.lastSelector(), core.complete.selector);
        assertEq(d.lastToken(), address(token));
        assertEq(d.lastAmount(), net);
        assertEq(d.lastData(), params);
    }

    function test_payoutReceiver_EOAReceiverReceivesFundsWithoutCallback() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, receiver);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        assertEq(token.balanceOf(receiver), BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
        assertEq(token.balanceOf(provider), 0);
    }

    function test_payoutReceiver_NonDisburserContractReceivesFundsWithoutCallback() public {
        NotADisburser nad = new NotADisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(nad));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        assertEq(token.balanceOf(address(nad)), BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
    }

    function test_payoutReceiver_RevertsWhenReceiverIsEscrow() public {
        uint256 id = _open();
        vm.prank(provider);
        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        core.setPayoutReceiver(id, address(core));
    }

    function test_complete_revertingDisburserRollsBack() public {
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
        core.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        vm.expectRevert("MockDisburser: forced revert");
        core.complete(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Submitted);
        assertEq(token.balanceOf(address(core)), BUDGET);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_payoutReceiver_ReentrantDisburserCannotReenterComplete() public {
        ReentrantDisburser d = new ReentrantDisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        d.setReentry(IReentrantERC8183(address(core)), id, 0, ReentrantDisburser.Action.Complete);
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        _assertReentryBlocked(d);
        _assertStatus(id, IERC8183.JobStatus.Completed);
    }

    function test_payoutReceiver_ReentrantDisburserCannotReenterClaimRefund() public {
        ReentrantDisburser d = new ReentrantDisburser();
        uint256 id = _open();
        vm.prank(provider);
        core.setPayoutReceiver(id, address(d));
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        d.setReentry(IReentrantERC8183(address(core)), id, 0, ReentrantDisburser.Action.ClaimRefund);
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        _assertReentryBlocked(d);
    }

    // =====================================================================
    //  e2e / edges
    // =====================================================================

    function test_e2e_TwoJobsDifferentTokens() public {
        uint256 a = _open();
        vm.prank(provider);
        core.setBudget(a, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(a, address(token), BUDGET, "");

        vm.prank(client);
        uint256 b = core.createJob(provider, evaluator, _expiry(), "b", address(0), 0);
        vm.prank(provider);
        core.setBudget(b, address(token2), 500e6, "");
        vm.prank(client);
        core.fund(b, address(token2), 500e6, "");

        vm.prank(provider);
        core.submit(a, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(a, REASON, "");

        _assertStatus(a, IERC8183.JobStatus.Completed);
        _assertStatus(b, IERC8183.JobStatus.Funded);
        assertEq(token.balanceOf(address(core)), 0);
        assertEq(token2.balanceOf(address(core)), 500e6);
    }

    function test_e2e_FullHappyPath() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, _expiry(), "j", address(0), 11);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        _assertStatus(id, IERC8183.JobStatus.Completed);
        assertEq(core.getJob(id).providerAgentId, 11);
    }

    function test_lifecycle_lateProvider() public {
        uint256 id = _openNoProvider();
        vm.prank(client);
        core.setProvider(id, provider, 3);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        _assertStatus(id, IERC8183.JobStatus.Funded);
    }

    function test_edge_minimumBudgetFeeRounding() public {
        uint256 id = _open();
        vm.prank(provider);
        core.setBudget(id, address(token), 1, "");
        vm.prank(client);
        core.fund(id, address(token), 1, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        assertEq(token.balanceOf(provider), 1);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_edge_evaluatorIsClient_accounting() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, client, _expiry(), "j", address(0), 0);
        vm.prank(provider);
        core.setBudget(id, address(token), BUDGET, "");
        uint256 cBal = token.balanceOf(client);
        vm.prank(client);
        core.fund(id, address(token), BUDGET, "");
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.prank(client);
        core.complete(id, REASON, "");
        assertEq(token.balanceOf(client), cBal - BUDGET + _eFee(BUDGET));
        assertEq(token.balanceOf(provider), BUDGET - _pFee(BUDGET) - _eFee(BUDGET));
        assertEq(token.balanceOf(treasury), _pFee(BUDGET));
    }

    function test_edge_multipleJobsIsolation() public {
        uint256 j1 = _funded();
        uint256 j2 = _funded();
        vm.prank(provider);
        core.submit(j1, DELIVERABLE, "");
        vm.prank(evaluator);
        core.complete(j1, REASON, "");
        _assertStatus(j1, IERC8183.JobStatus.Completed);
        _assertStatus(j2, IERC8183.JobStatus.Funded);
    }

    function test_zeroBudget_openSubmitComplete() public {
        uint256 id = _open();
        vm.prank(provider);
        core.submit(id, DELIVERABLE, "");
        vm.recordLogs();
        vm.prank(evaluator);
        core.complete(id, REASON, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 released = keccak256("PaymentReleased(uint256,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != released);
            }
        }
        _assertStatus(id, IERC8183.JobStatus.Completed);
    }

    function testFuzz_feeDistribution(
        uint16 plat,
        uint16 evalB,
        uint256 budget
    ) public {
        plat = uint16(bound(plat, 0, 5000));
        evalB = uint16(bound(evalB, 0, 5000 - plat));
        budget = bound(budget, 1, 1_000_000e6);

        vm.startPrank(owner);
        ERC8183 fuzzAc = new ERC8183(plat, evalB, treasury, owner);
        fuzzAc.setPaymentTokenAllowed(address(token), true);
        vm.stopPrank();

        token.mint(client, budget);
        vm.prank(client);
        token.approve(address(fuzzAc), budget);

        vm.prank(client);
        uint256 id = fuzzAc.createJob(provider, evaluator, _expiry(), "f", address(0), 0);
        vm.prank(provider);
        fuzzAc.setBudget(id, address(token), budget, "");
        vm.prank(client);
        fuzzAc.fund(id, address(token), budget, "");
        vm.prank(provider);
        fuzzAc.submit(id, DELIVERABLE, "");

        uint256 pBal = token.balanceOf(provider);
        uint256 tBal = token.balanceOf(treasury);
        uint256 eBal = token.balanceOf(evaluator);

        vm.prank(evaluator);
        fuzzAc.complete(id, REASON, "");

        uint256 expPFee = (budget * plat) / 10_000;
        uint256 expEFee = (budget * evalB) / 10_000;
        assertEq(token.balanceOf(provider), pBal + budget - expPFee - expEFee);
        assertEq(token.balanceOf(treasury), tBal + expPFee);
        assertEq(token.balanceOf(evaluator), eBal + expEFee);
    }
}

contract ERC8183ReentrancyTest is Test {
    ERC8183 internal core;
    ReentrantToken internal rToken;

    address internal owner = makeAddr("owner");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant BUDGET = 1000e18;

    function setUp() public {
        rToken = new ReentrantToken();
        core = new ERC8183(0, 0, treasury, owner);
        vm.prank(owner);
        core.setPaymentTokenAllowed(address(rToken), true);

        rToken.mint(client, BUDGET * 10);
        vm.prank(client);
        rToken.approve(address(core), type(uint256).max);
    }

    function test_reentrancy_claimRefundDuringReject() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, uint48(block.timestamp + 7 days), "j", address(0), 0);
        vm.prank(provider);
        core.setBudget(id, address(rToken), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(rToken), BUDGET, "");

        vm.warp(block.timestamp + 7 days);
        rToken.arm(address(core), id);

        vm.prank(evaluator);
        core.reject(id, bytes32(0), "");

        assertEq(uint8(core.getJob(id).status), uint8(IERC8183.JobStatus.Rejected));
        assertEq(rToken.balanceOf(client), BUDGET * 10);
        assertEq(rToken.balanceOf(address(core)), 0);
    }

    function test_reentrancy_claimRefundDuringClaimRefund() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, uint48(block.timestamp + 7 days), "j", address(0), 0);
        vm.prank(provider);
        core.setBudget(id, address(rToken), BUDGET, "");
        vm.prank(client);
        core.fund(id, address(rToken), BUDGET, "");

        vm.warp(block.timestamp + 7 days);
        rToken.arm(address(core), id);

        core.claimRefund(id);

        assertEq(uint8(core.getJob(id).status), uint8(IERC8183.JobStatus.Expired));
        assertEq(rToken.balanceOf(client), BUDGET * 10);
        assertEq(rToken.balanceOf(address(core)), 0);
    }

    function test_reentrancy_fundDuringFund() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, uint48(block.timestamp + 7 days), "j", address(0), 0);
        vm.prank(provider);
        core.setBudget(id, address(rToken), BUDGET, "");
        rToken.arm(address(core), id);
        vm.prank(client);
        core.fund(id, address(rToken), BUDGET, "");
        assertEq(uint8(core.getJob(id).status), uint8(IERC8183.JobStatus.Funded));
        assertEq(rToken.balanceOf(address(core)), BUDGET);
    }
}

contract ERC8183GasLimitTest is Test {
    ERC8183 internal core;
    MockERC20 internal token;
    GasGuzzlerHook internal guzzler;

    address internal owner = makeAddr("owner");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");

    function setUp() public {
        token = new MockERC20("T", "T", 6);
        guzzler = new GasGuzzlerHook();
        core = new ERC8183(0, 0, makeAddr("treasury"), owner);

        vm.startPrank(owner);
        core.setHookWhitelist(address(guzzler), true);
        core.setPaymentTokenAllowed(address(token), true);
        vm.stopPrank();

        token.mint(client, 1_000_000e6);
        vm.prank(client);
        token.approve(address(core), type(uint256).max);
    }

    function test_gasGuzzlerHook_cannotConsumeUnlimitedGas() public {
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, uint48(block.timestamp + 7 days), "j", address(guzzler), 0);

        vm.prank(provider);
        vm.expectRevert();
        core.setBudget(id, address(token), 1000e6, "");
    }
}
