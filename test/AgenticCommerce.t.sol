// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AgenticCommerce} from "../src/AgenticCommerce.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

contract AgenticCommerceTest is Test {
    AgenticCommerce public ac;
    MockERC20 public token;
    MockHook public hook;

    address public owner = makeAddr("owner");
    address public client = makeAddr("client");
    address public provider = makeAddr("provider");
    address public evaluator = makeAddr("evaluator");
    address public treasury = makeAddr("treasury");
    address public anyone = makeAddr("anyone");

    uint256 public constant BUDGET = 1000e6;
    uint256 public constant FEE_BP = 250; // 2.5%
    uint256 public constant DURATION = 7 days;

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        hook = new MockHook();

        vm.prank(owner);
        ac = new AgenticCommerce(address(token), FEE_BP, treasury, owner);

        token.mint(client, 100_000e6);
        vm.prank(client);
        token.approve(address(ac), type(uint256).max);
    }

    function _createJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = ac.createJob(provider, evaluator, block.timestamp + DURATION, "test job", address(0));
    }

    function _createJobWithHook() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = ac.createJob(provider, evaluator, block.timestamp + DURATION, "hooked job", address(hook));
    }

    function _createAndFundJob() internal returns (uint256 jobId) {
        jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");
    }

    function _createFundAndSubmitJob() internal returns (uint256 jobId) {
        jobId = _createAndFundJob();
        vm.prank(provider);
        ac.submit(jobId, keccak256("deliverable"), "");
    }

    function test_createJob_basic() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(provider, evaluator, block.timestamp + DURATION, "my job", address(0));

        assertEq(jobId, 1);
        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.evaluator, evaluator);
        assertEq(keccak256(bytes(job.description)), keccak256(bytes("my job")));
        assertEq(job.budget, 0);
        assertEq(job.expiredAt, block.timestamp + DURATION);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Open));
        assertEq(job.hook, address(0));
    }

    function test_createJob_withoutProvider() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(address(0), evaluator, block.timestamp + DURATION, "no provider", address(0));

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(job.provider, address(0));
    }

    function test_createJob_withHook() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(provider, evaluator, block.timestamp + DURATION, "hooked", address(hook));

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(job.hook, address(hook));
    }

    function test_createJob_revert_zeroEvaluator() public {
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.createJob(provider, address(0), block.timestamp + DURATION, "bad", address(0));
    }

    function test_createJob_revert_pastExpiry() public {
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.InvalidExpiry.selector);
        ac.createJob(provider, evaluator, block.timestamp, "bad", address(0));
    }

    function test_createJob_emitsEvent() public {
        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobCreated(1, client, provider, evaluator, block.timestamp + DURATION);
        ac.createJob(provider, evaluator, block.timestamp + DURATION, "event test", address(0));
    }

    function test_createJob_incrementsCounter() public {
        _createJob();
        _createJob();
        assertEq(ac.totalJobs(), 2);
    }

    function test_setProvider_basic() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(address(0), evaluator, block.timestamp + DURATION, "open", address(0));

        vm.prank(client);
        ac.setProvider(jobId, provider, "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(job.provider, provider);
    }

    function test_setProvider_revert_notClient() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(address(0), evaluator, block.timestamp + DURATION, "x", address(0));

        vm.prank(anyone);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.setProvider(jobId, provider, "");
    }

    function test_setProvider_revert_providerAlreadySet() public {
        uint256 jobId = _createJob(); // provider already set
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ProviderAlreadySet.selector);
        ac.setProvider(jobId, makeAddr("other"), "");
    }

    function test_setProvider_revert_zeroProvider() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(address(0), evaluator, block.timestamp + DURATION, "x", address(0));

        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.setProvider(jobId, address(0), "");
    }

    function test_setProvider_revert_notOpen() public {
        uint256 jobId = _createAndFundJob(); // status = Funded
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.setProvider(jobId, makeAddr("other"), "");
    }

    function test_setBudget_byClient() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(job.budget, BUDGET);
    }

    function test_setBudget_byProvider() public {
        uint256 jobId = _createJob();
        vm.prank(provider);
        ac.setBudget(jobId, BUDGET, "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(job.budget, BUDGET);
    }

    function test_setBudget_revert_unauthorized() public {
        uint256 jobId = _createJob();
        vm.prank(anyone);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.setBudget(jobId, BUDGET, "");
    }

    function test_setBudget_revert_notOpen() public {
        uint256 jobId = _createAndFundJob();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.setBudget(jobId, BUDGET * 2, "");
    }

    function test_fund_basic() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        uint256 balBefore = token.balanceOf(client);
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Funded));
        assertEq(token.balanceOf(address(ac)), BUDGET);
        assertEq(token.balanceOf(client), balBefore - BUDGET);
    }

    function test_fund_revert_budgetMismatch() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.BudgetMismatch.selector, BUDGET, BUDGET + 1));
        ac.fund(jobId, BUDGET + 1, "");
    }

    function test_fund_revert_zeroBudget() public {
        uint256 jobId = _createJob();
        // budget is 0 by default
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ZeroBudget.selector);
        ac.fund(jobId, 0, "");
    }

    function test_fund_revert_providerNotSet() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(address(0), evaluator, block.timestamp + DURATION, "x", address(0));

        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        vm.prank(client);
        vm.expectRevert(AgenticCommerce.ProviderNotSet.selector);
        ac.fund(jobId, BUDGET, "");
    }

    function test_fund_revert_notClient() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        vm.prank(provider);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.fund(jobId, BUDGET, "");
    }

    function test_submit_basic() public {
        uint256 jobId = _createAndFundJob();
        bytes32 deliverable = keccak256("my work");

        vm.prank(provider);
        ac.submit(jobId, deliverable, "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Submitted));
        assertEq(job.deliverable, deliverable);
    }

    function test_submit_revert_notProvider() public {
        uint256 jobId = _createAndFundJob();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.submit(jobId, keccak256("x"), "");
    }

    function test_submit_revert_notFunded() public {
        uint256 jobId = _createJob();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Open));
        ac.submit(jobId, keccak256("x"), "");
    }

    function test_complete_basic() public {
        uint256 jobId = _createFundAndSubmitJob();
        bytes32 reason = keccak256("good work");

        uint256 fee = (BUDGET * FEE_BP) / 10_000;
        uint256 providerAmount = BUDGET - fee;

        vm.prank(evaluator);
        ac.complete(jobId, reason, "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Completed));
        assertEq(token.balanceOf(provider), providerAmount);
        assertEq(token.balanceOf(treasury), fee);
        assertEq(token.balanceOf(address(ac)), 0);
    }

    function test_complete_zeroFee() public {
        // Deploy with 0% fee
        vm.prank(owner);
        AgenticCommerce acNoFee = new AgenticCommerce(address(token), 0, treasury, owner);

        token.mint(client, BUDGET);
        vm.prank(client);
        token.approve(address(acNoFee), type(uint256).max);

        vm.prank(client);
        uint256 jobId = acNoFee.createJob(provider, evaluator, block.timestamp + DURATION, "no fee", address(0));
        vm.prank(client);
        acNoFee.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        acNoFee.fund(jobId, BUDGET, "");
        vm.prank(provider);
        acNoFee.submit(jobId, keccak256("d"), "");

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(evaluator);
        acNoFee.complete(jobId, bytes32(0), "");

        assertEq(token.balanceOf(provider), BUDGET);
        assertEq(token.balanceOf(treasury), treasuryBefore);
    }

    function test_complete_revert_notEvaluator() public {
        uint256 jobId = _createFundAndSubmitJob();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.complete(jobId, bytes32(0), "");
    }

    function test_complete_revert_notSubmitted() public {
        uint256 jobId = _createAndFundJob();
        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Funded));
        ac.complete(jobId, bytes32(0), "");
    }

    function test_complete_evaluatorIsClient() public {
        vm.prank(client);
        uint256 jobId = ac.createJob(provider, client, block.timestamp + DURATION, "self-eval", address(0));
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");
        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");

        vm.prank(client); // client == evaluator
        ac.complete(jobId, bytes32(0), "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Completed));
    }

    function test_reject_fromOpen_byClient() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.reject(jobId, bytes32(0), "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Rejected));
    }

    function test_reject_fromFunded_byEvaluator() public {
        uint256 jobId = _createAndFundJob();
        uint256 clientBefore = token.balanceOf(client);

        vm.prank(evaluator);
        ac.reject(jobId, keccak256("bad"), "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Rejected));
        assertEq(token.balanceOf(client), clientBefore + BUDGET);
        assertEq(token.balanceOf(address(ac)), 0);
    }

    function test_reject_fromSubmitted_byEvaluator() public {
        uint256 jobId = _createFundAndSubmitJob();
        uint256 clientBefore = token.balanceOf(client);

        vm.prank(evaluator);
        ac.reject(jobId, keccak256("rejected"), "");

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Rejected));
        assertEq(token.balanceOf(client), clientBefore + BUDGET);
    }

    function test_reject_revert_clientCannotRejectFunded() public {
        uint256 jobId = _createAndFundJob();
        vm.prank(client);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.reject(jobId, bytes32(0), "");
    }

    function test_reject_revert_evaluatorCannotRejectOpen() public {
        uint256 jobId = _createJob();
        vm.prank(evaluator);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector);
        ac.reject(jobId, bytes32(0), "");
    }

    function test_reject_revert_fromCompleted() public {
        uint256 jobId = _createFundAndSubmitJob();
        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");

        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Completed));
        ac.reject(jobId, bytes32(0), "");
    }

    function test_claimRefund_fromFunded() public {
        uint256 jobId = _createAndFundJob();
        uint256 clientBefore = token.balanceOf(client);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(anyone);
        ac.claimRefund(jobId);

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Expired));
        assertEq(token.balanceOf(client), clientBefore + BUDGET);
    }

    function test_claimRefund_fromSubmitted() public {
        uint256 jobId = _createFundAndSubmitJob();
        uint256 clientBefore = token.balanceOf(client);

        vm.warp(block.timestamp + DURATION + 1);
        ac.claimRefund(jobId);

        IERC8183.Job memory job = ac.getJob(jobId);
        assertEq(uint8(job.status), uint8(IERC8183.Status.Expired));
        assertEq(token.balanceOf(client), clientBefore + BUDGET);
    }

    function test_claimRefund_revert_notExpired() public {
        uint256 jobId = _createAndFundJob();
        vm.expectRevert(AgenticCommerce.JobNotExpired.selector);
        ac.claimRefund(jobId);
    }

    function test_claimRefund_revert_fromOpen() public {
        uint256 jobId = _createJob();
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Open));
        ac.claimRefund(jobId);
    }

    function test_claimRefund_revert_fromCompleted() public {
        uint256 jobId = _createFundAndSubmitJob();
        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");

        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Completed));
        ac.claimRefund(jobId);
    }

    function test_claimRefund_anyoneCanCall() public {
        uint256 jobId = _createAndFundJob();
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(anyone);
        ac.claimRefund(jobId);
        assertEq(uint8(ac.getJob(jobId).status), uint8(IERC8183.Status.Expired));
    }

    function test_hook_calledOnSetBudget() public {
        uint256 jobId = _createJobWithHook();

        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        assertEq(hook.beforeCallCount(), 1);
        assertEq(hook.afterCallCount(), 1);
        assertEq(hook.lastBeforeJobId(), jobId);
        assertEq(hook.lastAfterJobId(), jobId);
    }

    function test_hook_calledOnFund() public {
        uint256 jobId = _createJobWithHook();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        uint256 beforeCount = hook.beforeCallCount();
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        assertEq(hook.beforeCallCount(), beforeCount + 1);
        assertEq(hook.afterCallCount(), beforeCount + 1);
    }

    function test_hook_calledOnSubmit() public {
        uint256 jobId = _createJobWithHook();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        uint256 beforeCount = hook.beforeCallCount();
        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");

        assertEq(hook.beforeCallCount(), beforeCount + 1);
        assertEq(hook.afterCallCount(), beforeCount + 1);
    }

    function test_hook_calledOnComplete() public {
        uint256 jobId = _createJobWithHook();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");
        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");

        uint256 beforeCount = hook.beforeCallCount();
        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");

        assertEq(hook.beforeCallCount(), beforeCount + 1);
        assertEq(hook.afterCallCount(), beforeCount + 1);
    }

    function test_hook_calledOnReject() public {
        uint256 jobId = _createJobWithHook();
        uint256 beforeCount = hook.beforeCallCount();

        vm.prank(client);
        ac.reject(jobId, bytes32(0), "");

        assertEq(hook.beforeCallCount(), beforeCount + 1);
        assertEq(hook.afterCallCount(), beforeCount + 1);
    }

    function test_hook_notCalledOnClaimRefund() public {
        uint256 jobId = _createJobWithHook();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        uint256 beforeCount = hook.beforeCallCount();
        uint256 afterCount = hook.afterCallCount();

        vm.warp(block.timestamp + DURATION + 1);
        ac.claimRefund(jobId);

        // Hook NOT called for claimRefund
        assertEq(hook.beforeCallCount(), beforeCount);
        assertEq(hook.afterCallCount(), afterCount);
    }

    function test_hook_beforeRevertBlocksAction() public {
        uint256 jobId = _createJobWithHook();
        hook.setShouldRevertBefore(true);

        vm.prank(client);
        vm.expectRevert(AgenticCommerce.HookCallFailed.selector);
        ac.setBudget(jobId, BUDGET, "");
    }

    function test_hook_optParamsForwarded() public {
        uint256 jobId = _createJobWithHook();
        bytes memory params = abi.encode("custom data", uint256(42));

        vm.prank(client);
        ac.setBudget(jobId, BUDGET, params);

        bytes memory expectedData = abi.encode(BUDGET, params);
        assertEq(keccak256(hook.lastBeforeData()), keccak256(expectedData));
        assertEq(keccak256(hook.lastAfterData()), keccak256(expectedData));
    }

    function test_setPlatformFee() public {
        vm.prank(owner);
        ac.setPlatformFee(500);
        assertEq(ac.platformFeeBp(), 500);
    }

    function test_setPlatformFee_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(AgenticCommerce.FeeTooHigh.selector);
        ac.setPlatformFee(5001);
    }

    function test_setPlatformFee_revert_notOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        ac.setPlatformFee(100);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        ac.setTreasury(newTreasury);
        assertEq(ac.treasury(), newTreasury);
    }

    function test_setTreasury_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        ac.setTreasury(address(0));
    }

    function test_supportsInterface_IERC8183() public view {
        assertTrue(ac.supportsInterface(type(IERC8183).interfaceId));
    }

    function test_supportsInterface_IERC165() public view {
        assertTrue(ac.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_unknown() public view {
        assertFalse(ac.supportsInterface(0xdeadbeef));
    }

    function test_getJob_revert_doesNotExist() public {
        vm.expectRevert(AgenticCommerce.JobDoesNotExist.selector);
        ac.getJob(999);
    }

    function test_getJob_revert_zeroId() public {
        vm.expectRevert(AgenticCommerce.JobDoesNotExist.selector);
        ac.getJob(0);
    }

    function test_fullLifecycle_happyPath() public {
        // 1. Create job
        vm.prank(client);
        uint256 jobId = ac.createJob(provider, evaluator, block.timestamp + DURATION, "full test", address(0));

        // 2. Set budget
        vm.prank(provider);
        ac.setBudget(jobId, BUDGET, "");

        // 3. Fund
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        // 4. Submit
        bytes32 deliverable = keccak256("final deliverable");
        vm.prank(provider);
        ac.submit(jobId, deliverable, "");

        // 5. Complete
        uint256 providerBefore = token.balanceOf(provider);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(evaluator);
        ac.complete(jobId, keccak256("approved"), "");

        uint256 fee = (BUDGET * FEE_BP) / 10_000;
        assertEq(token.balanceOf(provider), providerBefore + BUDGET - fee);
        assertEq(token.balanceOf(treasury), treasuryBefore + fee);
        assertEq(uint8(ac.getJob(jobId).status), uint8(IERC8183.Status.Completed));
    }

    function test_fullLifecycle_lateProviderAssignment() public {
        // 1. Create without provider
        vm.prank(client);
        uint256 jobId = ac.createJob(address(0), evaluator, block.timestamp + DURATION, "late assign", address(0));

        // 2. Assign provider later
        vm.prank(client);
        ac.setProvider(jobId, provider, "");

        // 3. Budget + Fund
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        // 4. Submit + Complete
        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");
        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");

        assertEq(uint8(ac.getJob(jobId).status), uint8(IERC8183.Status.Completed));
    }

    function test_fullLifecycle_expiry() public {
        uint256 jobId = _createAndFundJob();
        uint256 clientBefore = token.balanceOf(client);

        // Warp past expiry
        vm.warp(block.timestamp + DURATION + 1);

        // Anyone can trigger refund
        vm.prank(anyone);
        ac.claimRefund(jobId);

        assertEq(uint8(ac.getJob(jobId).status), uint8(IERC8183.Status.Expired));
        assertEq(token.balanceOf(client), clientBefore + BUDGET);
    }

    function testFuzz_feeDistribution(
        uint256 budget,
        uint256 feeBp
    ) public {
        budget = bound(budget, 1, 1_000_000e6);
        feeBp = bound(feeBp, 0, 5000);

        vm.prank(owner);
        AgenticCommerce acFuzz = new AgenticCommerce(address(token), feeBp, treasury, owner);

        token.mint(client, budget);
        vm.prank(client);
        token.approve(address(acFuzz), budget);

        vm.prank(client);
        uint256 jobId = acFuzz.createJob(provider, evaluator, block.timestamp + DURATION, "fuzz", address(0));
        vm.prank(client);
        acFuzz.setBudget(jobId, budget, "");
        vm.prank(client);
        acFuzz.fund(jobId, budget, "");
        vm.prank(provider);
        acFuzz.submit(jobId, keccak256("d"), "");

        uint256 providerBefore = token.balanceOf(provider);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(evaluator);
        acFuzz.complete(jobId, bytes32(0), "");

        uint256 expectedFee = (budget * feeBp) / 10_000;
        uint256 expectedProvider = budget - expectedFee;

        assertEq(token.balanceOf(provider), providerBefore + expectedProvider);
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedFee);
    }

    function test_constructor_revert_zeroPaymentToken() public {
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        new AgenticCommerce(address(0), FEE_BP, treasury, owner);
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(AgenticCommerce.ZeroAddress.selector);
        new AgenticCommerce(address(token), FEE_BP, address(0), owner);
    }

    function test_constructor_revert_feeTooHigh() public {
        vm.expectRevert(AgenticCommerce.FeeTooHigh.selector);
        new AgenticCommerce(address(token), 5001, treasury, owner);
    }

    function test_complete_usesSnapshotedFee() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        vm.prank(client);
        ac.fund(jobId, BUDGET, "");

        vm.prank(owner);
        ac.setPlatformFee(5000);

        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");

        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");

        uint256 expectedFee = (BUDGET * FEE_BP) / 10_000;
        uint256 expectedProvider = BUDGET - expectedFee;
        assertEq(token.balanceOf(provider), expectedProvider);
        assertEq(token.balanceOf(treasury), expectedFee);
    }

    function test_reject_revert_fromRejected() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.reject(jobId, bytes32(0), "");

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Rejected));
        ac.reject(jobId, bytes32(0), "");
    }

    function test_reject_revert_fromExpired() public {
        uint256 jobId = _createAndFundJob();
        vm.warp(block.timestamp + DURATION + 1);
        ac.claimRefund(jobId);

        vm.prank(evaluator);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Expired));
        ac.reject(jobId, bytes32(0), "");
    }

    function test_submit_revert_fromSubmitted() public {
        uint256 jobId = _createFundAndSubmitJob();
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.InvalidStatus.selector, IERC8183.Status.Submitted));
        ac.submit(jobId, keccak256("x"), "");
    }

    function test_fund_emitsEvent() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");

        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobFunded(jobId, client, BUDGET);
        ac.fund(jobId, BUDGET, "");
    }

    function test_submit_emitsEvent() public {
        uint256 jobId = _createAndFundJob();
        bytes32 deliverable = keccak256("work");

        vm.prank(provider);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobSubmitted(jobId, provider, deliverable);
        ac.submit(jobId, deliverable, "");
    }

    function test_complete_emitsEvent() public {
        uint256 jobId = _createFundAndSubmitJob();
        bytes32 reason = keccak256("good");

        vm.prank(evaluator);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobCompleted(jobId, evaluator, reason);
        ac.complete(jobId, reason, "");
    }

    function test_reject_emitsEvent() public {
        uint256 jobId = _createJob();
        bytes32 reason = keccak256("bad");

        vm.prank(client);
        vm.expectEmit(true, true, false, true);
        emit IERC8183.JobRejected(jobId, client, reason);
        ac.reject(jobId, reason, "");
    }

    function test_claimRefund_emitsEvent() public {
        uint256 jobId = _createAndFundJob();
        vm.warp(block.timestamp + DURATION + 1);

        vm.expectEmit(true, false, false, false);
        emit IERC8183.JobExpired(jobId);
        ac.claimRefund(jobId);
    }

    function test_setTreasury_revert_notOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        ac.setTreasury(makeAddr("x"));
    }

    function test_hook_selectorCorrectness() public {
        uint256 jobId = _createJobWithHook();

        vm.prank(client);
        ac.setBudget(jobId, BUDGET, "");
        assertEq(hook.lastBeforeSelector(), ac.setBudget.selector);
        assertEq(hook.lastAfterSelector(), ac.setBudget.selector);

        vm.prank(client);
        ac.fund(jobId, BUDGET, "");
        assertEq(hook.lastBeforeSelector(), ac.fund.selector);
        assertEq(hook.lastAfterSelector(), ac.fund.selector);

        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");
        assertEq(hook.lastBeforeSelector(), ac.submit.selector);
        assertEq(hook.lastAfterSelector(), ac.submit.selector);

        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");
        assertEq(hook.lastBeforeSelector(), ac.complete.selector);
        assertEq(hook.lastAfterSelector(), ac.complete.selector);
    }

    function test_claimRefund_exactlyAtExpiry() public {
        uint256 jobId = _createAndFundJob();
        IERC8183.Job memory job = ac.getJob(jobId);

        vm.warp(job.expiredAt);
        ac.claimRefund(jobId);
        assertEq(uint8(ac.getJob(jobId).status), uint8(IERC8183.Status.Expired));
    }

    function test_edgeCase_minimumBudgetFeeRounding() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        ac.setBudget(jobId, 1, "");
        vm.prank(client);
        ac.fund(jobId, 1, "");
        vm.prank(provider);
        ac.submit(jobId, keccak256("d"), "");

        vm.prank(evaluator);
        ac.complete(jobId, bytes32(0), "");

        assertEq(token.balanceOf(provider), 1);
        assertEq(token.balanceOf(address(ac)), 0);
    }
}
