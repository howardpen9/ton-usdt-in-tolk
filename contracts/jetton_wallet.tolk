import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments";

import "./utils/op_codes.tolk";
import "./utils/workchain.tolk";
import "./utils/jetton_utils.tolk";
import "./utils/gas.tolk";

const RESERVE_AT_MOST = 2;

fun loadData(): (int, int, slice, slice) {
    var ds = getContractData().beginParse();

    var status = ds.loadUint(4);
    var balance = ds.loadCoins();
    var owner_address = ds.loadAddress();
    var jetton_master_address = ds.loadAddress();
    ds.assertEndOfSlice();
    return (status, balance, owner_address, jetton_master_address);
}

/*
    saveData stores storage variables as a cell into persistent storage
*/
fun saveData(status: int, balance: int, owner_address: slice, jetton_master_address: slice) {
    setContractData(
        pack_jetton_wallet_data(status, balance, owner_address, jetton_master_address)
    );
}


fun send_jettons(msgBody: slice, sender_address: slice, msgValue: int, forwardFee: int) {
    // see transfer TL-B layout in jetton.tlb
    var query_id = msgBody.loadMessageQueryId();
    var jetton_amount = msgBody.loadCoins();
    var to_owner_address: slice = msgBody.loadAddress();
    check_same_workchain(to_owner_address);

    var (status, balance, owner_address, jetton_master_address) = loadData();

    var is_from_master = isSliceBitsEqual(jetton_master_address, sender_address);
    var outgoing_transfers_unlocked = ((status & 1) == 0);
    assert(outgoing_transfers_unlocked | is_from_master, ERROR_CONTRACT_LOCKED);
    assert(isSliceBitsEqual(owner_address, sender_address) | is_from_master, ERROR_NOT_OWNER);

    balance -= jetton_amount;
    assert(balance >= 0, ERROR_BALANCE_ERROR);

    var state_init: cell = calculateJettonWalletStateInit(to_owner_address, jetton_master_address, getContractCode());
    var to_wallet_address: slice = calculateJettonWalletAddress(state_init);
    var response_address: slice = msgBody.loadAddress();
    msgBody.skipMaybeRef(); // custom_payload
    var forward_ton_amount = msgBody.loadCoins();
    
    checkEitherForwardPayload(msgBody);
    var either_forward_payload: slice = msgBody;

    // see internal TL-B layout in jetton.tlb
    var msg_body: cell = beginCell()
                    .storeMessageOp(OP_INTERNAL_TRANSFER)
                    .storeMessageQueryId(query_id)
                    .storeCoins(jetton_amount)
                    .storeSlice(owner_address)
                    .storeSlice(response_address)
                    .storeCoins(forward_ton_amount)
                    .storeSlice(either_forward_payload)
                .endCell();

    // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
    var msg = beginCell()
                .storeUint(BOUNCEABLE, 6) // message flags and address none
                .storeSlice(to_wallet_address)
                .storeCoins(0)
                .storeStatinitRefAndBodyRef(state_init, msg_body)
            .endCell();

    check_amount_is_enough_to_transfer(msgValue, forward_ton_amount, forwardFee);
    sendRawMessage(msg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
    saveData(status, balance, owner_address, jetton_master_address);
}

// @impure // todo inline_ref
@inline
fun receive_jettons(msgBody: slice, sender_address: slice, myBalance: int, msgValue: int) {
    var (status, balance, owner_address, jetton_master_address) = loadData();

    var incoming_transfers_locked = ((status & 2) == 2);
    assert(!incoming_transfers_locked, ERROR_CONTRACT_LOCKED);
    
    //  see internal TL-B layout in jetton.tlb
    var query_id = msgBody.loadMessageQueryId();
    var jetton_amount = msgBody.loadCoins();

    balance += jetton_amount;
    
    var from_address: slice = msgBody.loadAddress();
    var response_address: slice = msgBody.loadAddress();
    assert(
        isSliceBitsEqual(jetton_master_address, sender_address) |
        isSliceBitsEqual(calculateUserJettonWalletAddress(from_address, jetton_master_address, getContractCode()), sender_address)
        ,ERROR_NOT_VALID_WALLET
    );
    
    var forward_ton_amount = msgBody.loadCoins();

    if (forward_ton_amount) {
        var either_forward_payload = msgBody;

        //  see transfer_notification TL-B layout in jetton.tlb
        var msg_body = beginCell()
        .storeMessageOp(OP_TRANSFER_NOTIFICATION)
        .storeMessageQueryId(query_id)
        .storeCoins(jetton_amount)
        .storeSlice(from_address)
        .storeSlice(either_forward_payload)
        .endCell();

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg = beginCell()
        .storeUint(NON_BOUNCEABLE, 6) // store for message flags and address none
        .storeSlice(owner_address)
        .storeCoins(forward_ton_amount)
        .storeOnlyBodyRef(msg_body)
        .endCell();

        sendRawMessage(msg, SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
    }

    if (addressIsNone(response_address)) {
        var to_leave_on_balance = myBalance - msgValue + getMyStorageDuePayment();
        reserveToncoinsOnBalance(max(to_leave_on_balance, calculate_jetton_wallet_min_storage_fee()), RESERVE_AT_MOST);

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg = beginCell()
        .storeUint(NON_BOUNCEABLE, 6) // store for message flags and address none
        .storeSlice(response_address)
        .storeCoins(0)
        .storePrefixOnlyBody()
        .storeMessageOp(OP_EXCESSES)
        .storeMessageQueryId(query_id)
        .endCell();
        sendRawMessage(msg, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
    }

    saveData(status, balance, owner_address, jetton_master_address);
}

// @impure inline_ref
fun burn_jettons(in_msg_body: slice, sender_address: slice, msgValue: int) {
    var (status, balance, owner_address, jetton_master_address) = loadData();

    var query_id = in_msg_body.loadMessageQueryId();
    var jetton_amount = in_msg_body.loadCoins();
    var response_address: slice = in_msg_body.loadAddress();
    in_msg_body.skipMaybeRef(); // custom_payload
    in_msg_body.isEndOfSlice();

    balance -= jetton_amount;
    var is_from_master = isSliceBitsEqual(jetton_master_address, sender_address);
    assert(is_from_master, ERROR_NOT_OWNER);
    assert( balance >= 0, ERROR_BALANCE_ERROR);

    // see burn_notification TL-B layout in jetton.tlb
    var msg_body = beginCell()
    .storeMessageOp(OP_BURN_NOTIFICATION)
    .storeMessageQueryId(query_id)
    .storeCoins(jetton_amount)
    .storeSlice(owner_address)
    .storeSlice(response_address)
    .endCell();

    // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
    var msg = beginCell()
    .storeUint(BOUNCEABLE, 6)
    .storeSlice(jetton_master_address)
    .storeCoins(0)
    .storeOnlyBodyRef(msg_body)
    .endCell();

    check_amount_is_enough_to_burn(msgValue);

    sendRawMessage(msg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
    saveData(status, balance, owner_address, jetton_master_address);
}

@inline
fun on_bounce(in_msg_body: slice) {
    in_msg_body.skipBouncedPrefix();

    var (status, balance, owner_address, jetton_master_address) = loadData();

    var op = in_msg_body.loadMessageOp();
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION), ERROR_WRONG_OP);
    in_msg_body.skipMessageQueryId();
    var jetton_amount = in_msg_body.loadCoins();
    saveData(status, balance + jetton_amount, owner_address, jetton_master_address);
}


/*
    Main Contract 
*/

fun onInternalMessage(myBalance: int, msgValue: int, msgFull: cell, msgBody: slice) {
    if (msgBody.isEndOfSlice()) { // ignore all empty messages
        return;
    }

    var cs: slice = msgFull.beginParse();
    val flags = cs.loadMessageFlags();
    if (isMessageBounced(flags)) { // ignore all bounced messages
        return;
    }

    var sender_address: slice = cs.loadAddress();
    var forwardFeeFromInMsg = cs.retrieveFwdFee();
    var forwardFee = calculateOriginalMessageFee(MY_WORKCHAIN, forwardFeeFromInMsg);
    
    val op = msgBody.loadMessageOp(); // by convention, the first 32 bits of incoming message is the op
        
    //  outgoing transfer
    if (op == OP_TRANSFER) {
        send_jettons(msgBody, sender_address, msgValue, forwardFee);
        return ();
    }

    //  incoming transfer
    if (op == OP_INTERNAL_TRANSFER) {
        receive_jettons(msgBody, sender_address, myBalance, msgValue);
        return ();
    }

    //  burn
    if (op == OP_BURN) {
        burn_jettons(msgBody, sender_address, msgValue);
        return ();
    }

    if (op == OP_SET_STATUS) { //  0xeed236d3
        //  skip the query_id 
        msgBody.skipMessageQueryId();

        //  read the new status for this Jetton Wallet 
        var new_status = msgBody.loadUint(STATUS_SIZE);
        msgBody.isEndOfSlice();

        var (status, balance, owner_address, jetton_master_address) = loadData();
        assert(isSliceBitsEqual(sender_address, jetton_master_address), ERROR_NOT_VALID_WALLET);

        saveData(new_status, balance, owner_address, jetton_master_address);
        return ();
    }

    if (op == OP_TOP_UP) {
        return (); //  just accept tons
    }

    throw 0xffff; // if the message contains an op that is not known to this contract, we throw
}


/*
     Get Method 
*/

get get_wallet_data(): (int, slice, slice, cell) {
    var (status, balance, owner_address, jetton_master_address) = loadData();
    return (balance, owner_address, jetton_master_address, getContractCode());
}

get get_status(): int {
    var (status, _, _, _) = loadData();
    return status;
}