// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.22 <0.9.0;

import { ISablierLockup } from "src/interfaces/ISablierLockup.sol";
import { Lockup, LockupTranched } from "src/types/DataTypes.sol";

import { Lockup_Tranched_Integration_Fuzz_Test } from "./LockupTranched.t.sol";

contract CreateWithDurationsLT_Integration_Fuzz_Test is Lockup_Tranched_Integration_Fuzz_Test {
    struct Vars {
        uint256 actualNextStreamId;
        address actualNFTOwner;
        Lockup.Status actualStatus;
        Lockup.CreateAmounts createAmounts;
        uint256 expectedNextStreamId;
        address expectedNFTOwner;
        Lockup.Status expectedStatus;
        address funder;
        bool isCancelable;
        bool isSettled;
        LockupTranched.Tranche[] tranchesWithTimestamps;
        uint128 totalAmount;
    }

    function testFuzz_CreateWithDurationsLT(LockupTranched.TrancheWithDuration[] memory tranches)
        external
        whenNoDelegateCall
        whenTrancheCountNotExceedMaxValue
        whenTimestampsCalculationNotOverflow
    {
        vm.assume(tranches.length != 0);

        // Fuzz the durations.
        Vars memory vars;
        fuzzTrancheDurations(tranches);

        // Fuzz the tranche amounts and calculate the total and create amounts (deposit and broker fee).
        (vars.totalAmount, vars.createAmounts) = fuzzTranchedStreamAmounts(tranches, defaults.BROKER_FEE());

        // Make the Sender the stream's funder (recall that the Sender is the default caller).
        vars.funder = users.sender;
        uint256 expectedStreamId = lockup.nextStreamId();

        // Mint enough tokens to the fuzzed funder.
        deal({ token: address(dai), to: vars.funder, give: vars.totalAmount });

        // Expect the tokens to be transferred from the funder to {SablierLockup}.
        expectCallToTransferFrom({ from: vars.funder, to: address(lockup), value: vars.createAmounts.deposit });

        // Expect the broker fee to be paid to the broker, if not zero.
        if (vars.createAmounts.brokerFee > 0) {
            expectCallToTransferFrom({ from: vars.funder, to: users.broker, value: vars.createAmounts.brokerFee });
        }

        // Create the timestamps struct.
        vars.tranchesWithTimestamps = getTranchesWithTimestamps(tranches);
        Lockup.Timestamps memory timestamps = Lockup.Timestamps({
            start: getBlockTimestamp(),
            end: vars.tranchesWithTimestamps[vars.tranchesWithTimestamps.length - 1].timestamp
        });

        // Expect the relevant event to be emitted.
        vm.expectEmit({ emitter: address(lockup) });
        emit ISablierLockup.CreateLockupTranchedStream({
            streamId: expectedStreamId,
            commonParams: defaults.lockupCreateEvent(vars.createAmounts, timestamps),
            tranches: vars.tranchesWithTimestamps
        });

        // Create the stream.
        _defaultParams.createWithDurations.totalAmount = vars.totalAmount;
        _defaultParams.createWithDurations.transferable = true;
        uint256 streamId = lockup.createWithDurationsLT(_defaultParams.createWithDurations, tranches);

        // Check if the stream is settled. It is possible for a Lockup Tranched stream to settle at the time of creation
        // because some tranche amounts can be zero.
        vars.isSettled = lockup.refundableAmountOf(streamId) == 0;
        vars.isCancelable = vars.isSettled ? false : true;

        // It should create the stream.
        assertEq(lockup.getDepositedAmount(streamId), vars.createAmounts.deposit, "depositedAmount");
        assertEq(lockup.getEndTime(streamId), timestamps.end, "endTime");
        assertEq(lockup.isCancelable(streamId), vars.isCancelable, "isCancelable");
        assertFalse(lockup.isDepleted(streamId), "isDepleted");
        assertTrue(lockup.isStream(streamId), "isStream");
        assertTrue(lockup.isTransferable(streamId), "isTransferable");
        assertEq(lockup.getLockupModel(streamId), Lockup.Model.LOCKUP_TRANCHED);
        assertEq(lockup.getRecipient(streamId), users.recipient, "recipient");
        assertEq(lockup.getSender(streamId), users.sender, "sender");
        assertEq(lockup.getStartTime(streamId), timestamps.start, "startTime");
        assertEq(lockup.getTranches(streamId), vars.tranchesWithTimestamps);
        assertEq(lockup.getUnderlyingToken(streamId), dai, "underlyingToken");
        assertFalse(lockup.wasCanceled(streamId), "wasCanceled");

        // Assert that the stream's status is correct.
        vars.actualStatus = lockup.statusOf(streamId);
        vars.expectedStatus = vars.isSettled ? Lockup.Status.SETTLED : Lockup.Status.STREAMING;
        assertEq(vars.actualStatus, vars.expectedStatus);

        // Assert that the next stream ID has been bumped.
        vars.actualNextStreamId = lockup.nextStreamId();
        vars.expectedNextStreamId = streamId + 1;
        assertEq(vars.actualNextStreamId, vars.expectedNextStreamId, "nextStreamId");

        // Assert that the NFT has been minted.
        vars.actualNFTOwner = lockup.ownerOf({ tokenId: streamId });
        vars.expectedNFTOwner = users.recipient;
        assertEq(vars.actualNFTOwner, vars.expectedNFTOwner, "NFT owner");
    }
}
