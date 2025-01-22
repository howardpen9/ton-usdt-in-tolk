import "op_codes.tolk";

const BASESCHAIN: int = 0;
const MY_WORKCHAIN: int = BASECHAIN;

@inline // https://docs.ton.org/v3/documentation/smart-contracts/tolk/tolk-vs-func/mutability
fun is_same_workchain(addr: slice): int {
    var (wc, _) = parseStandardAddress(addr);
    return wc == MY_WORKCHAIN;
}

fun check_same_workchain(addr: slice) {
    assert(ERROR_WRONG_WORKCHAIN, is_same_workchain(addr));
}