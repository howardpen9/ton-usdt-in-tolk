import "workchain.tolk";
import "op_codes.tolk";

const STATUS_SIZE = 4;

@inline
fun pack_jetton_wallet_data(status: int, balance: int, owner_address: slice, jetton_master_address: slice): cell {
    return beginCell()
        .storeInt(status, STATUS_SIZE) // 4 bits
        .storeCoins(balance)
        .storeSlice(owner_address)
        .storeSlice(jetton_master_address)
    .endCell();
}

/*
    https://github.com/ton-blockchain/ton/blob/8a9ff339927b22b72819c5125428b70c406da631/crypto/block/block.tlb#L144
    _ split_depth:(Maybe (## 5)) special:(Maybe TickTock)
    code:(Maybe ^Cell) data:(Maybe ^Cell)
    library:(Maybe ^Cell) = StateInit;
*/
fun calculateJettonWalletStateInit(owner_address: slice, jetton_master_address: slice, jetton_wallet_code: cell): cell {
    return beginCell()
            .storeUint(0, 2) // 0b00 - No split_depth; No special
            .storeMaybeRef(jetton_wallet_code)  // code 
            .storeMaybeRef(                     // data 
                pack_jetton_wallet_data(
                    0, // status
                    0, //  balance
                    owner_address,
                    jetton_master_address)
                )
            .storeUint(0, 1) // Empty libraries
        .endCell();
}


/*
    https://github.com/ton-blockchain/ton/blob/8a9ff339927b22b72819c5125428b70c406da631/crypto/block/block.tlb#L105
    addr_std$10 anycast:(Maybe Anycast) workchain_id:int8 address:bits256  = MsgAddressInt;
*/
@inline
fun calculateJettonWalletAddress(state_init: cell): slice{
    return beginCell()
        .storeUint(4, 3) // 0b100 = addr_std$10 tag; No anycast
        .storeInt(MY_WORKCHAIN, 8)
        .storeUint(cellHash(state_init), 256)
    .endCell().beginParse();
}

@inline
fun calculateUserJettonWalletAddress(owner_address: slice, jetton_master_address: slice, jetton_wallet_code: cell) {
    return calculateJettonWalletAddress(
        calculateJettonWalletStateInit(owner_address, jetton_master_address, jetton_wallet_code)
    );
}


@inline
fun checkEitherForwardPayload(s: slice) {
    if (s.preloadUint(1)) {
        var (remain_bits, remain_refs) = getRemainingBitsAndRefsCount(s);  // forward_payload in ref
        assert((remain_refs == 1) & (remain_bits == 1), ERROR_INVALID_MESSAGE); // we check that there is no excess in the slice
    }
    // else forward_payload in slice - arbitrary bits and refs
}

const MSG_INFO_REST_BITS = 1 + 4 + 4 + 64 + 32;
const MSG_WITH_STATE_INIT_AND_BODY_SIZE = MSG_INFO_REST_BITS + 1 + 1 + 1;
const MSG_HAVE_STATE_INIT = 4;
const MSG_STATE_INIT_IN_REF = 2;
const MSG_BODY_IN_REF = 1;

const TRUE = -1;
const FALSE = 0;

// if no StateInit:
// 0b0 for `Maybe (Either StateInit ^StateInit)` and 0b1 or 0b0 for `body:(Either X ^X)`

const MSG_ONLY_BODY_SIZE = MSG_INFO_REST_BITS + 1 + 1;

@inline
fun storeStatinitRefAndBodyRef(b: builder, state_init: cell, body: cell): builder{
    return b
    .storeUint(MSG_HAVE_STATE_INIT + MSG_STATE_INIT_IN_REF + MSG_BODY_IN_REF, MSG_WITH_STATE_INIT_AND_BODY_SIZE)
    .storeRef(state_init)
    .storeRef(body);
}

@inline
fun storeOnlyBodyRef(b: builder, body: cell): builder{
    return b
    .storeUint(MSG_BODY_IN_REF, MSG_ONLY_BODY_SIZE)
    .storeRef(body);
}

@inline
fun storePrefixOnlyBody(b: builder): builder{
    return b.storeUint(0, MSG_ONLY_BODY_SIZE);
}

// parse after sernder_address
@inline
fun retrieveFwdFee(in_msg_full_slice: slice): int {
    in_msg_full_slice.loadAddress();  // skip dst
    in_msg_full_slice.loadCoins();    // skip value
    in_msg_full_slice.skipDict();     // skip extracurrency collection
    in_msg_full_slice.loadCoins();    // skip ihr_fee
    var fwd_fee = in_msg_full_slice.loadCoins(); 
    in_msg_full_slice.isEndOfSlice();
    return fwd_fee;
}