// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC8183} from "../src/ERC8183.sol";
import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ERC8183Handler is Test {
    ERC8183 public core;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner;
    address public treasury;

    address[] public clients;
    address[] public providers;
    address[] public evaluators;

    uint256[] public jobIds;

    mapping(uint256 jobId => uint16 platformFeeBp) public ghostPlat;
    mapping(uint256 jobId => uint16 evaluatorFeeBp) public ghostEval;
    mapping(uint256 jobId => address treasury_) public ghostTreasury;
    mapping(uint256 jobId => bool funded) public ghostFunded;
    mapping(uint256 jobId => uint256 amt) public ghostPendingAmt;
    mapping(uint256 jobId => bytes32 deliv) public ghostPendingDeliv;
    uint256 public claimNonce;

    constructor(
        ERC8183 core_,
        MockERC20 tokenA_,
        MockERC20 tokenB_,
        address owner_,
        address treasury_
    ) {
        core = core_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        owner = owner_;
        treasury = treasury_;

        for (uint256 i = 0; i < 3; i++) {
            address c = makeAddr(string.concat("inv-client-", vm.toString(i)));
            address p = makeAddr(string.concat("inv-provider-", vm.toString(i)));
            address e = makeAddr(string.concat("inv-evaluator-", vm.toString(i)));
            clients.push(c);
            providers.push(p);
            evaluators.push(e);
            tokenA.mint(c, 1_000_000_000e6);
            tokenB.mint(c, 1_000_000_000e6);
            vm.prank(c);
            tokenA.approve(address(core), type(uint256).max);
            vm.prank(c);
            tokenB.approve(address(core), type(uint256).max);
        }
    }

    function createJob(
        uint256 seed
    ) external {
        uint256 i = seed % 3;
        address client = clients[i];
        address provider = providers[(i + 1) % 3];
        address evaluator = evaluators[(i + 2) % 3];
        vm.prank(client);
        uint256 id = core.createJob(provider, evaluator, uint48(block.timestamp + 7 days), "inv", address(0), seed);
        jobIds.push(id);
    }

    function createJobNoProvider(
        uint256 seed
    ) external {
        uint256 i = seed % 3;
        address client = clients[i];
        address evaluator = evaluators[(i + 2) % 3];
        vm.prank(client);
        uint256 id = core.createJob(address(0), evaluator, uint48(block.timestamp + 7 days), "inv", address(0), 0);
        jobIds.push(id);
    }

    function setProvider(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Open || j.provider != address(0)) return;
        if (block.timestamp >= j.expiredAt) return;
        address provider = providers[seed % 3];
        if (provider == j.client || provider == j.evaluator) return;
        vm.prank(j.client);
        core.setProvider(id, provider, seed);
    }

    function setBudget(
        uint256 seed,
        uint256 amount
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Open || j.provider == address(0)) return;
        if (block.timestamp >= j.expiredAt) return;
        address token = seed % 2 == 0 ? address(tokenA) : address(tokenB);
        if (j.payoutReceiver != address(0) && j.payoutReceiver == token) return;
        amount = bound(amount, 0, 1_000_000e6);
        vm.prank(j.provider);
        core.setBudget(id, token, amount, "");
    }

    function setPayoutReceiver(
        uint256 seed,
        address recv
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Open || j.provider == address(0)) return;
        if (block.timestamp >= j.expiredAt) return;
        if (recv == address(core) || (recv != address(0) && recv == j.paymentToken)) {
            recv = address(0);
        }
        vm.prank(j.provider);
        core.setPayoutReceiver(id, recv);
    }

    function fund(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Open || j.provider == address(0) || j.paymentToken == address(0)) return;
        if (block.timestamp >= j.expiredAt) return;
        vm.prank(j.client);
        core.fund(id, j.paymentToken, j.budget, "");
        (uint16 p, uint16 e, address t) = core.getFeeSnapshot(id);
        ghostPlat[id] = p;
        ghostEval[id] = e;
        ghostTreasury[id] = t;
        ghostFunded[id] = true;
    }

    function submit(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        bool ok = j.status == IERC8183.JobStatus.Funded
            || (j.status == IERC8183.JobStatus.Open && j.budget == 0 && j.provider != address(0));
        if (!ok) return;
        if (block.timestamp >= j.expiredAt) return;
        vm.prank(j.provider);
        core.submit(id, bytes32(seed), "");
    }

    function complete(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Submitted) return;
        vm.prank(j.evaluator);
        core.complete(id, bytes32(seed), "");
    }

    function rejectJob(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status == IERC8183.JobStatus.Open) {
            address actor = seed % 2 == 0 ? j.client : j.provider;
            if (actor == address(0)) actor = j.client;
            vm.prank(actor);
            core.reject(id, bytes32(seed), "");
        } else if (j.status == IERC8183.JobStatus.Funded || j.status == IERC8183.JobStatus.Submitted) {
            vm.prank(j.evaluator);
            core.reject(id, bytes32(seed), "");
        }
    }

    function claimRefund(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (
            j.status != IERC8183.JobStatus.Open && j.status != IERC8183.JobStatus.Funded
                && j.status != IERC8183.JobStatus.Submitted
        ) return;
        uint256 minTs = j.expiredAt;
        if (j.status == IERC8183.JobStatus.Submitted) {
            minTs = uint256(j.expiredAt) + core.EVALUATION_GRACE_PERIOD();
        } else if (core.pendingClaimHash(id) != bytes32(0)) {
            return;
        }
        if (block.timestamp < minTs) {
            vm.warp(minTs);
        }
        core.claimRefund(id);
    }

    function submitClaim(
        uint256 seed,
        uint256 amount
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Funded) return;
        if (block.timestamp >= j.expiredAt) return;
        if (core.pendingClaimHash(id) != bytes32(0)) return;
        if (j.budget == 0 || j.settledAmount >= j.budget) return;
        amount = bound(amount, j.settledAmount + 1, j.budget);
        bytes32 deliv = bytes32(++claimNonce);
        vm.prank(j.provider);
        core.submitClaim(id, amount, deliv, "");
        ghostPendingAmt[id] = amount;
        ghostPendingDeliv[id] = deliv;
    }

    function settleClaim(
        uint256 seed,
        uint256 amount
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Funded) return;
        if (block.timestamp >= j.expiredAt) return;
        if (j.budget == 0 || j.settledAmount >= j.budget) return;
        amount = bound(amount, j.settledAmount + 1, j.budget);
        vm.prank(j.client);
        core.settleClaim(id, amount, bytes32(0), "");
    }

    function approveClaim(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Funded) return;
        bytes32 pending = core.pendingClaimHash(id);
        if (pending == bytes32(0)) return;
        if (keccak256(abi.encode(ghostPendingAmt[id], ghostPendingDeliv[id], keccak256(""))) != pending) return;
        if (ghostPendingAmt[id] <= j.settledAmount) return;
        address actor = seed % 2 == 0 ? j.client : j.evaluator;
        vm.prank(actor);
        core.approveClaim(id, ghostPendingAmt[id], ghostPendingDeliv[id], "");
    }

    function rejectClaim(
        uint256 seed
    ) external {
        if (jobIds.length == 0) return;
        uint256 id = jobIds[seed % jobIds.length];
        IERC8183.Job memory j = core.getJob(id);
        if (j.status != IERC8183.JobStatus.Funded) return;
        bytes32 pending = core.pendingClaimHash(id);
        if (pending == bytes32(0)) return;
        if (keccak256(abi.encode(ghostPendingAmt[id], ghostPendingDeliv[id], keccak256(""))) != pending) return;
        address actor;
        uint256 which = seed % 3;
        if (which == 0) actor = j.client;
        else if (which == 1) actor = j.evaluator;
        else actor = j.provider;
        vm.prank(actor);
        core.rejectClaim(id, ghostPendingAmt[id], ghostPendingDeliv[id], bytes32(seed), "");
    }

    function setFees(
        uint16 plat,
        uint16 evalB
    ) external {
        plat = uint16(bound(plat, 0, 5000));
        evalB = uint16(bound(evalB, 0, 5000 - plat));
        vm.startPrank(owner);
        core.setEvaluatorFee(0);
        core.setPlatformFee(plat);
        core.setEvaluatorFee(evalB);
        vm.stopPrank();
    }

    function setTreasury(
        uint256 seed
    ) external {
        address t = makeAddr(string.concat("inv-treasury-", vm.toString(seed)));
        vm.prank(owner);
        core.setTreasury(t);
        treasury = t;
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }
}

contract ERC8183InvariantTest is Test {
    ERC8183 internal core;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    ERC8183Handler internal handler;

    address internal owner = makeAddr("inv-owner");
    address internal treasury = makeAddr("inv-treasury");

    function setUp() public {
        tokenA = new MockERC20("A", "A", 6);
        tokenB = new MockERC20("B", "B", 6);
        core = new ERC8183(250, 100, treasury, owner);
        vm.startPrank(owner);
        core.setPaymentTokenAllowed(address(tokenA), true);
        core.setPaymentTokenAllowed(address(tokenB), true);
        vm.stopPrank();

        handler = new ERC8183Handler(core, tokenA, tokenB, owner, treasury);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = ERC8183Handler.createJob.selector;
        selectors[1] = ERC8183Handler.createJobNoProvider.selector;
        selectors[2] = ERC8183Handler.setProvider.selector;
        selectors[3] = ERC8183Handler.setBudget.selector;
        selectors[4] = ERC8183Handler.setPayoutReceiver.selector;
        selectors[5] = ERC8183Handler.fund.selector;
        selectors[6] = ERC8183Handler.submit.selector;
        selectors[7] = ERC8183Handler.complete.selector;
        selectors[8] = ERC8183Handler.rejectJob.selector;
        selectors[9] = ERC8183Handler.claimRefund.selector;
        selectors[10] = ERC8183Handler.setFees.selector;
        selectors[11] = ERC8183Handler.setTreasury.selector;
        selectors[12] = ERC8183Handler.submitClaim.selector;
        selectors[13] = ERC8183Handler.settleClaim.selector;
        selectors[14] = ERC8183Handler.approveClaim.selector;
        selectors[15] = ERC8183Handler.rejectClaim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Inv-1: escrow conservation per token.
    function invariant_escrowConservation() public view {
        _assertLocked(tokenA);
        _assertLocked(tokenB);
    }

    /// @dev Inv-2: settledAmount <= budget for every job.
    function invariant_settledAmountBounded() public view {
        uint256 n = core.jobCounter();
        for (uint256 i = 1; i <= n; i++) {
            IERC8183.Job memory j = core.getJob(i);
            assertLe(j.settledAmount, j.budget);
        }
    }

    /// @dev Inv-3: pending claim only when status == Funded.
    function invariant_pendingClaimOnlyFunded() public view {
        uint256 n = core.jobCounter();
        for (uint256 i = 1; i <= n; i++) {
            if (core.pendingClaimHash(i) != bytes32(0)) {
                assertEq(uint8(core.getJob(i).status), uint8(IERC8183.JobStatus.Funded));
            }
        }
    }

    /// @dev Inv-4: role mutex.
    function invariant_roleMutex() public view {
        uint256 n = core.jobCounter();
        for (uint256 i = 1; i <= n; i++) {
            IERC8183.Job memory j = core.getJob(i);
            if (j.provider != address(0)) {
                assertTrue(j.provider != j.client);
                assertTrue(j.provider != j.evaluator);
            }
        }
    }

    /// @dev Inv-5: fee snapshot is immutable after Funded.
    function invariant_snapshotImmutable() public view {
        uint256 n = handler.jobCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = handler.jobIds(k);
            if (!handler.ghostFunded(id)) continue;
            (uint16 p, uint16 e, address t) = core.getFeeSnapshot(id);
            assertEq(p, handler.ghostPlat(id));
            assertEq(e, handler.ghostEval(id));
            assertEq(t, handler.ghostTreasury(id));
        }
    }

    function _assertLocked(
        MockERC20 token
    ) internal view {
        uint256 locked;
        uint256 n = core.jobCounter();
        for (uint256 i = 1; i <= n; i++) {
            IERC8183.Job memory j = core.getJob(i);
            if (
                j.paymentToken == address(token)
                    && (j.status == IERC8183.JobStatus.Funded || j.status == IERC8183.JobStatus.Submitted)
            ) {
                locked += j.budget - j.settledAmount;
            }
        }
        assertGe(token.balanceOf(address(core)), locked);
    }
}
