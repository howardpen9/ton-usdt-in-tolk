import { Blockchain, SandboxContract, TreasuryContract,printTransactionFees, prettyLogTransactions,} from '@ton/sandbox';
import { Cell, toNano, beginCell } from '@ton/core';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';
import { Minter } from '../wrappers/JettonMinter';
import { Wallet } from '../wrappers/JettonWallet';

import { buildOnchainMetadata } from "../scripts/jetton-helpers";

const jettonParams = {
    name: "test USDT",
    description: "This is description for test USDT",
    symbol: "testUSDT",
    image: "https://i.ibb.co/J3rk47X/USDT-ocean.webp"
};
let jetton_content_metadata = buildOnchainMetadata(jettonParams);

describe('Sample', () => {
    let code: Cell;

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let treasury: SandboxContract<TreasuryContract>;
    let minter: SandboxContract<Minter>;
    let jettonWallet_deployer: SandboxContract<Wallet>;
    let jettonWallet_treasury: SandboxContract<Wallet>;
    beforeAll(async () => {
        code = await compile('JettonMinter');
    });


    beforeEach(async () => {
        blockchain = await Blockchain.create();
        deployer = await blockchain.treasury('deployer');
        treasury = await blockchain.treasury('treasury');
        minter = blockchain.openContract(
            Minter.createFromConfig(
                {
                    total_supply: 0n,
                    admin_address: deployer.address!!,
                    next_admin_address: treasury.address!!,
                    jetton_wallet_code:  await compile("JettonWallet"),
                    metadata_url: jetton_content_metadata
                },
                code
            )
        );
        
        console.log("Deployer Address: " + deployer.address);
        console.log("Minter Address: " + minter.address);

        jettonWallet_deployer = blockchain.openContract(
            Wallet.createFromConfig(
                { 
                    owner_address: deployer.address, 
                    jetton_master_address: minter.address 
                },
                await compile("JettonWallet")
            )
        );

        jettonWallet_treasury = blockchain.openContract(
            Wallet.createFromConfig(
                { 
                    owner_address: treasury.address, 
                    jetton_master_address: minter.address 
                },
                await compile("JettonWallet")
            )
        );

        // Mint 10000 USDT to deployer
        let master_msg = beginCell()
                            .storeUint(395134233, 32) // opCode: TokenTransferInternal / 0x178d4519
                            .storeUint(0, 64) // query_id
                            .storeCoins(toNano('100000')) // jetton_amount
                            .storeAddress(minter.address) // from_address
                            .storeAddress(deployer.address) // response_address
                            .storeCoins(10000) // forward_ton_amount, 0.01 TON
                            .storeUint(0, 1) // whether forward_payload or not
                        .endCell();

        const deployResult = await minter.sendMint(deployer.getSender(), { // 0x642b7d07
            value: toNano('1.5'),
            queryID: 0,
            toAddress: deployer.address,
            tonAmount: toNano('0.1'),
            master_msg: master_msg
        });


        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: minter.address,
            deploy: true,
            success: true,
        });
        printTransactionFees(deployResult.transactions);
        prettyLogTransactions(deployResult.transactions);
    });


    it('should deploy', async () => {
        let balanceDeployer = await jettonWallet_deployer.getBalance();
        console.log("Balance: " + balanceDeployer);
        
        let fetch_read = await jettonWallet_deployer.getBalance();
        console.log("Deployer's Jetton Balance: " + fetch_read);

        let fetch_read_treasury = await jettonWallet_treasury.getBalance();
        console.log("Treasury's Jetton Balance: " + fetch_read_treasury);

    });
});
