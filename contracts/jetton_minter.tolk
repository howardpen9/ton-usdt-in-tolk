import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"

import "./utils/op_codes.tolk";
import "./utils/workchain.tolk";
import "./utils/jetton_utils.tolk";
import "./utils/gas.tolk";

/*
    loadData populates storage variables from persistent storage
    
    storage#_ total_supply:Coins admin_address:MsgAddress next_admin_address:MsgAddress jetton_wallet_code:^Cell metadata_uri:^Cell = Storage;
*/ 
fun loadData(): (int, slice, slice, cell, cell) {
    var ds = getContractData().beginParse();
    var total_supply = ds.loadCoins();
    var admin_address = ds.loadAddress();
    var next_admin_address = ds.loadAddress();
    var jetton_wallet_code = ds.loadRef();
    var metadata_url = ds.loadRef();
    ds.assertEndOfSlice();

    return (total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_url);
}

/*
    saveData stores storage variables as a cell into persistent storage
*/
fun saveData(total_supply: int, admin_address: slice, next_admin_address: slice, jetton_wallet_code: cell, metadata_url: cell) {
    setContractData(
        beginCell()
            .storeCoins(total_supply)
            .storeSlice(admin_address)
            .storeSlice(next_admin_address)
            .storeRef(jetton_wallet_code)
            .storeRef(metadata_url)
        .endCell()
    );
}

fun sendToJettonWallet(to_address: slice, jetton_wallet_code: cell, ton_amount: int, master_msg: cell, need_state_init: int){
    reserveToncoinsOnBalance(ONE_TON, SEND_MODE_REGULAR); // reserve for storage fees
    var state_init: cell = calculateJettonWalletStateInit(to_address, getMyAddress(), jetton_wallet_code);
    var to_wallet_address: slice = calculateJettonWalletAddress(state_init);

    // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
    var msg = beginCell()
        .storeUint(BOUNCEABLE, 6)       // store_msg_flags_and_address_none, 6
        .storeSlice(to_wallet_address)  // dest
        .storeCoins(ton_amount);

    if (need_state_init) {
        msg = msg.storeStatinitRefAndBodyRef(state_init, master_msg);
    } else {
        msg = msg.storeOnlyBodyRef(master_msg);
    }

    sendRawMessage(msg.endCell(), SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

/*
    onInternalMessage is the main entrypoint; it's called when a contract receives an internal message from other contracts
*/
fun onInternalMessage(myBalance: int, msgValue: int, msgFull: cell, msgBody: slice) {
    if (msgBody.isEndOfSlice()) { // ignore all empty messages
        return;
    }

    var msgFullSlice: slice = msgFull.beginParse();
    val flags = msgFullSlice.loadMessageFlags();

    if (isMessageBounced(flags)) { // ignore all bounced messages
        msgBody.skipBouncedPrefix(); 
        if (msgBody.loadMessageOp() != OP_INTERNAL_TRANSFER) { // process only mint bounces
            return (); 
        }

        msgBody.skipMessageQueryId();
        var jettonAmount = msgBody.loadCoins();
        var (total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_uri) = loadData();
        saveData(total_supply - jettonAmount, admin_address, next_admin_address, jetton_wallet_code, metadata_uri);
        return;
    }

    var senderAddress: slice = msgFullSlice.loadAddress();
    var forwardFeeFromInMsg: int = msgFullSlice.retrieveFwdFee();
    var forwardFee = calculateOriginalMessageFee(MY_WORKCHAIN, forwardFeeFromInMsg);
    
    val op = msgBody.loadMessageOp(); // by convention, the first 32 bits of incoming message is the op
    val queryID = msgBody.loadMessageQueryId(); // also by convention, the next 64 bits contain the "query id", although this is not always the case
    
    var (total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_uri) = loadData();
    
    if (op == OP_MINT) { // 0x642b7d07
        assert(isSliceBitsEqual(senderAddress, admin_address), ERROR_NOT_OWNER);
        
        var to_address: slice = msgBody.loadAddress();
        check_same_workchain(to_address);

        var tonAmount: int = msgBody.loadCoins();
        var master_msg: cell = msgBody.loadRef();
        msgBody.assertEndOfSlice();

        // See internal_transfer TL-B layout in jetton.tlb
        var masterMsgSlice: slice = master_msg.beginParse();
        assert(masterMsgSlice.loadMessageOp() == OP_INTERNAL_TRANSFER, ERROR_INVALID_OP);

        masterMsgSlice.skipMessageQueryId();
        var jettonAmount: int = masterMsgSlice.loadCoins();
        masterMsgSlice.loadAddress(); // from_address
        masterMsgSlice.loadAddress(); // response_address
        var forwardTonAmount: int = masterMsgSlice.loadCoins(); // forward_ton_amount
        checkEitherForwardPayload(masterMsgSlice); // either_forward_payload

        // A little more than needed, it’s ok since it’s sent by the admin and excesses will return back
        check_amount_is_enough_to_transfer(tonAmount, forwardTonAmount, forwardFee);

        sendToJettonWallet(to_address, jetton_wallet_code, tonAmount, master_msg, TRUE);
        saveData(total_supply + jettonAmount, admin_address, next_admin_address, jetton_wallet_code, metadata_uri);
        return;
    }

    if (op == OP_BURN_NOTIFICATION) { // 0x7bdd97de
        // see burn_notification TL-B layout in jetton.tlb
        var jettonAmount = msgBody.loadCoins();
        var from_address: slice = msgBody.loadAddress();
        assert(isSliceBitsEqual(calculateUserJettonWalletAddress(from_address, getMyAddress(), jetton_wallet_code), senderAddress), ERROR_NOT_VALID_WALLET);

        saveData(total_supply - jettonAmount, admin_address, next_admin_address, jetton_wallet_code, metadata_uri);
        
        var response_address: slice = msgBody.loadAddress();
        msgBody.isEndOfSlice();
        
        if (addressIsNone(response_address)) {
            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var msg = beginCell()
            .storeUint(NON_BOUNCEABLE, 6) // .store_msg_flags_and_address_none(NON_BOUNCEABLE)
            .storeSlice(response_address) // dest
            .storeCoins(0)
            .storePrefixOnlyBody()
            .storeMessageOp(OP_EXCESSES)
            .storeMessageQueryId(queryID);

            sendRawMessage(msg.endCell(), SEND_MODE_IGNORE_ERRORS | SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return ();
    }

    if (op == OP_PROVIDE_WALLET_ADDRESS) { // 0x2c76b973
        // see provide_wallet_address TL-B layout in jetton.tlb
        var owner_address: slice = msgBody.loadAddress();
        var include_address = msgBody.loadBool();
        msgBody.isEndOfSlice();

        var included_address: cell = include_address ? beginCell().storeSlice(owner_address).endCell() : null; // todo

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg = beginCell()
        .storeUint(NON_BOUNCEABLE, 6)// .store_msg_flags_and_address_none(NON_BOUNCEABLE)
        .storeSlice(senderAddress)
        .storeCoins(0)
        .storePrefixOnlyBody()
        .storeMessageOp(OP_TAKE_WALLET_ADDRESS)
        .storeMessageQueryId(queryID);

        if (is_same_workchain(owner_address)) {
            msg = msg.storeSlice(calculateUserJettonWalletAddress(owner_address, getMyAddress(), jetton_wallet_code));
        } else {
            msg = msg.storeAddressNone();
        }

        var msg_cell: cell = msg.storeMaybeRef(included_address).endCell();
        sendRawMessage(msg_cell, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return ();
    }

    if (op == OP_CHANGE_ADMIN) { // 0x6501f354
        assert(isSliceBitsEqual(senderAddress, admin_address), ERROR_NOT_OWNER);
        next_admin_address = msgBody.loadAddress();
        msgBody.isEndOfSlice();
        saveData(total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_uri);
        return ();
    }

    if (op == OP_CLAIM_ADMIN) { // 0xfb88e119
        msgBody.assertEndOfSlice();
        assert(isSliceBitsEqual(senderAddress, next_admin_address), ERROR_NOT_OWNER);
        saveData(total_supply, next_admin_address, createAddressNone(), jetton_wallet_code, metadata_uri);
        return ();
    }

    // can be used to lock, unlock or reedem funds
    if (op == OP_CALL_TO) { // 0x235caf52
        assert(isSliceBitsEqual(senderAddress, admin_address), ERROR_NOT_OWNER);

        // read the in-message body info
        var to_address: slice = msgBody.loadAddress();
        var tonAmount = msgBody.loadCoins();
        var master_msg: cell = msgBody.loadRef();
        msgBody.isEndOfSlice();

        var masterMsgSlice: slice = master_msg.beginParse();
        var master_op = masterMsgSlice.loadMessageOp();
        masterMsgSlice.skipMessageQueryId();
        
        // parse-validate messages
        if (master_op == OP_TRANSFER) {
            // see transfer TL-B layout in jetton.tlb
            masterMsgSlice.loadCoins(); // jetton_amount
            masterMsgSlice.loadAddress(); // to_owner_address
            masterMsgSlice.loadAddress(); // response_address
            masterMsgSlice.skipMaybeRef(); // custom_payload
            var forwardTonAmount = masterMsgSlice.loadCoins(); // forward_ton_amount
            checkEitherForwardPayload(masterMsgSlice); // either_forward_payload

            check_amount_is_enough_to_transfer(tonAmount, forwardTonAmount, forwardFee);

        } else if (master_op == OP_BURN) {
            // see burn TL-B layout in jetton.tlb
            masterMsgSlice.loadCoins(); // jetton_amount
            masterMsgSlice.loadAddress(); // response_address
            masterMsgSlice.skipMaybeRef(); // custom_payload
            masterMsgSlice.isEndOfSlice();

            check_amount_is_enough_to_burn(tonAmount);

        } else if (master_op == OP_SET_STATUS) {
            masterMsgSlice.loadUint(STATUS_SIZE); // status
            masterMsgSlice.isEndOfSlice();
        } else {
            throw ERROR_INVALID_OP;
        }
        sendToJettonWallet(to_address, jetton_wallet_code, tonAmount, master_msg, FALSE);
        return ();
    }

    if (op == OP_CHANGE_METADATA_URI) { // 0xcb862902
        assert(isSliceBitsEqual(senderAddress, admin_address), ERROR_NOT_OWNER);
        saveData(total_supply, admin_address, next_admin_address, jetton_wallet_code, beginCell().storeSlice(msgBody).endCell());
        return ();
    }

    if (op == OP_UPGRADE) { // 0x2508d66a
        assert(isSliceBitsEqual(senderAddress, admin_address), ERROR_NOT_OWNER);
        var (new_data, new_code) = (msgBody.loadRef(), msgBody.loadRef());
        msgBody.isEndOfSlice();
        setContractData(new_data);
        setContractCodePostponed(new_code);
        return ();
    }

    if (op == OP_TOP_UP) { // 0xd372158c
        return (); // just accept tons
    }


    throw 0xffff; // if the message contains an op that is not known to this contract, we throw
}


/* ------------------------------------------------------------------------------
    // TOKEN METADATA
    // https://github.com/ton-blockchain/TEPs/blob/master/text/0064-token-data-standard.md
    // Key is sha256 hash of string. Value is data encoded as described in "Data serialization" paragraph.
    // Snake format - must be prefixed with 0x00 byte
*/
fun set_token_snake_metadata_entry(content_dict: cell, key: int, value: slice): (cell, ()) {
    content_dict.udictSetRef(256, key, beginCell().storeUint(0, 8).storeSlice(value).endCell());
    return (content_dict, ());
}

// On-chain content layout The first byte is 0x00 and the rest is key/value dictionary.
@inline
fun create_token_onchain_metadata(content_dict: cell): cell {
    return beginCell().storeUint(0, 8).storeDict(content_dict).endCell();
}

fun udictSetRef(dict: cell, key_len: int, index: int, value: cell): void
    asm(value index dict key_len) "DICTUSETREF";



@inline
fun build_content_cell(metadata_uri: slice): cell {
    var content_dict: cell = createEmptyDict();
    content_dict.set_token_snake_metadata_entry("uri"H, metadata_uri);

    content_dict.set_token_snake_metadata_entry("decimals"H, "6");
    return create_token_onchain_metadata(content_dict);
}

/*
    get methods are a means to conveniently read contract data using, for example, HTTP APIs
    note that unlike in many other smart contract VMs, get methods cannot be called by other contracts
*/
get get_jetton_data(): (int, int, slice, cell, cell) {
    var (total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_uri) = loadData();
    return (
        total_supply,
        TRUE,
        admin_address,
        build_content_cell(metadata_uri.beginParse()),
        jetton_wallet_code
    );
}

get get_wallet_address(owner_address: slice) {
    var (total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_uri) = loadData();
    return calculateUserJettonWalletAddress(owner_address, getMyAddress(), jetton_wallet_code);
}

get get_next_admin_address(): slice {
    var (total_supply, admin_address, next_admin_address, jetton_wallet_code, metadata_uri) = loadData();
    return next_admin_address;
}