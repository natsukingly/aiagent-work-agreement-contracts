// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import "../../contracts/WorkAgreement.sol";
import { MockERC20 } from "../../contracts/test/MockERC20.sol";

/**
 * @title WorkAgreementWithDeadline_Test
 * @notice テストコード例
 */
contract WorkAgreementWithDeadline_Test is Test {
    WorkAgreement public workAgreement;
    MockERC20 public mockToken;

    // テスト用アドレス
    address public client;
    address public contractor;
    address public disputeResolver;

    // 定数
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    // 締め切り (例: 今から3日後)
    uint256 public constant JOB_DEADLINE = 3 days;
    string public constant JOB_TITLE = "Test Job with Deadline";
    string public constant JOB_DESCRIPTION = "This job has a strict deadline.";
    string public constant JOB_URI = "ipfs://QmTest";

    // --------------------------------------------------------------------------------
    // setUp
    // --------------------------------------------------------------------------------
    function setUp() public {
        // テスト用アドレス
        client = makeAddr("client");
        contractor = makeAddr("contractor");
        disputeResolver = makeAddr("disputeResolver");

        // コントラクトデプロイ
        mockToken = new MockERC20("Mock Token", "MTK");
        workAgreement = new WorkAgreement(disputeResolver);

        // Clientにトークン付与＆approve
        mockToken.mint(client, DEPOSIT_AMOUNT);
        vm.prank(client);
        mockToken.approve(address(workAgreement), DEPOSIT_AMOUNT);
    }

    // --------------------------------------------------------------------------------
    // 正常系テスト
    // --------------------------------------------------------------------------------

    /**
     * @dev 期限内に納品→承認→支払いまで完了するフロー
     */
    function test_SuccessWhen_FullLifecycle_BeforeDeadline() external {
        // 1. Create
        vm.startPrank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE, // 今から3日後
            JOB_URI
        );
        vm.stopPrank();

        // 2. Contractorが応募
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        // 3. Clientが契約開始
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 4. 期限内に納品 (例: 2日後に納品)
        skip(2 days);
        vm.prank(contractor);
        workAgreement.deliverWork(jobId); // deadline内なのでOK

        // 5. Clientが承認
        vm.prank(client);
        workAgreement.approveAndComplete(jobId);

        // 6. ContractorがWithdraw
        uint256 contractorBalanceBefore = mockToken.balanceOf(contractor);
        vm.prank(contractor);
        workAgreement.withdrawPayment(jobId);
        uint256 contractorBalanceAfter = mockToken.balanceOf(contractor);

        // 検証
        assertEq(
            contractorBalanceAfter - contractorBalanceBefore,
            DEPOSIT_AMOUNT,
            "Contractor should get the full deposit"
        );
    }

    // --------------------------------------------------------------------------------
    // 異常系テスト
    // --------------------------------------------------------------------------------

    /**
     * @dev 期限を過ぎて納品しようとした場合 => revert
     */
    function test_RevertWhen_DeliverAfterDeadline() external {
        // 1. Create
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Apply & Start
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. Deadlineを超過して納品を試み
        skip(4 days); // 3日より超過
        vm.startPrank(contractor);
        vm.expectRevert("Deadline passed, cannot deliver");
        workAgreement.deliverWork(jobId);
        vm.stopPrank();
    }

    /**
     * @dev 期限超過になった仕事を自動キャンセル (誰でも呼べる例)
     */
    function test_SuccessWhen_AutoCancelIfDeadlinePassed() external {
        // 1. Create job
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Apply & Start
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. Deadlineを超過 (納品なし)
        skip(4 days);

        // 4. autoCancelIfDeadlinePassed
        //    => InProgress & deadline経過 => キャンセル
        vm.expectEmit(true, true, false, false);
        emit JobDeadlineCancelled(jobId);

        // 誰でも呼べる
        workAgreement.autoCancelIfDeadlinePassed(jobId);

        // 検証
        (,, uint256 depositAmount,, WorkAgreement.JobStatus status,,,,,) =
            workAgreement.getJob(jobId);

        // depositは0に戻っているはず
        assertEq(depositAmount, 0, "Deposit should be 0 after refund");
        // ステータス => Cancelled
        assertEq(uint256(status), uint256(WorkAgreement.JobStatus.Cancelled));
    }

    /**
     * @dev 紛争のテスト(納期前に納品し、クライアントがDispute→コントラクター勝訴)
     */
    function test_SuccessWhen_Dispute_ContractorWins() external {
        // 1. Create
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Apply & Start
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. 納期前に納品
        skip(1 days);
        vm.prank(contractor);
        workAgreement.deliverWork(jobId);

        // 4. ClientがDispute
        vm.prank(client);
        workAgreement.raiseDispute(jobId);

        // 5. DisputeResolver => コントラクター勝訴 (false)
        vm.prank(disputeResolver);
        workAgreement.resolveDispute(jobId, false);

        // コントラクターに全額支払いされる
        uint256 contractorBalance = mockToken.balanceOf(contractor);
        assertEq(contractorBalance, DEPOSIT_AMOUNT);
    }
}
