import { TupleBuilder, Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Sender, SendMode } from '@ton/core';

export type MinterConfig = {
    total_supply: bigint;
    admin_address: Address;
    next_admin_address: Address;
    jetton_wallet_code: Cell;
    metadata_url: Cell;
};

export function minterConfigToCell(config: MinterConfig): Cell {
    return beginCell()
        .storeCoins(config.total_supply)
        .storeAddress(config.admin_address)
        .storeAddress(config.next_admin_address)
        .storeRef(config.jetton_wallet_code)
        .storeRef(config.metadata_url)
    .endCell();
}

export const Opcodes = {
    mint: 0x642b7d07,
    burn_notification: 0x7bdd97de,
    // increase: 0x7e8764ef,
};

export class Minter implements Contract {
    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {}

    static createFromAddress(address: Address) {
        return new Minter(address);
    }

    static createFromConfig(config: MinterConfig, code: Cell, workchain = 0) {
        const data = minterConfigToCell(config);
        const init = { code, data };
        return new Minter(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().endCell(),
        });
    }

    async sendMint(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint | string
            queryID?: number;
            toAddress: Address;
            tonAmount: bigint;
            master_msg: Cell;
        }
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                    .storeUint(Opcodes.mint, 32)
                    .storeUint(opts.queryID ?? 0, 64)
                    .storeAddress(opts.toAddress)
                    .storeCoins(opts.tonAmount)
                    .storeRef(opts.master_msg)
                .endCell(),
        });
    }

    async getJettonData(provider: ContractProvider): Promise<[bigint, boolean, Address, Cell, Cell]> {
        const { stack } = await provider.get('get_jetton_data', [])
        return [
            stack.readBigNumber(), 
            stack.readBoolean(), 
            stack.readAddress(), 
            stack.readCell(), 
            stack.readCell()
        ]
    }

    async getWalletAddress(provider: ContractProvider, owner: Address): Promise<Address> {
        const tb = new TupleBuilder()
        tb.writeAddress(owner)
        const { stack } = await provider.get('get_wallet_address', tb.build())
        return stack.readAddress()
    }

    async getBalance(provider: ContractProvider): Promise<bigint> {
        const state = await provider.getState()
        return state.balance
    }

    async getNextAdminAddress(provider: ContractProvider) {
        const result = await provider.get('get_next_admin_address', []);
        return result.stack.readAddress();
    }
}


// import { Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Sender, SendMode } from '@ton/core';

// export type TolkExampleConfig = {
//     id: number;
//     counter: number;
// };

// export function tolkExampleConfigToCell(config: TolkExampleConfig): Cell {
//     return beginCell().storeUint(config.id, 32).storeUint(config.counter, 32).endCell();
// }

// export const Opcodes = {
//     OP_INCREASE: 0x7e8764ef,
// };

// export class TolkExample implements Contract {
//     constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {}

//     static createFromAddress(address: Address) {
//         return new TolkExample(address);
//     }

//     static createFromConfig(config: TolkExampleConfig, code: Cell, workchain = 0) {
//         const data = tolkExampleConfigToCell(config);
//         const init = { code, data };
//         return new TolkExample(contractAddress(workchain, init), init);
//     }

//     async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
//         await provider.internal(via, {
//             value,
//             sendMode: SendMode.PAY_GAS_SEPARATELY,
//             body: beginCell().endCell(),
//         });
//     }

//     async sendIncrease(
//         provider: ContractProvider,
//         via: Sender,
//         opts: {
//             increaseBy: number;
//             value: bigint;
//             queryID?: number;
//         }
//     ) {
//         await provider.internal(via, {
//             value: opts.value,
//             sendMode: SendMode.PAY_GAS_SEPARATELY,
//             body: beginCell()
//                 .storeUint(Opcodes.OP_INCREASE, 32)
//                 .storeUint(opts.queryID ?? 0, 64)
//                 .storeUint(opts.increaseBy, 32)
//                 .endCell(),
//         });
//     }

//     async getCounter(provider: ContractProvider) {
//         const result = await provider.get('currentCounter', []);
//         return result.stack.readNumber();
//     }

//     async getID(provider: ContractProvider) {
//         const result = await provider.get('initialId', []);
//         return result.stack.readNumber();
//     }
// }
